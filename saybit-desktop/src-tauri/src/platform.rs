// 跨平台桌面環境查詢：前景視窗歸屬 App、以及該 App 目前選取的文字。
//
// 原生 macOS 版靠 NSWorkspace + AX API 拿這兩項；Tauri 版沒有等價物，先前
// `getContextAndSelection()` 直接回傳寫死的 "active-app"，導致 context-aware
// prompt、per-app 語氣規則、歷史紀錄的來源欄位全部失效。這個模組補上真正的實作。

// 注意：只有單一平台會用到的 import 一定要放進該平台的函式裡（例如下面 macOS
// 分支的 mpsc）。放在頂層會讓其他平台編出 unused_imports，而在 macOS 上本機
// 開發完全看不到 —— 這是三平台 CI 的 clippy 抓到的。
use serde::Serialize;
use std::time::Duration;
use tauri::AppHandle;

#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct ForegroundApp {
    /// 使用者看得到的 App 名稱，例如 "Slack"、"Visual Studio Code"
    pub app_name: String,
    /// macOS 為 bundle identifier；Windows 為 exe 檔名（例如 "slack.exe"）；
    /// Linux 為 WM_CLASS，拿不到時退回 /proc/<pid>/comm。
    /// inject_text / simulate_enter 用這個欄位比對前景 App 有沒有換。
    pub bundle_id: String,
}

// ---------------------------------------------------------------- macOS

// NSWorkspace 屬於 AppKit。這個 app 先前已經因為在 tokio worker 執行緒上呼叫
// AppKit（enigo 的 TSM 查表）而整支崩潰，所以這裡一律派回主執行緒再取值，
// 用 channel 把結果送回呼叫端。
#[cfg(target_os = "macos")]
pub(crate) fn query_foreground(app: &AppHandle) -> ForegroundApp {
    use std::sync::mpsc;

    let (tx, rx) = mpsc::channel::<ForegroundApp>();
    let dispatched = app.run_on_main_thread(move || {
        use objc2_app_kit::NSWorkspace;
        let workspace = NSWorkspace::sharedWorkspace();
        let result = match workspace.frontmostApplication() {
            Some(running) => ForegroundApp {
                app_name: running
                    .localizedName()
                    .map(|s| s.to_string())
                    .unwrap_or_default(),
                bundle_id: running
                    .bundleIdentifier()
                    .map(|s| s.to_string())
                    .unwrap_or_default(),
            },
            None => ForegroundApp::default(),
        };
        let _ = tx.send(result);
    });

    if dispatched.is_err() {
        return ForegroundApp::default();
    }
    rx.recv_timeout(Duration::from_millis(500)).unwrap_or_default()
}

// ------------------------------------------------ macOS：最近一個外部前景 App
//
// 開 saybit:// 會把 Saybit 帶到前景，之後的注入就貼進 Saybit 自己。照原生版
// AppDelegate：觀察 NSWorkspaceDidActivateApplicationNotification，記住最近一個
// 「非 Saybit、非 launcher」的 App，處理 URL 指令前把焦點還給它。

/// 啟動器類 App 觸發 URL 後自己會隱藏，不當作要把焦點還回去的目標
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
const LAUNCHER_BUNDLE_IDS: [&str; 4] = [
    "com.raycast.macos",
    "com.runningwithcrayons.alfred",
    "com.apple.spotlight",
    "com.elgato.streamdeck",
];

#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) fn is_launcher(bundle_id: &str) -> bool {
    LAUNCHER_BUNDLE_IDS.iter().any(|l| l.eq_ignore_ascii_case(bundle_id))
}

#[cfg(target_os = "macos")]
#[derive(Clone, Debug)]
struct ExternalApp {
    pid: i32,
    info: ForegroundApp,
}

#[cfg(target_os = "macos")]
static LAST_EXTERNAL: std::sync::Mutex<Option<ExternalApp>> = std::sync::Mutex::new(None);

#[cfg(target_os = "macos")]
fn remember_if_external(running: &objc2_app_kit::NSRunningApplication) {
    let pid = running.processIdentifier();
    if pid <= 0 || pid as u32 == std::process::id() {
        return;
    }
    let bundle_id = running.bundleIdentifier().map(|s| s.to_string()).unwrap_or_default();
    if is_launcher(&bundle_id) {
        return;
    }
    let info = ForegroundApp {
        app_name: running.localizedName().map(|s| s.to_string()).unwrap_or_default(),
        bundle_id,
    };
    *LAST_EXTERNAL.lock().unwrap_or_else(|e| e.into_inner()) = Some(ExternalApp { pid, info });
}

/// 在主執行緒（setup）呼叫一次：開始追蹤外部前景 App。
#[cfg(target_os = "macos")]
pub(crate) fn start_tracking_external_app() {
    use block2::RcBlock;
    use objc2::rc::Retained;
    use objc2::runtime::AnyObject;
    use objc2::{class, msg_send};
    use objc2_app_kit::{NSRunningApplication, NSWorkspace};
    use objc2_foundation::NSString;
    use std::ptr::NonNull;

    let workspace = NSWorkspace::sharedWorkspace();
    if let Some(front) = workspace.frontmostApplication() {
        remember_if_external(&front);
    }

    let block = RcBlock::new(|notification: NonNull<AnyObject>| unsafe {
        let key = NSString::from_str("NSWorkspaceApplicationKey");
        let info: Option<Retained<AnyObject>> = msg_send![notification.as_ref(), userInfo];
        let Some(info) = info else { return };
        let app: Option<Retained<AnyObject>> = msg_send![&*info, objectForKey: &*key];
        let Some(app) = app else { return };
        if let Ok(running) = app.downcast::<NSRunningApplication>() {
            remember_if_external(&running);
        }
    });

    unsafe {
        let center: Retained<AnyObject> = msg_send![&*workspace, notificationCenter];
        let name = NSString::from_str("NSWorkspaceDidActivateApplicationNotification");
        let queue: Retained<AnyObject> = msg_send![class!(NSOperationQueue), mainQueue];
        let nil: *const AnyObject = std::ptr::null();
        let observer: Option<Retained<AnyObject>> = msg_send![
            &*center,
            addObserverForName: &*name,
            object: nil,
            queue: &*queue,
            usingBlock: &*block
        ];
        // 整個程序生命週期都要觀察，刻意不移除
        std::mem::forget(observer);
    }
}

/// Saybit 是不是目前的前景 App 且有可還的外部 App 時，把焦點還給它並回傳 true。
/// 必須在主執行緒呼叫。
#[cfg(target_os = "macos")]
pub(crate) fn refocus_last_external_if_self_front() -> bool {
    use objc2::msg_send;
    use objc2::sel;
    use objc2_app_kit::{NSRunningApplication, NSWorkspace};

    let front_pid = NSWorkspace::sharedWorkspace()
        .frontmostApplication()
        .map(|a| a.processIdentifier());
    if front_pid != Some(std::process::id() as i32) {
        return false;
    }
    let Some(target) = LAST_EXTERNAL.lock().unwrap_or_else(|e| e.into_inner()).clone() else {
        return false;
    };
    let Some(running) = NSRunningApplication::runningApplicationWithProcessIdentifier(target.pid)
    else {
        return false;
    };
    if running.isTerminated() {
        return false;
    }
    unsafe {
        // macOS 14+ 用 activate；舊系統退回 activateWithOptions:（IgnoringOtherApps）
        let responds: bool = msg_send![&*running, respondsToSelector: sel!(activate)];
        if responds {
            let _: bool = msg_send![&*running, activate];
        } else {
            let _: bool = msg_send![&*running, activateWithOptions: 1usize << 1];
        }
    }
    true
}

/// 主執行緒外呼叫：必要時把焦點還給外部 App，有還就等 250 ms 讓切換完成。
pub(crate) fn refocus_external_before_command(_app: &AppHandle) {
    #[cfg(target_os = "macos")]
    {
        use std::sync::mpsc;
        let (tx, rx) = mpsc::channel::<bool>();
        let dispatched = _app.run_on_main_thread(move || {
            let _ = tx.send(refocus_last_external_if_self_front());
        });
        if dispatched.is_ok() && rx.recv_timeout(Duration::from_millis(500)).unwrap_or(false) {
            std::thread::sleep(Duration::from_millis(250));
        }
    }
}

// ---------------------------------------------------------------- Windows

#[cfg(target_os = "windows")]
pub(crate) fn query_foreground(_app: &AppHandle) -> ForegroundApp {
    use windows::core::PWSTR;
    use windows::Win32::Foundation::{CloseHandle, MAX_PATH};
    use windows::Win32::System::Threading::{
        OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32,
        PROCESS_QUERY_LIMITED_INFORMATION,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        GetForegroundWindow, GetWindowTextW, GetWindowThreadProcessId,
    };

    unsafe {
        let hwnd = GetForegroundWindow();
        if hwnd.0.is_null() {
            return ForegroundApp::default();
        }

        // 視窗標題當作後備顯示名（例如 UWP app 拿不到有意義的 exe 名時）
        let mut title_buf = [0u16; 512];
        let title_len = GetWindowTextW(hwnd, &mut title_buf);
        let window_title = if title_len > 0 {
            String::from_utf16_lossy(&title_buf[..title_len as usize])
        } else {
            String::new()
        };

        let mut pid: u32 = 0;
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
        if pid == 0 {
            return ForegroundApp {
                app_name: window_title,
                bundle_id: String::new(),
            };
        }

        let mut exe_path = String::new();
        if let Ok(handle) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) {
            let mut buf = [0u16; MAX_PATH as usize];
            let mut size = buf.len() as u32;
            if QueryFullProcessImageNameW(
                handle,
                PROCESS_NAME_WIN32,
                PWSTR(buf.as_mut_ptr()),
                &mut size,
            )
            .is_ok()
            {
                exe_path = String::from_utf16_lossy(&buf[..size as usize]);
            }
            let _ = CloseHandle(handle);
        }

        // "C:\Program Files\Slack\slack.exe" → 檔名 "slack.exe"、顯示名 "slack"
        let file_name = exe_path.rsplit(['\\', '/']).next().unwrap_or("").to_string();
        let stem = file_name
            .trim_end_matches(".exe")
            .trim_end_matches(".EXE")
            .to_string();

        ForegroundApp {
            app_name: if stem.is_empty() { window_title } else { stem },
            bundle_id: file_name,
        }
    }
}

// ---------------------------------------------------------------- Linux

// X11/Wayland 沒有統一的 API，改用外部工具盡力而為：有 xdotool 就用，沒有就
// 回空值（前端會退回 "unknown" context，只是拿不到 per-app 規則，不影響主流程）。
#[cfg(target_os = "linux")]
pub(crate) fn query_foreground(_app: &AppHandle) -> ForegroundApp {
    use std::process::Command;

    let name = Command::new("xdotool")
        .args(["getactivewindow", "getwindowname"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default();

    let class = Command::new("xdotool")
        .args(["getactivewindow", "getwindowclassname"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default();

    // 沒有 WM_CLASS（少數 X11 client）時退回 _NET_WM_PID → /proc/<pid>/comm，
    // 讓注入前的前景比對仍有東西可比。Wayland 下 xdotool 拿不到東西，兩者皆空。
    let ident = if class.is_empty() {
        Command::new("xdotool")
            .args(["getactivewindow", "getwindowpid"])
            .output()
            .ok()
            .filter(|o| o.status.success())
            .and_then(|o| String::from_utf8_lossy(&o.stdout).trim().parse::<u32>().ok())
            .and_then(|pid| std::fs::read_to_string(format!("/proc/{pid}/comm")).ok())
            .map(|s| s.trim().to_string())
            .unwrap_or_default()
    } else {
        class.clone()
    };

    ForegroundApp {
        app_name: if class.is_empty() { name } else { class },
        bundle_id: ident,
    }
}

/// 注入前的前景比對。`expected` 為空字串視為「呼叫端沒有可比的值」而略過；
/// 實際值查不到（逾時、Wayland）但呼叫端有給 → 當成不一致，寧可不打字。
pub(crate) fn foreground_matches(expected: &str, actual: &ForegroundApp) -> bool {
    let expected = expected.trim();
    if expected.is_empty() {
        return true;
    }
    actual.bundle_id.trim().eq_ignore_ascii_case(expected)
}

/// 有給 expected_bundle_id 時查前景並比對；不一致回 Err("foreground-changed")。
pub(crate) fn ensure_foreground(app: &AppHandle, expected: Option<&str>) -> Result<(), String> {
    match expected {
        Some(exp) if !exp.trim().is_empty() => {
            let actual = query_foreground(app);
            if foreground_matches(exp, &actual) {
                Ok(())
            } else {
                Err("foreground-changed".into())
            }
        }
        _ => Ok(()),
    }
}

// ---------------------------------------------------------------- commands

/// 查詢目前前景 App。必須在 Saybit 自己的視窗搶到焦點「之前」呼叫，
/// 否則拿到的會是 Saybit 本身。
#[tauri::command]
pub fn foreground_app(app: AppHandle) -> ForegroundApp {
    query_foreground(&app)
}

/// 最近一個非 Saybit、非 launcher 的前景 App（macOS）。還沒記錄到時回目前前景。
/// Windows/Linux 不追蹤，直接回目前前景。
#[tauri::command]
pub fn last_external_app(app: AppHandle) -> ForegroundApp {
    #[cfg(target_os = "macos")]
    {
        if let Some(ext) = LAST_EXTERNAL.lock().unwrap_or_else(|e| e.into_inner()).clone() {
            return ext.info;
        }
    }
    query_foreground(&app)
}

/// 模擬複製鍵取得前景 App 的選取文字，取完還原使用者原本的剪貼簿內容。
///
/// 做法是先把剪貼簿寫入一個哨兵字串，送出 Cmd/Ctrl+C 後輪詢剪貼簿：內容不再是
/// 哨兵就代表複製成功（也就是真的有選取文字）；逾時仍是哨兵代表沒有選取。
/// 這樣才能區分「沒選取」與「選取內容剛好等於舊剪貼簿」。
#[tauri::command]
pub fn get_selected_text(app: AppHandle) -> Result<String, String> {
    use tauri_plugin_clipboard_manager::ClipboardExt;

    const SENTINEL: &str = "__saybit_selection_probe__";

    let clipboard = app.clipboard();
    let backup = clipboard.read_text().unwrap_or_default();

    clipboard
        .write_text(SENTINEL.to_string())
        .map_err(|e| e.to_string())?;

    simulate_copy(&app)?;

    let mut selected = String::new();
    // 最多等 400ms：目標 App 處理 Cmd+C 到寫入 pasteboard 有延遲，慢的 Electron
    // app（Slack/Discord）實測約 100–250ms。
    for _ in 0..20 {
        std::thread::sleep(Duration::from_millis(20));
        if let Ok(current) = clipboard.read_text() {
            if current != SENTINEL {
                selected = current;
                break;
            }
        }
    }

    // 不論成功與否都要還原，避免污染使用者剪貼簿
    let _ = clipboard.write_text(backup);

    Ok(selected)
}

fn simulate_copy(app: &AppHandle) -> Result<(), String> {
    use enigo::{Direction, Enigo, Key, Keyboard, Settings};

    app.run_on_main_thread(|| {
        if let Ok(mut enigo) = Enigo::new(&Settings::default()) {
            #[cfg(target_os = "macos")]
            let modifier = Key::Meta;
            #[cfg(not(target_os = "macos"))]
            let modifier = Key::Control;
            let _ = enigo.key(modifier, Direction::Press);
            let _ = enigo.key(Key::Unicode('c'), Direction::Click);
            let _ = enigo.key(modifier, Direction::Release);
        }
    })
    .map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fg(id: &str) -> ForegroundApp {
        ForegroundApp { app_name: String::new(), bundle_id: id.into() }
    }

    #[test]
    fn foreground_match_rules() {
        assert!(foreground_matches("", &fg("com.a")));
        assert!(foreground_matches("  ", &fg("")));
        assert!(foreground_matches("com.tinyspeck.slackmacgap", &fg("com.tinyspeck.slackmacgap")));
        assert!(foreground_matches("Slack.exe", &fg("slack.exe")));
        assert!(!foreground_matches("com.a", &fg("com.b")));
        assert!(!foreground_matches("com.a", &fg("")));
    }

    #[test]
    fn launcher_detection() {
        assert!(is_launcher("com.raycast.macos"));
        assert!(is_launcher("com.Apple.Spotlight"));
        assert!(!is_launcher("com.tinyspeck.slackmacgap"));
        assert!(!is_launcher(""));
    }
}

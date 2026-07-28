// 跨平台桌面環境查詢：前景視窗歸屬 App、以及該 App 目前選取的文字。
//
// 原生 macOS 版靠 NSWorkspace + AX API 拿這兩項；Tauri 版沒有等價物，先前
// `getContextAndSelection()` 直接回傳寫死的 "active-app"，導致 context-aware
// prompt、per-app 語氣規則、歷史紀錄的來源欄位全部失效。這個模組補上真正的實作。

use serde::Serialize;
use std::sync::mpsc;
use std::time::Duration;
use tauri::AppHandle;

#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct ForegroundApp {
    /// 使用者看得到的 App 名稱，例如 "Slack"、"Visual Studio Code"
    pub app_name: String,
    /// macOS 為 bundle identifier；Windows 為 exe 完整路徑；Linux 為 WM_CLASS
    pub bundle_id: String,
}

// ---------------------------------------------------------------- macOS

// NSWorkspace 屬於 AppKit。這個 app 先前已經因為在 tokio worker 執行緒上呼叫
// AppKit（enigo 的 TSM 查表）而整支崩潰，所以這裡一律派回主執行緒再取值，
// 用 channel 把結果送回呼叫端。
#[cfg(target_os = "macos")]
fn query_foreground(app: &AppHandle) -> ForegroundApp {
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

// ---------------------------------------------------------------- Windows

#[cfg(target_os = "windows")]
fn query_foreground(_app: &AppHandle) -> ForegroundApp {
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

        // "C:\Program Files\Slack\slack.exe" → "slack"
        let stem = exe_path
            .rsplit(['\\', '/'])
            .next()
            .unwrap_or("")
            .trim_end_matches(".exe")
            .trim_end_matches(".EXE")
            .to_string();

        ForegroundApp {
            app_name: if stem.is_empty() { window_title } else { stem },
            bundle_id: exe_path,
        }
    }
}

// ---------------------------------------------------------------- Linux

// X11/Wayland 沒有統一的 API，改用外部工具盡力而為：有 xdotool 就用，沒有就
// 回空值（前端會退回 "unknown" context，只是拿不到 per-app 規則，不影響主流程）。
#[cfg(target_os = "linux")]
fn query_foreground(_app: &AppHandle) -> ForegroundApp {
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

    ForegroundApp {
        app_name: if class.is_empty() { name } else { class.clone() },
        bundle_id: class,
    }
}

// ---------------------------------------------------------------- commands

/// 查詢目前前景 App。必須在 Saybit 自己的視窗搶到焦點「之前」呼叫，
/// 否則拿到的會是 Saybit 本身。
#[tauri::command]
pub fn foreground_app(app: AppHandle) -> ForegroundApp {
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

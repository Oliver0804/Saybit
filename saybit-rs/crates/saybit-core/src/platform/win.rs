//! Windows：GetForegroundWindow、ShellExecuteW、HKCU Run、PlaySoundW。

use crate::types::AppContext;
use windows::core::{BOOL, HSTRING, PCWSTR, PWSTR};
use windows::Win32::Foundation::{CloseHandle, HWND, LPARAM, MAX_PATH};
use windows::Win32::System::Threading::{
    OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetForegroundWindow, GetWindowTextW, GetWindowThreadProcessId, IsIconic, IsWindowVisible,
    SetForegroundWindow, ShowWindow, SW_RESTORE, SW_SHOWNORMAL,
};

const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
const RUN_VALUE: &str = "Saybit";

fn window_pid(hwnd: HWND) -> u32 {
    let mut pid: u32 = 0;
    // SAFETY: hwnd 由系統回傳；pid 是區域變數
    unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
    pid
}

fn exe_path_of(pid: u32) -> String {
    // SAFETY: handle 用完即關；buf 大小與 size 一致
    unsafe {
        let Ok(handle) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else {
            return String::new();
        };
        let mut buf = [0u16; MAX_PATH as usize];
        let mut size = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(handle, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut size).is_ok();
        let _ = CloseHandle(handle);
        if ok {
            String::from_utf16_lossy(&buf[..size as usize])
        } else {
            String::new()
        }
    }
}

pub(super) fn foreground_app() -> AppContext {
    // SAFETY: 純查詢
    let hwnd = unsafe { GetForegroundWindow() };
    if hwnd.0.is_null() {
        return AppContext::default();
    }
    let mut title_buf = [0u16; 512];
    // SAFETY: buf 是區域陣列
    let title_len = unsafe { GetWindowTextW(hwnd, &mut title_buf) };
    let window_title =
        if title_len > 0 { String::from_utf16_lossy(&title_buf[..title_len as usize]) } else { String::new() };

    let pid = window_pid(hwnd);
    if pid == 0 {
        return AppContext { app_name: window_title.clone(), window_title, ..Default::default() };
    }
    // "C:\Program Files\Slack\slack.exe" → 檔名 "slack.exe"、顯示名 "slack"
    let exe_path = exe_path_of(pid);
    let file_name = exe_path.rsplit(['\\', '/']).next().unwrap_or("").to_string();
    let stem = file_name.trim_end_matches(".exe").trim_end_matches(".EXE").to_string();
    AppContext {
        app_name: if stem.is_empty() { window_title.clone() } else { stem },
        bundle_id: file_name,
        pid: Some(pid),
        window_title,
        selected_text: None,
    }
}

pub(super) fn foreground_pid() -> Option<u32> {
    // SAFETY: 純查詢
    let hwnd = unsafe { GetForegroundWindow() };
    if hwnd.0.is_null() {
        return None;
    }
    Some(window_pid(hwnd)).filter(|p| *p != 0)
}

pub(super) fn start_tracking_external_app() {}

struct FindWindow {
    pid: u32,
    found: Option<HWND>,
}

unsafe extern "system" fn enum_proc(hwnd: HWND, lparam: LPARAM) -> BOOL {
    // SAFETY: lparam 是 activate_app 傳進來的 &mut FindWindow，EnumWindows 回傳前有效
    let state = unsafe { &mut *(lparam.0 as *mut FindWindow) };
    if window_pid(hwnd) == state.pid && unsafe { IsWindowVisible(hwnd) }.as_bool() {
        state.found = Some(hwnd);
        return BOOL(0);
    }
    BOOL(1)
}

pub(super) fn activate_app(target: &AppContext) -> bool {
    let Some(pid) = target.pid.filter(|p| *p != 0) else { return false };
    let mut state = FindWindow { pid, found: None };
    // SAFETY: state 在 EnumWindows 期間存活；EnumWindows 在 callback 回 FALSE 時回 Err，忽略
    unsafe {
        let _ = EnumWindows(Some(enum_proc), LPARAM(&mut state as *mut FindWindow as isize));
    }
    let Some(hwnd) = state.found else { return false };
    // SAFETY: hwnd 是剛列舉到的視窗
    unsafe {
        if IsIconic(hwnd).as_bool() {
            let _ = ShowWindow(hwnd, SW_RESTORE);
        }
        SetForegroundWindow(hwnd).as_bool()
    }
}

fn shell_open(target: &str, params: Option<&str>) -> anyhow::Result<()> {
    use windows::Win32::UI::Shell::ShellExecuteW;
    let verb = HSTRING::from("open");
    let file = HSTRING::from(target);
    let params = params.map(HSTRING::from);
    // SAFETY: 所有字串在呼叫期間存活
    let r = unsafe {
        ShellExecuteW(
            None,
            &verb,
            &file,
            params.as_ref().map(|p| PCWSTR(p.as_ptr())).unwrap_or(PCWSTR::null()),
            PCWSTR::null(),
            SW_SHOWNORMAL,
        )
    };
    // ShellExecute 回傳值 > 32 才是成功
    anyhow::ensure!(r.0 as isize > 32, "ShellExecuteW 失敗 ({})", r.0 as isize);
    Ok(())
}

pub(super) fn open_url(url: &str) -> anyhow::Result<()> {
    shell_open(url, None)
}

pub(super) fn reveal_in_file_manager(path: &std::path::Path) -> anyhow::Result<()> {
    let arg = format!("/select,\"{}\"", path.display());
    shell_open("explorer.exe", Some(&arg))
}

pub(super) fn accessibility_trusted() -> Option<bool> {
    None
}

pub(super) fn request_accessibility() {}

pub(super) fn open_privacy_settings(_pane: &str) -> anyhow::Result<()> {
    shell_open("ms-settings:privacy-microphone", None)
}

// ───────────────────────────── 開機啟動（HKCU Run） ─────────────────────────────

fn open_run_key(write: bool) -> anyhow::Result<windows::Win32::System::Registry::HKEY> {
    use windows::Win32::System::Registry::{RegOpenKeyExW, HKEY, HKEY_CURRENT_USER, KEY_READ, KEY_SET_VALUE};
    let mut key = HKEY::default();
    let access = if write { KEY_SET_VALUE } else { KEY_READ };
    // SAFETY: key 是區域變數，成功後由呼叫端 RegCloseKey
    let status = unsafe { RegOpenKeyExW(HKEY_CURRENT_USER, &HSTRING::from(RUN_KEY), Some(0), access, &mut key) };
    anyhow::ensure!(status.is_ok(), "RegOpenKeyExW 失敗 ({status:?})");
    Ok(key)
}

pub(super) fn launch_at_login() -> bool {
    use windows::Win32::System::Registry::{RegCloseKey, RegQueryValueExW};
    let Ok(key) = open_run_key(false) else { return false };
    // SAFETY: 只查詢值是否存在
    let status = unsafe { RegQueryValueExW(key, &HSTRING::from(RUN_VALUE), None, None, None, None) };
    // SAFETY: key 由 open_run_key 開啟
    unsafe {
        let _ = RegCloseKey(key);
    }
    status.is_ok()
}

pub(super) fn set_launch_at_login(enabled: bool) -> anyhow::Result<()> {
    use windows::Win32::Foundation::ERROR_FILE_NOT_FOUND;
    use windows::Win32::System::Registry::{RegCloseKey, RegDeleteValueW, RegSetValueExW, REG_SZ};
    let key = open_run_key(true)?;
    let name = HSTRING::from(RUN_VALUE);
    let result = if enabled {
        let exe = std::env::current_exe()?;
        let value = super::windows_run_value(&exe.to_string_lossy());
        let wide: Vec<u16> = value.encode_utf16().chain(std::iter::once(0)).collect();
        // SAFETY: REG_SZ 資料是含結尾 NUL 的 UTF-16 bytes
        let bytes = unsafe { std::slice::from_raw_parts(wide.as_ptr() as *const u8, wide.len() * 2) };
        let status = unsafe { RegSetValueExW(key, &name, Some(0), REG_SZ, Some(bytes)) };
        if status.is_ok() { Ok(()) } else { Err(anyhow::anyhow!("RegSetValueExW 失敗 ({status:?})")) }
    } else {
        // SAFETY: key 由 open_run_key 開啟
        let status = unsafe { RegDeleteValueW(key, &name) };
        if status.is_ok() || status == ERROR_FILE_NOT_FOUND {
            Ok(())
        } else {
            Err(anyhow::anyhow!("RegDeleteValueW 失敗 ({status:?})"))
        }
    };
    // SAFETY: 同上
    unsafe {
        let _ = RegCloseKey(key);
    }
    result
}

// ───────────────────────────── 音效 ─────────────────────────────

/// macOS 音效名 → Windows 系統音效別名
pub(crate) fn sound_alias(name: &str) -> &'static str {
    match name {
        "Basso" | "Funk" | "Sosumi" => "SystemHand",
        "Glass" | "Hero" => "SystemAsterisk",
        "Purr" => "SystemExclamation",
        _ => "SystemDefault",
    }
}

pub(super) fn play_sound(name: &str) {
    use windows::Win32::Media::Audio::{PlaySoundW, SND_ALIAS, SND_ASYNC, SND_NODEFAULT};
    let alias = HSTRING::from(sound_alias(name));
    // SAFETY: alias 在呼叫期間存活；SND_ASYNC 讓系統自己複製
    unsafe {
        let _ = PlaySoundW(&alias, None, SND_ALIAS | SND_ASYNC | SND_NODEFAULT);
    }
}

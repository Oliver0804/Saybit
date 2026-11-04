//! 平台相關（批次 C3；移植 platform.rs）：前景 App、選取文字（剪貼簿 Ctrl/Cmd+C，終端機與黑名單 App 不做）、
//! 最近外部 App 追蹤（macOS）、開 URL、檔案管理員顯示、開機啟動、音效、輔助使用權限。
//!
//! 注意：只有單一平台會用到的 import 一律放進該平台的檔案 / 函式裡，放頂層會讓其他平台編出
//! unused_imports（三平台 CI 的 clippy 抓得到，本機 macOS 看不到）。

use crate::types::*;
use parking_lot::Mutex;

mod eventkit;
mod selection;

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
use macos as imp;

#[cfg(target_os = "windows")]
mod win;
#[cfg(target_os = "windows")]
use win as imp;

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
use linux as imp;

#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
mod other;
#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
use other as imp;

// ───────────────────────────── 公開 API ─────────────────────────────

/// 目前前景 App。必須在 Saybit 自己的視窗搶到焦點「之前」呼叫，否則拿到的是 Saybit 本身。
pub fn foreground_app() -> AppContext {
    let ctx = imp::foreground_app();
    remember_if_external(&ctx);
    ctx
}

/// 有選取就回文字；AX 不可用時走剪貼簿 fallback（備份並還原），終端機 / 密碼管理員 / Finder 不做
pub fn selected_text(ctx: &AppContext) -> Option<String> {
    selection::selected_text(ctx)
}

pub fn is_self_frontmost() -> bool {
    imp::foreground_pid() == Some(std::process::id())
}

/// macOS：觀察 NSWorkspaceDidActivateApplicationNotification 記住最近非 Saybit、非 launcher 的 App；其他平台 no-op
/// （其他平台改由每次 `foreground_app()` 看到的外部 App 更新）。macOS 必須在主執行緒呼叫一次。
pub fn start_tracking_external_app() {
    imp::start_tracking_external_app();
}

/// 最近一個非 Saybit、非 launcher 的前景 App；還沒記錄到時回目前前景
pub fn last_external_app() -> AppContext {
    if let Some(ctx) = LAST_EXTERNAL.lock().clone() {
        return ctx;
    }
    foreground_app()
}

/// Saybit 是前景時把焦點還給上一個外部 App（等 250 ms）；回是否有切換。不要在主執行緒呼叫（會 sleep）。
pub fn refocus_last_external_if_self_front() -> bool {
    if !is_self_frontmost() {
        return false;
    }
    let Some(target) = LAST_EXTERNAL.lock().clone() else { return false };
    if !imp::activate_app(&target) {
        return false;
    }
    std::thread::sleep(std::time::Duration::from_millis(250));
    true
}

pub fn activate_app(bundle_id_or_pid: &AppContext) {
    if !imp::activate_app(bundle_id_or_pid) {
        log::info!("activate_app: 找不到 {} / {:?}", bundle_id_or_pid.bundle_id, bundle_id_or_pid.pid);
    }
}

pub fn open_url(url: &str) {
    if let Err(e) = imp::open_url(url) {
        log::warn!("open_url 失敗: {e}");
    }
}

pub fn reveal_in_file_manager(path: &std::path::Path) {
    if let Err(e) = imp::reveal_in_file_manager(path) {
        log::warn!("reveal_in_file_manager 失敗: {e}");
    }
}

/// macOS：AXIsProcessTrusted；其他平台 None（不適用）
pub fn accessibility_trusted() -> Option<bool> {
    imp::accessibility_trusted()
}

/// macOS：AXIsProcessTrustedWithOptions(prompt) —— 會彈系統對話框；其他平台 no-op
pub fn request_accessibility() {
    imp::request_accessibility();
}

/// macOS：`pane` 是 Privacy_* 名稱（Privacy_Accessibility / Privacy_Microphone / Privacy_ScreenCapture…）；
/// Windows：一律開麥克風隱私設定（Windows 沒有輔助使用權限）；Linux no-op
pub fn open_privacy_settings(pane: &str) {
    if let Err(e) = imp::open_privacy_settings(pane) {
        log::warn!("open_privacy_settings 失敗: {e}");
    }
}

pub fn launch_at_login() -> bool {
    imp::launch_at_login()
}

pub fn set_launch_at_login(enabled: bool) -> anyhow::Result<()> {
    imp::set_launch_at_login(enabled)
}

/// 系統音效（macOS NSSound 名稱如 "Pop"/"Purr"/"Glass"；其他平台用內建短音或 no-op）
pub fn play_sound(name: &str) {
    imp::play_sound(name);
}

/// 執行使用者已確認的動作（行事曆 / 提醒）。macOS 用 EventKit（移植 saybit-desktop/src-tauri/src/eventkit.rs）；其他平台回 Err("此平台不支援")。
/// 回傳給使用者看的確認文字。會阻塞到使用者回應授權對話框（最多 60 s），不要在主執行緒呼叫。
pub fn execute_action(action: &PendingAction) -> anyhow::Result<String> {
    eventkit::execute_action(action)
}

/// 這個平台能不能執行 PendingAction（UI 用來決定顯示「建立」還是只顯示文字）。
/// macOS 另外要求 bundle Info.plist 有行事曆 / 提醒的用途說明（沒有時要求授權會被系統直接終止程序）。
pub fn supports_actions() -> bool {
    eventkit::supports_actions()
}

// ───────────────────────────── 最近外部 App ─────────────────────────────

static LAST_EXTERNAL: Mutex<Option<AppContext>> = Mutex::new(None);

/// 啟動器類 App 觸發 URL 後自己會隱藏，不當作要把焦點還回去的目標
const LAUNCHER_IDS: [&str; 4] = [
    "com.raycast.macos",
    "com.runningwithcrayons.alfred",
    "com.apple.spotlight",
    "com.elgato.streamdeck",
];

pub(crate) fn is_launcher(bundle_id: &str) -> bool {
    LAUNCHER_IDS.iter().any(|l| l.eq_ignore_ascii_case(bundle_id.trim()))
}

/// 這個前景 App 能不能當「最近外部 App」：要有 pid、不是自己、不是 launcher
pub(crate) fn is_trackable_external(ctx: &AppContext, self_pid: u32) -> bool {
    match ctx.pid {
        Some(pid) if pid > 0 && pid != self_pid => !is_launcher(&ctx.bundle_id),
        _ => false,
    }
}

pub(crate) fn remember_if_external(ctx: &AppContext) {
    if is_trackable_external(ctx, std::process::id()) {
        let mut stored = ctx.clone();
        stored.selected_text = None;
        *LAST_EXTERNAL.lock() = Some(stored);
    }
}

// ───────────────────────────── 前景比對 ─────────────────────────────

/// 注入前的前景比對。`expected` 為空字串視為「呼叫端沒有可比的值」而略過；
/// 實際值查不到（逾時、Wayland）但呼叫端有給 → 當成不一致，寧可不打字。
pub(crate) fn foreground_matches(expected: &str, actual: &AppContext) -> bool {
    let expected = expected.trim();
    if expected.is_empty() {
        return true;
    }
    actual.bundle_id.trim().eq_ignore_ascii_case(expected)
}

// ───────────────────────────── 敏感 App 黑名單 ─────────────────────────────

/// ⌘C / Ctrl+C fallback 黑名單（移植 SensitiveApps.swift 的 clipboardFallbackPatterns，另補常見終端機）。
/// 結尾 `.*` 表示前綴比對；比對不分大小寫。Windows 是 exe 檔名、Linux 是 WM_CLASS / comm。
const CLIPBOARD_FALLBACK_BLOCKLIST: &[&str] = &[
    // macOS：密碼管理員 / 鑰匙圈
    "com.1password.*",
    "com.agilebits.*",
    "com.apple.keychainaccess",
    "com.apple.Passwords",
    "com.bitwarden.desktop",
    "com.lastpass.LastPass",
    "com.dashlane.*",
    // macOS：終端機
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "dev.warp.*",
    "com.mitchellh.ghostty",
    "org.alacritty",
    "net.kovidgoyal.kitty",
    "com.github.wez.wezterm",
    // macOS：Finder（⌘C 複製檔案而非文字）
    "com.apple.finder",
    // macOS：遠端桌面 / 虛擬機
    "com.microsoft.rdc.macos",
    "com.parallels.*",
    "com.vmware.*",
    "com.teamviewer.*",
    "com.apple.ScreenSharing",
    "com.anydesk.*",
    "com.realvnc.*",
    // Windows：終端機（Ctrl+C 是中斷）、檔案總管、密碼管理員、遠端桌面
    "windowsterminal.exe",
    "cmd.exe",
    "powershell.exe",
    "pwsh.exe",
    "conhost.exe",
    "openconsole.exe",
    "wezterm-gui.exe",
    "alacritty.exe",
    "mintty.exe",
    "putty.exe",
    "explorer.exe",
    "1password.exe",
    "bitwarden.exe",
    "keepass.exe",
    "keepassxc.exe",
    "mstsc.exe",
    "msrdc.exe",
    "teamviewer.exe",
    "anydesk.exe",
    "vncviewer.exe",
    // Linux（WM_CLASS / comm）
    "gnome-terminal-server",
    "gnome-terminal",
    "org.gnome.terminal",
    "org.gnome.console",
    "kgx",
    "konsole",
    "xterm",
    "uxterm",
    "alacritty",
    "kitty",
    "terminator",
    "tilix",
    "xfce4-terminal",
    "org.wezfurlong.wezterm",
    "com.mitchellh.ghostty",
    "nautilus",
    "org.gnome.nautilus",
    "dolphin",
    "thunar",
    "nemo",
    "1password",
    "bitwarden",
    "keepassxc",
    "remmina",
    "org.remmina.remmina",
    "anydesk",
    "teamviewer",
];

/// bundle id 是否符合黑名單 pattern（`.*` 結尾為前綴比對，不分大小寫）。空 id 不算符合。
pub(crate) fn matches_patterns(bundle_id: &str, patterns: &[&str]) -> bool {
    let id = bundle_id.trim().to_ascii_lowercase();
    if id.is_empty() {
        return false;
    }
    patterns.iter().any(|raw| {
        let pattern = raw.to_ascii_lowercase();
        match pattern.strip_suffix(".*") {
            Some(prefix) => id == prefix || id.starts_with(&format!("{prefix}.")),
            None => id == pattern,
        }
    })
}

pub(crate) fn is_clipboard_fallback_blocked(bundle_id: &str) -> bool {
    matches_patterns(bundle_id, CLIPBOARD_FALLBACK_BLOCKLIST)
}

// ───────────────────────────── 開機啟動檔案內容（純函式） ─────────────────────────────

#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) const LAUNCH_AGENT_LABEL: &str = "com.bashcat.saybit";

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

/// macOS LaunchAgent plist（非 .app bundle 執行時的開機啟動方式）
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) fn launch_agent_plist(exe: &str) -> String {
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n\
<plist version=\"1.0\">\n<dict>\n\
\t<key>Label</key>\n\t<string>{label}</string>\n\
\t<key>ProgramArguments</key>\n\t<array>\n\t\t<string>{exe}</string>\n\t</array>\n\
\t<key>RunAtLoad</key>\n\t<true/>\n\
\t<key>ProcessType</key>\n\t<string>Interactive</string>\n\
</dict>\n</plist>\n",
        label = LAUNCH_AGENT_LABEL,
        exe = xml_escape(exe),
    )
}

/// Linux XDG autostart / scheme handler 共用的 .desktop Exec 參數跳脫
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub(crate) fn desktop_exec_quote(exe: &str) -> String {
    let needs_quote = exe.chars().any(|c| " \t\n\"'\\><~|&;$*?#()`".contains(c));
    if !needs_quote {
        return exe.to_string();
    }
    let mut out = String::from("\"");
    for c in exe.chars() {
        if matches!(c, '"' | '`' | '$' | '\\') {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('"');
    out
}

/// Linux `~/.config/autostart/saybit.desktop`
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub(crate) fn autostart_desktop_entry(exe: &str) -> String {
    format!(
        "[Desktop Entry]\nType=Application\nName=Saybit\nExec={}\nX-GNOME-Autostart-enabled=true\nTerminal=false\n",
        desktop_exec_quote(exe)
    )
}

/// Windows `HKCU\...\Run` 的值
#[cfg_attr(not(target_os = "windows"), allow(dead_code))]
pub(crate) fn windows_run_value(exe: &str) -> String {
    format!("\"{exe}\"")
}

/// macOS 系統設定隱私頁 URL
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) fn macos_privacy_url(pane: &str) -> String {
    let pane = pane.trim();
    if pane.is_empty() {
        "x-apple.systempreferences:com.apple.preference.security".into()
    } else {
        format!("x-apple.systempreferences:com.apple.preference.security?{pane}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ctx(id: &str, pid: Option<u32>) -> AppContext {
        AppContext { bundle_id: id.into(), pid, ..Default::default() }
    }

    #[test]
    fn foreground_match_rules() {
        assert!(foreground_matches("", &ctx("com.a", None)));
        assert!(foreground_matches("  ", &ctx("", None)));
        assert!(foreground_matches("com.tinyspeck.slackmacgap", &ctx("com.tinyspeck.slackmacgap", None)));
        assert!(foreground_matches("Slack.exe", &ctx("slack.exe", None)));
        assert!(!foreground_matches("com.a", &ctx("com.b", None)));
        assert!(!foreground_matches("com.a", &ctx("", None)));
    }

    #[test]
    fn launcher_detection() {
        assert!(is_launcher("com.raycast.macos"));
        assert!(is_launcher("com.Apple.Spotlight"));
        assert!(!is_launcher("com.tinyspeck.slackmacgap"));
        assert!(!is_launcher(""));
    }

    #[test]
    fn trackable_external() {
        assert!(is_trackable_external(&ctx("com.tinyspeck.slackmacgap", Some(42)), 7));
        assert!(!is_trackable_external(&ctx("com.tinyspeck.slackmacgap", Some(7)), 7)); // 自己
        assert!(!is_trackable_external(&ctx("com.raycast.macos", Some(42)), 7)); // launcher
        assert!(!is_trackable_external(&ctx("x", None), 7));
        assert!(!is_trackable_external(&ctx("x", Some(0)), 7));
    }

    #[test]
    fn blocklist_patterns() {
        assert!(is_clipboard_fallback_blocked("com.apple.Terminal"));
        assert!(is_clipboard_fallback_blocked("com.apple.terminal"));
        assert!(is_clipboard_fallback_blocked("com.1password.1password"));
        assert!(is_clipboard_fallback_blocked("com.1password"));
        assert!(!is_clipboard_fallback_blocked("com.1passwordx.app"));
        assert!(is_clipboard_fallback_blocked("com.apple.finder"));
        assert!(is_clipboard_fallback_blocked("WindowsTerminal.exe"));
        assert!(is_clipboard_fallback_blocked("explorer.exe"));
        assert!(is_clipboard_fallback_blocked("gnome-terminal-server"));
        assert!(!is_clipboard_fallback_blocked("com.tinyspeck.slackmacgap"));
        assert!(!is_clipboard_fallback_blocked("slack.exe"));
        assert!(!is_clipboard_fallback_blocked(""));
    }

    #[test]
    fn launch_agent_plist_escapes_path() {
        let p = launch_agent_plist("/Users/a&b/Saybit");
        assert!(p.contains("<string>/Users/a&amp;b/Saybit</string>"));
        assert!(p.contains("<string>com.bashcat.saybit</string>"));
        assert!(p.contains("<key>RunAtLoad</key>"));
    }

    #[test]
    fn desktop_entry_quotes_exec() {
        assert_eq!(desktop_exec_quote("/usr/bin/saybit"), "/usr/bin/saybit");
        assert_eq!(desktop_exec_quote("/opt/My App/saybit"), "\"/opt/My App/saybit\"");
        assert_eq!(desktop_exec_quote("/opt/a$b"), "\"/opt/a\\$b\"");
        let e = autostart_desktop_entry("/usr/bin/saybit");
        assert!(e.starts_with("[Desktop Entry]\n"));
        assert!(e.contains("Exec=/usr/bin/saybit\n"));
    }

    #[test]
    fn run_value_and_privacy_url() {
        assert_eq!(windows_run_value(r"C:\Saybit\saybit.exe"), "\"C:\\Saybit\\saybit.exe\"");
        assert_eq!(
            macos_privacy_url("Privacy_Accessibility"),
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        );
        assert_eq!(macos_privacy_url(""), "x-apple.systempreferences:com.apple.preference.security");
    }
}

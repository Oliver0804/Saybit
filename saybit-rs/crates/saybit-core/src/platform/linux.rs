//! Linux：X11/Wayland 沒有統一 API，外部工具盡力而為（xdotool、xdg-open、paplay、dbus-send）。
//! 拿不到就回空值，不影響主流程（只是沒有 per-app 規則）。

use crate::types::AppContext;
use std::process::{Command, Stdio};

fn xdotool(args: &[&str]) -> Option<String> {
    Command::new("xdotool")
        .args(args)
        .stderr(Stdio::null())
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
}

pub(super) fn foreground_pid() -> Option<u32> {
    xdotool(&["getactivewindow", "getwindowpid"]).and_then(|s| s.parse().ok())
}

pub(super) fn foreground_app() -> AppContext {
    let title = xdotool(&["getactivewindow", "getwindowname"]).unwrap_or_default();
    let class = xdotool(&["getactivewindow", "getwindowclassname"]).unwrap_or_default();
    let pid = foreground_pid();
    // 沒有 WM_CLASS 時退回 /proc/<pid>/comm，讓注入前的前景比對仍有東西可比；Wayland 下兩者皆空
    let ident = if class.is_empty() {
        pid.and_then(|p| std::fs::read_to_string(format!("/proc/{p}/comm")).ok())
            .map(|s| s.trim().to_string())
            .unwrap_or_default()
    } else {
        class.clone()
    };
    AppContext {
        app_name: if class.is_empty() { title.clone() } else { class },
        bundle_id: ident,
        pid,
        window_title: title,
        selected_text: None,
    }
}

pub(super) fn start_tracking_external_app() {}

pub(super) fn activate_app(target: &AppContext) -> bool {
    let Some(pid) = target.pid.filter(|p| *p != 0) else { return false };
    let pid = pid.to_string();
    Command::new("xdotool")
        .args(["search", "--onlyvisible", "--pid", &pid, "windowactivate"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn spawn(cmd: &str, args: &[&std::ffi::OsStr]) -> anyhow::Result<()> {
    Command::new(cmd).args(args).stdout(Stdio::null()).stderr(Stdio::null()).spawn()?;
    Ok(())
}

pub(super) fn open_url(url: &str) -> anyhow::Result<()> {
    spawn("xdg-open", &[std::ffi::OsStr::new(url)])
}

pub(super) fn reveal_in_file_manager(path: &std::path::Path) -> anyhow::Result<()> {
    // freedesktop FileManager1.ShowItems（Nautilus / Dolphin / Nemo 支援）；失敗退回開上層資料夾
    let uri = url::Url::from_file_path(path).map(|u| u.to_string()).unwrap_or_default();
    if !uri.is_empty() {
        let ok = Command::new("dbus-send")
            .args([
                "--session",
                "--dest=org.freedesktop.FileManager1",
                "--type=method_call",
                "/org/freedesktop/FileManager1",
                "org.freedesktop.FileManager1.ShowItems",
                &format!("array:string:{uri}"),
                "string:",
            ])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if ok {
            return Ok(());
        }
    }
    let dir = if path.is_dir() { path } else { path.parent().unwrap_or(path) };
    spawn("xdg-open", &[dir.as_os_str()])
}

pub(super) fn accessibility_trusted() -> Option<bool> {
    None
}

pub(super) fn request_accessibility() {}

pub(super) fn open_privacy_settings(pane: &str) -> anyhow::Result<()> {
    log::info!("Linux 沒有對應的隱私設定頁（{pane}）");
    Ok(())
}

fn autostart_path() -> Option<std::path::PathBuf> {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(std::path::PathBuf::from)
        .filter(|p| p.is_absolute())
        .or_else(|| std::env::var_os("HOME").map(|h| std::path::PathBuf::from(h).join(".config")))?;
    Some(base.join("autostart").join("saybit.desktop"))
}

pub(super) fn launch_at_login() -> bool {
    autostart_path().is_some_and(|p| p.exists())
}

pub(super) fn set_launch_at_login(enabled: bool) -> anyhow::Result<()> {
    let path = autostart_path().ok_or_else(|| anyhow::anyhow!("找不到 HOME"))?;
    if enabled {
        let exe = std::env::current_exe()?;
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        std::fs::write(&path, super::autostart_desktop_entry(&exe.to_string_lossy()))?;
    } else {
        match std::fs::remove_file(&path) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.into()),
        }
    }
    Ok(())
}

/// macOS 音效名 → freedesktop sound theme 名稱
pub(crate) fn sound_file(name: &str) -> &'static str {
    match name {
        "Basso" | "Funk" | "Sosumi" => "dialog-error",
        "Glass" | "Hero" => "complete",
        "Pop" | "Tink" => "message",
        _ => "bell",
    }
}

pub(super) fn play_sound(name: &str) {
    let file = format!("/usr/share/sounds/freedesktop/stereo/{}.oga", sound_file(name));
    if std::path::Path::new(&file).exists() {
        let _ = spawn("paplay", &[std::ffi::OsStr::new(&file)]);
    }
}

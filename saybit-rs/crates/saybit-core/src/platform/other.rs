//! 其他平台（BSD 等）：全部 no-op，讓 crate 仍能編譯。

use crate::types::AppContext;

pub(super) fn foreground_app() -> AppContext {
    AppContext::default()
}
pub(super) fn foreground_pid() -> Option<u32> {
    None
}
pub(super) fn start_tracking_external_app() {}
pub(super) fn activate_app(_target: &AppContext) -> bool {
    false
}
pub(super) fn open_url(_url: &str) -> anyhow::Result<()> {
    anyhow::bail!("unsupported platform")
}
pub(super) fn reveal_in_file_manager(_path: &std::path::Path) -> anyhow::Result<()> {
    anyhow::bail!("unsupported platform")
}
pub(super) fn accessibility_trusted() -> Option<bool> {
    None
}
pub(super) fn request_accessibility() {}
pub(super) fn open_privacy_settings(_pane: &str) -> anyhow::Result<()> {
    Ok(())
}
pub(super) fn launch_at_login() -> bool {
    false
}
pub(super) fn set_launch_at_login(_enabled: bool) -> anyhow::Result<()> {
    anyhow::bail!("unsupported platform")
}
pub(super) fn play_sound(_name: &str) {}

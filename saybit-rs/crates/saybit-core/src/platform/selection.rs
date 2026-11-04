//! 選取文字（移植 TextExtractor.swift）。
//!
//! macOS：先試 AX（kAXSelectedText）。三態：有文字 → 用；`.emptySelection` → 不 fallback
//! （VS Code 的 ⌘C 會複製整行、Finder 會複製檔案）；只有 `.unsupported` 且焦點元素是文字輸入類
//! 才送 ⌘C fallback。Windows / Linux 沒有 AX，只有剪貼簿 fallback。兩者都套黑名單。

use crate::inject::{self, clipboard};
use crate::types::AppContext;
use std::time::Duration;

/// AX 讀取選取文字的三種結果：只有 `Unsupported` 才考慮 ⌘C fallback
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum AxSelection {
    Text(String),
    EmptySelection,
    Unsupported,
}

/// ⌘C fallback 只對文字輸入類元素執行
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
const FALLBACK_ROLES: [&str; 3] = ["AXTextField", "AXTextArea", "AXWebArea"];

#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) fn should_use_clipboard_fallback_mac(bundle_id: &str, role: Option<&str>) -> bool {
    let Some(role) = role else { return false };
    FALLBACK_ROLES.contains(&role) && !super::is_clipboard_fallback_blocked(bundle_id)
}

/// AX 結果 + role → 最後要不要 fallback / 直接回什麼
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum SelectionPlan {
    Done(Option<String>),
    ClipboardFallback,
}

#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) fn plan_mac(ax: AxSelection, bundle_id: &str, role: Option<&str>) -> SelectionPlan {
    match ax {
        AxSelection::Text(t) => SelectionPlan::Done(Some(t)),
        AxSelection::EmptySelection => SelectionPlan::Done(None),
        AxSelection::Unsupported if should_use_clipboard_fallback_mac(bundle_id, role) => {
            SelectionPlan::ClipboardFallback
        }
        AxSelection::Unsupported => SelectionPlan::Done(None),
    }
}

pub(crate) fn selected_text(ctx: &AppContext) -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        let pid = match ctx.pid {
            Some(p) if p > 0 => p,
            _ => super::foreground_app().pid?,
        };
        let (ax, role) = super::macos::ax_selection(pid as i32);
        match plan_mac(ax, &ctx.bundle_id, role.as_deref()) {
            SelectionPlan::Done(t) => t,
            SelectionPlan::ClipboardFallback => {
                log::info!("AX 不支援選取文字（role={role:?}），嘗試剪貼簿 fallback");
                copy_via_clipboard()
            }
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        if super::is_clipboard_fallback_blocked(&ctx.bundle_id) {
            log::info!("{} 在剪貼簿 fallback 黑名單，略過選取文字", ctx.bundle_id);
            return None;
        }
        copy_via_clipboard()
    }
}

/// macOS：備份 → ⌘C → 輪詢 changeCount（最多 600 ms）→ 讀文字 → 完整還原
#[cfg(target_os = "macos")]
fn copy_via_clipboard() -> Option<String> {
    let backup = clipboard::snapshot();
    let before = clipboard::change_count();
    if let Err(e) = inject::send_shortcut('c') {
        log::warn!("Cmd+C 送出失敗: {e}");
        return None;
    }
    let mut changed = false;
    for _ in 0..12 {
        std::thread::sleep(Duration::from_millis(50));
        if clipboard::change_count() != before {
            changed = true;
            break;
        }
    }
    if !changed {
        log::info!("剪貼簿 fallback：剪貼簿未改變（沒有選取）");
        return None;
    }
    let text = clipboard::read_text();
    clipboard::restore(&backup);
    text.filter(|t| !t.is_empty())
}

/// Windows / Linux：沒有 changeCount，先寫哨兵字串，送 Ctrl+C 後內容不再是哨兵 = 複製成功。
/// 這樣才能區分「沒選取」與「選取內容剛好等於舊剪貼簿」。不論成功與否都還原。
#[cfg(not(target_os = "macos"))]
fn copy_via_clipboard() -> Option<String> {
    const SENTINEL: &str = "__saybit_selection_probe__";
    let backup = clipboard::snapshot();
    if clipboard::write_transient(SENTINEL).is_err() {
        return None;
    }
    if let Err(e) = inject::send_shortcut('c') {
        log::warn!("Ctrl+C 送出失敗: {e}");
        clipboard::restore(&backup);
        return None;
    }
    let mut selected = None;
    // 慢的 Electron App（Slack / Discord）實測約 100–250 ms
    for _ in 0..30 {
        std::thread::sleep(Duration::from_millis(20));
        if let Some(current) = clipboard::read_text() {
            if current != SENTINEL {
                selected = Some(current);
                break;
            }
        }
    }
    clipboard::restore(&backup);
    selected.filter(|t| !t.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mac_plan_three_states() {
        assert_eq!(
            plan_mac(AxSelection::Text("hi".into()), "com.a", Some("AXTextArea")),
            SelectionPlan::Done(Some("hi".into()))
        );
        // 明確沒選取：不 fallback
        assert_eq!(plan_mac(AxSelection::EmptySelection, "com.a", Some("AXTextArea")), SelectionPlan::Done(None));
        // 不支援 + 文字類 role → fallback
        assert_eq!(plan_mac(AxSelection::Unsupported, "com.a", Some("AXWebArea")), SelectionPlan::ClipboardFallback);
        // 不支援但 role 不是文字類 / 沒 role → 不做
        assert_eq!(plan_mac(AxSelection::Unsupported, "com.a", Some("AXButton")), SelectionPlan::Done(None));
        assert_eq!(plan_mac(AxSelection::Unsupported, "com.a", None), SelectionPlan::Done(None));
        // 黑名單
        assert_eq!(
            plan_mac(AxSelection::Unsupported, "com.googlecode.iterm2", Some("AXTextArea")),
            SelectionPlan::Done(None)
        );
        assert_eq!(
            plan_mac(AxSelection::Unsupported, "com.apple.finder", Some("AXTextField")),
            SelectionPlan::Done(None)
        );
    }
}

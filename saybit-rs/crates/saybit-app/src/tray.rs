//! 系統匣（tray-icon + muda；對照 UI/MenuBar/MenuBarView.swift）。
//! 選單內容由 `TrayModel` 決定，model 有變才整份重建（muda 項目沒有 radio，處理風格／語調用 check 項目模擬）。

use crate::ui::l10n::{t, tf};
use crate::ui::SettingsTab;
use saybit_core::{PromptStyle, ToneStyle};
use tray_icon::menu::{CheckMenuItem, IsMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu};
use tray_icon::{Icon, TrayIcon, TrayIconBuilder};

#[derive(Debug, Clone, PartialEq)]
pub struct TrayModel {
    pub recording: bool,
    pub recording_allowed: bool,
    pub hotkey_label: String,
    /// (id, 顯示名稱含快捷鍵)
    pub modes: Vec<(String, String)>,
    pub prompt_style: PromptStyle,
    pub tone: ToneStyle,
    pub smart_send: bool,
    pub whisper_mode: bool,
    pub api_key_missing: bool,
    pub accessibility_missing: bool,
    pub update_tag: Option<String>,
    /// 語言變了要重建
    pub language: saybit_core::AppLanguage,
}

#[derive(Debug, Clone, PartialEq)]
pub enum TrayAction {
    ToggleRecording,
    RecordWithMode(String),
    SetPromptStyle(PromptStyle),
    SetTone(ToneStyle),
    ToggleSmartSend,
    ToggleWhisperMode,
    OpenApiSettings,
    RequestAccessibility,
    OpenUpdate,
    OpenTab(SettingsTab),
    ReregisterHotkey,
    ResetOverlay,
    Quit,
}

pub const PROMPT_STYLES: [PromptStyle; 2] = [PromptStyle::Typeless, PromptStyle::WisprFlow];
pub const TONES: [ToneStyle; 4] = [ToneStyle::Auto, ToneStyle::Formal, ToneStyle::Casual, ToneStyle::VeryCasual];

pub fn prompt_style_key(s: PromptStyle) -> &'static str {
    match s {
        PromptStyle::Typeless => "typeless",
        PromptStyle::WisprFlow => "wisprFlow",
    }
}

pub fn tone_key(s: ToneStyle) -> &'static str {
    match s {
        ToneStyle::Auto => "auto",
        ToneStyle::Formal => "formal",
        ToneStyle::Casual => "casual",
        ToneStyle::VeryCasual => "veryCasual",
    }
}

pub fn prompt_style_name(s: PromptStyle) -> String {
    t(&format!("style.{}", prompt_style_key(s)))
}

pub fn tone_name(s: ToneStyle) -> String {
    t(&format!("tone.{}", tone_key(s)))
}

/// 選單項目 id → 動作（純邏輯，可測）
pub fn parse_menu_id(id: &str) -> Option<TrayAction> {
    if let Some(mode) = id.strip_prefix("mode:") {
        return Some(TrayAction::RecordWithMode(mode.to_string()));
    }
    if let Some(s) = id.strip_prefix("style:") {
        return PROMPT_STYLES.iter().find(|p| prompt_style_key(**p) == s).map(|p| TrayAction::SetPromptStyle(*p));
    }
    if let Some(s) = id.strip_prefix("tone:") {
        return TONES.iter().find(|p| tone_key(**p) == s).map(|p| TrayAction::SetTone(*p));
    }
    Some(match id {
        "rec.toggle" => TrayAction::ToggleRecording,
        "smart_send" => TrayAction::ToggleSmartSend,
        "whisper" => TrayAction::ToggleWhisperMode,
        "warn.api_key" => TrayAction::OpenApiSettings,
        "warn.accessibility" => TrayAction::RequestAccessibility,
        "update" => TrayAction::OpenUpdate,
        "open.transcribe" => TrayAction::OpenTab(SettingsTab::Transcribe),
        "open.history" => TrayAction::OpenTab(SettingsTab::History),
        "open.settings" => TrayAction::OpenTab(SettingsTab::General),
        "open.logs" => TrayAction::OpenTab(SettingsTab::Logs),
        "trouble.hotkey" => TrayAction::ReregisterHotkey,
        "trouble.overlay" => TrayAction::ResetOverlay,
        "quit" => TrayAction::Quit,
        _ => return None,
    })
}

pub struct Tray {
    icon: TrayIcon,
    last: Option<TrayModel>,
}

fn load_icon() -> Option<(Icon, bool)> {
    #[cfg(target_os = "macos")]
    let (bytes, template): (&[u8], bool) = (include_bytes!("../assets/tray-template@2x.png"), true);
    #[cfg(not(target_os = "macos"))]
    let (bytes, template): (&[u8], bool) = (include_bytes!("../assets/tray-color.png"), false);
    let img = image::load_from_memory(bytes).ok()?.into_rgba8();
    let (w, h) = img.dimensions();
    Icon::from_rgba(img.into_raw(), w, h).ok().map(|i| (i, template))
}

impl Tray {
    /// 必須在事件迴圈已啟動後、在主執行緒呼叫
    pub fn new(model: &TrayModel) -> Option<Self> {
        let (icon, template) = load_icon()?;
        let menu = build_menu(model);
        let builder = TrayIconBuilder::new();
        let builder = if template { builder.with_icon_templated(icon) } else { builder.with_icon(icon) };
        let built = builder
            .with_tooltip("Saybit")
            .with_menu(Box::new(menu))
            .build();
        match built {
            Ok(icon) => Some(Self { icon, last: Some(model.clone()) }),
            Err(e) => {
                crate::applog::error("Tray", format!("無法建立系統匣圖示：{e}"));
                None
            }
        }
    }

    pub fn update(&mut self, model: &TrayModel) {
        if self.last.as_ref() == Some(model) {
            return;
        }
        self.icon.set_menu(Some(Box::new(build_menu(model))));
        self.last = Some(model.clone());
    }
}

fn build_menu(m: &TrayModel) -> Menu {
    let menu = Menu::new();
    let add = |item: &dyn IsMenuItem| {
        let _ = menu.append(item);
    };
    let sep = PredefinedMenuItem::separator;

    // 錄音（引導未完成時只允許停止）
    let rec_label = if m.recording { t("tray.stopRecording") } else { tf("tray.startRecording", &[("hotkey", &m.hotkey_label)]) };
    add(&MenuItem::with_id("rec.toggle", rec_label, m.recording || m.recording_allowed, None));
    if !m.modes.is_empty() {
        let sub = Submenu::new(t("tray.recordWithMode"), m.recording || m.recording_allowed);
        for (id, label) in &m.modes {
            let _ = sub.append(&MenuItem::with_id(format!("mode:{id}"), label, true, None));
        }
        add(&sub);
    }
    add(&sep());

    // 處理風格 / 語調（radio）
    let style = Submenu::new(tf("menu.promptLabel", &[("name", &prompt_style_name(m.prompt_style))]), true);
    for s in PROMPT_STYLES {
        let id = format!("style:{}", prompt_style_key(s));
        let _ = style.append(&CheckMenuItem::with_id(id, prompt_style_name(s), true, s == m.prompt_style, None));
    }
    add(&style);
    let tone = Submenu::new(tf("menu.toneLabel", &[("name", &tone_name(m.tone))]), true);
    for s in TONES {
        let id = format!("tone:{}", tone_key(s));
        let _ = tone.append(&CheckMenuItem::with_id(id, tone_name(s), true, s == m.tone, None));
    }
    add(&tone);
    add(&CheckMenuItem::with_id("smart_send", t("tray.smartSend"), true, m.smart_send, None));
    add(&CheckMenuItem::with_id("whisper", t("tray.whisperMode"), true, m.whisper_mode, None));

    // 只在需要處理時才出現
    if m.api_key_missing || m.accessibility_missing {
        add(&sep());
        if m.api_key_missing {
            add(&MenuItem::with_id("warn.api_key", t("tray.apiKeyMissing"), true, None));
        }
        if m.accessibility_missing {
            add(&MenuItem::with_id("warn.accessibility", t("tray.accessibilityMissing"), true, None));
        }
    }
    if let Some(tag) = &m.update_tag {
        add(&sep());
        add(&MenuItem::with_id("update", tf("menu.updateAvailable", &[("tag", tag)]), true, None));
    }

    add(&sep());
    add(&MenuItem::with_id("open.transcribe", t("tray.fileTranscribe"), true, None));
    add(&MenuItem::with_id("open.history", t("tray.history"), true, None));
    add(&MenuItem::with_id("open.settings", t("tray.settings"), true, None));
    let trouble = Submenu::new(t("tray.troubleshoot"), true);
    let _ = trouble.append(&MenuItem::with_id(
        "trouble.hotkey",
        tf("menu.reregisterHotkey", &[("label", &m.hotkey_label)]),
        true,
        None,
    ));
    let _ = trouble.append(&MenuItem::with_id("trouble.overlay", t("overlay.resetPosition"), true, None));
    let _ = trouble.append(&MenuItem::with_id("open.logs", t("tray.logs"), true, None));
    add(&trouble);
    add(&sep());
    add(&MenuItem::with_id("quit", t("common.quit"), true, None));
    menu
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn menu_ids_round_trip() {
        assert_eq!(parse_menu_id("rec.toggle"), Some(TrayAction::ToggleRecording));
        assert_eq!(parse_menu_id("mode:email"), Some(TrayAction::RecordWithMode("email".into())));
        for s in PROMPT_STYLES {
            assert_eq!(parse_menu_id(&format!("style:{}", prompt_style_key(s))), Some(TrayAction::SetPromptStyle(s)));
        }
        for s in TONES {
            assert_eq!(parse_menu_id(&format!("tone:{}", tone_key(s))), Some(TrayAction::SetTone(s)));
        }
        assert_eq!(parse_menu_id("open.logs"), Some(TrayAction::OpenTab(SettingsTab::Logs)));
        assert_eq!(parse_menu_id("tone:nope"), None);
        assert_eq!(parse_menu_id("bogus"), None);
    }
}

//! 首次引導（對照 UI/Onboarding/OnboardingView.swift 最新版五步）：
//! 語言 → 權限 → 選 AI 方式（雲端 / 自架 Ollama·LM Studio；Rust 版沒有 Apple 本機模型）→ API Key → 完成。
//! 引導畫在主視窗（root viewport）裡；完成後主視窗切回設定並隱藏。

use crate::theme;
use crate::ui::l10n::{set_language, t, tf};
use crossbeam_channel::{Receiver, TryRecvError};
use egui::{Color32, RichText, Ui};
use saybit_core::llm::client::{LlmClient, LlmError};
use saybit_core::llm::providers;
use saybit_core::{secure_store, AppLanguage, Settings};
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Step {
    Language,
    Permissions,
    AiChoice,
    ApiKey,
    Done,
}

const STEPS: [Step; 5] = [Step::Language, Step::Permissions, Step::AiChoice, Step::ApiKey, Step::Done];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AiChoice {
    Cloud,
    Server,
}

/// 引導裡快速選擇的雲端服務商
pub const CLOUD_PROVIDERS: [&str; 4] = ["openrouter", "openai", "deepseek", "groq"];

/// 引導結束時告訴 App 要做什麼
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OnboardingOutcome {
    /// 設定有改（語言、服務商…），App 要存檔並廣播
    SettingsChanged,
    /// API key 已寫入 secure_store
    SecretsChanged,
    /// 按了「開始使用」
    Finished,
}

struct TestResult {
    ok: bool,
    message: String,
    hint: Option<String>,
}

pub struct Onboarding {
    step: Step,
    choice: AiChoice,
    api_key: String,
    show_key: bool,
    key_saved: bool,
    testing: Option<Receiver<TestResult>>,
    test_result: Option<TestResult>,
    accessibility: Option<bool>,
    last_perm_check: Option<Instant>,
    key_loaded_for: Option<String>,
    /// smoke 模式：不碰平台 / 金鑰庫 / 網路
    smoke: bool,
}

impl Onboarding {
    pub fn new(settings: &Settings, smoke: bool) -> Self {
        let choice = if matches!(settings.selected_provider_id.as_str(), "ollama" | "lmstudio") {
            AiChoice::Server
        } else {
            AiChoice::Cloud
        };
        Self {
            step: Step::Language,
            choice,
            api_key: String::new(),
            show_key: false,
            key_saved: false,
            testing: None,
            test_result: None,
            accessibility: None,
            last_perm_check: None,
            key_loaded_for: None,
            smoke,
        }
    }

    /// smoke 截圖用
    pub fn set_step_index(&mut self, i: usize) {
        self.step = STEPS[i.min(STEPS.len() - 1)];
    }

    fn index(&self) -> usize {
        STEPS.iter().position(|s| *s == self.step).unwrap_or(0)
    }

    fn next(&self) -> Step {
        match self.step {
            // 自架伺服器不需要 API Key，跳過那一步
            Step::AiChoice if self.choice != AiChoice::Cloud => Step::Done,
            s => STEPS[(STEPS.iter().position(|x| *x == s).unwrap_or(0) + 1).min(STEPS.len() - 1)],
        }
    }

    fn previous(&self) -> Step {
        match self.step {
            Step::Done if self.choice != AiChoice::Cloud => Step::AiChoice,
            s => STEPS[STEPS.iter().position(|x| *x == s).unwrap_or(0).saturating_sub(1)],
        }
    }

    pub fn ui(&mut self, ui: &mut Ui, settings: &mut Settings) -> Vec<OnboardingOutcome> {
        let mut out = Vec::new();
        self.poll_test(ui.ctx());
        if self.step == Step::Permissions {
            self.refresh_permissions(false);
            ui.ctx().request_repaint_after(Duration::from_secs(2));
        }

        egui::Frame::new().inner_margin(egui::Margin::same(24)).show(ui, |ui| {
            // 標題列
            ui.horizontal(|ui| {
                let title = if self.step == Step::Language { "Saybit".to_string() } else { t("onb.title") };
                ui.heading(RichText::new(title).strong());
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    let i = self.index();
                    if i > 0 {
                        ui.label(
                            RichText::new(tf("onb.stepOf", &[("current", &i.to_string()), ("total", &(STEPS.len() - 1).to_string())]))
                                .color(theme::TEXT_DIM),
                        );
                    }
                });
            });
            ui.separator();

            let footer_h = 44.0;
            let body_h = (ui.available_height() - footer_h).max(100.0);
            egui::ScrollArea::vertical().max_height(body_h).auto_shrink([false, false]).show(ui, |ui| {
                ui.add_space(6.0);
                match self.step {
                    Step::Language => self.language_step(ui, settings, &mut out),
                    Step::Permissions => self.permissions_step(ui),
                    Step::AiChoice => self.ai_choice_step(ui, settings, &mut out),
                    Step::ApiKey => self.api_key_step(ui, settings, &mut out),
                    Step::Done => self.done_step(ui, settings),
                }
            });

            ui.separator();
            ui.horizontal(|ui| {
                if self.step != Step::Language && ui.button(t("common.previous")).clicked() {
                    self.step = self.previous();
                }
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    if self.step == Step::Done {
                        if ui.add(theme::primary_button(t("common.startUsing"))).clicked() {
                            settings.has_completed_onboarding = true;
                            out.push(OnboardingOutcome::SettingsChanged);
                            out.push(OnboardingOutcome::Finished);
                        }
                    } else if ui.add(theme::primary_button(t("common.next"))).clicked() {
                        self.step = self.next();
                        if self.step == Step::Permissions {
                            self.refresh_permissions(true);
                        }
                    }
                });
            });
        });
        out
    }

    // ── 1. 語言 ──
    fn language_step(&mut self, ui: &mut Ui, settings: &mut Settings, out: &mut Vec<OnboardingOutcome>) {
        ui.vertical_centered(|ui| {
            ui.add_space(30.0);
            ui.label(RichText::new("🎤").size(48.0));
            ui.add_space(8.0);
            ui.label(RichText::new(t("onb.chooseLanguage")).size(16.0));
            ui.add_space(16.0);
            for (lang, key) in [
                (AppLanguage::ZhTw, "onb.languageName.zhTw"),
                (AppLanguage::ZhCn, "onb.languageName.zhCn"),
                (AppLanguage::En, "onb.languageName.en"),
                (AppLanguage::Ja, "onb.languageName.ja"),
            ] {
                let selected = settings.app_language == lang;
                let label = if selected { format!("✔  {}", t(key)) } else { t(key) };
                let btn = if selected {
                    theme::primary_button(label)
                } else {
                    egui::Button::new(RichText::new(label))
                };
                if ui.add_sized([240.0, 34.0], btn).clicked() && !selected {
                    settings.app_language = lang;
                    // 辨識語言跟著介面語言（使用者之後可在設定改）
                    settings.language_preference = match lang {
                        AppLanguage::ZhTw => "zh-TW",
                        AppLanguage::ZhCn => "zh-CN",
                        AppLanguage::En => "en-US",
                        AppLanguage::Ja => "ja-JP",
                    }
                    .into();
                    set_language(lang);
                    out.push(OnboardingOutcome::SettingsChanged);
                }
                ui.add_space(4.0);
            }
        });
    }

    // ── 2. 權限 ──
    fn refresh_permissions(&mut self, force: bool) {
        if self.smoke {
            return;
        }
        if !force && self.last_perm_check.is_some_and(|t| t.elapsed() < Duration::from_secs(2)) {
            return;
        }
        self.last_perm_check = Some(Instant::now());
        self.accessibility = saybit_core::platform::accessibility_trusted();
    }

    fn permissions_step(&mut self, ui: &mut Ui) {
        ui.label(RichText::new(t("onb.permissionsTitle")).size(17.0).strong());
        let desc = if cfg!(target_os = "macos") { t("onb.permissionsDesc") } else { t("onb.permissionsDescOther") };
        theme::description(ui, &desc);
        ui.add_space(8.0);
        let smoke = self.smoke;
        let open = |pane: &str| {
            if !smoke {
                saybit_core::platform::open_privacy_settings(pane);
            }
        };
        // 麥克風權限沒有跨平台查詢 API：第一次錄音時由系統詢問
        perm_row(ui, "🎤", &t("onb.micTitle"), &t("onb.micDesc"), None, &mut || open("Privacy_Microphone"));
        if cfg!(target_os = "macos") {
            perm_row(ui, "💬", &t("onb.speechTitle"), &t("onb.speechDesc"), None, &mut || {
                open("Privacy_SpeechRecognition")
            });
            let granted = self.accessibility;
            perm_row(ui, "♿", &t("onb.accessibilityTitle"), &t("onb.accessibilityDesc"), Some(granted.unwrap_or(false)), &mut || {
                if !smoke {
                    saybit_core::platform::request_accessibility();
                    saybit_core::platform::open_privacy_settings("Privacy_Accessibility");
                }
            });
            ui.add_space(6.0);
            if ui.button(t("onb.recheckPermissions")).clicked() {
                self.refresh_permissions(true);
            }
        }
    }

    // ── 3. 選 AI 方式 ──
    fn ai_choice_step(&mut self, ui: &mut Ui, settings: &mut Settings, out: &mut Vec<OnboardingOutcome>) {
        ui.label(RichText::new(t("onb.aiChoiceTitle")).size(17.0).strong());
        theme::description(ui, &t("onb.aiChoiceDesc"));
        ui.add_space(8.0);
        for (choice, icon, title, desc) in [
            (AiChoice::Cloud, "☁", "onb.choiceCloudTitle", "onb.choiceCloudDesc"),
            (AiChoice::Server, "🖥", "onb.choiceServerTitle", "onb.choiceServerDesc"),
        ] {
            let selected = self.choice == choice;
            let frame = theme::glass_card().stroke(egui::Stroke::new(
                if selected { 2.0 } else { 1.0 },
                if selected { theme::ACCENT } else { Color32::from_white_alpha(22) },
            ));
            let resp = frame
                .show(ui, |ui| {
                    ui.set_width(ui.available_width());
                    ui.horizontal_top(|ui| {
                        ui.label(RichText::new(icon).size(20.0).color(if selected { theme::ACCENT } else { theme::TEXT_DIM }));
                        ui.vertical(|ui| {
                            ui.label(RichText::new(t(title)).strong());
                            theme::description(ui, &t(desc));
                        });
                    });
                })
                .response
                .interact(egui::Sense::click());
            if resp.clicked() && !selected {
                self.select_choice(choice, settings);
                out.push(OnboardingOutcome::SettingsChanged);
            }
        }
    }

    fn select_choice(&mut self, choice: AiChoice, settings: &mut Settings) {
        self.choice = choice;
        match choice {
            AiChoice::Server => {
                if !matches!(settings.selected_provider_id.as_str(), "ollama" | "lmstudio") {
                    select_provider(settings, "ollama");
                }
            }
            AiChoice::Cloud => {
                if matches!(settings.selected_provider_id.as_str(), "ollama" | "lmstudio") {
                    select_provider(settings, "openrouter");
                }
            }
        }
    }

    // ── 4. API Key ──
    fn api_key_step(&mut self, ui: &mut Ui, settings: &mut Settings, out: &mut Vec<OnboardingOutcome>) {
        let provider_id = settings.selected_provider_id.clone();
        let provider = providers::find(settings, &provider_id);
        let provider_name = provider.as_ref().map(|p| p.name.clone()).unwrap_or_else(|| provider_id.clone());
        if self.key_loaded_for.as_deref() != Some(provider_id.as_str()) {
            self.key_loaded_for = Some(provider_id.clone());
            self.api_key = if self.smoke { String::new() } else { secure_store::get(&secure_store::llm_account(&provider_id)).unwrap_or_default() };
            self.key_saved = false;
            self.test_result = None;
        }

        ui.label(RichText::new(t("onb.apiKeyTitle")).size(17.0).strong());
        theme::description(ui, &t("onb.apiKeyIntro"));
        ui.add_space(8.0);

        ui.label(RichText::new(t("onb.chooseProvider")).strong());
        let mut list: Vec<&str> = CLOUD_PROVIDERS.to_vec();
        if !list.contains(&provider_id.as_str()) {
            list.push(provider_id.as_str());
        }
        ui.horizontal_wrapped(|ui| {
            for id in &list {
                let name = providers::find(settings, id).map(|p| p.name).unwrap_or_else(|| id.to_string());
                if ui.selectable_label(*id == provider_id, name).clicked() && *id != provider_id {
                    select_provider(settings, id);
                    out.push(OnboardingOutcome::SettingsChanged);
                }
            }
        });
        let blurb = match provider_id.as_str() {
            "openrouter" => Some("onb.blurbOpenRouter"),
            "openai" => Some("onb.blurbOpenAI"),
            "deepseek" => Some("onb.blurbDeepSeek"),
            "groq" => Some("onb.blurbGroq"),
            _ => None,
        };
        if let Some(b) = blurb {
            theme::description(ui, &t(b));
        }
        ui.add_space(6.0);

        theme::glass_card().show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.horizontal(|ui| {
                theme::step_badge(ui, 1);
                ui.label(tf("onb.keyStep1", &[("provider", &provider_name)]));
                if let Some(url) = providers::key_portal_url(&provider_id) {
                    if ui.link(t("onb.openKeyPage")).clicked() && !self.smoke {
                        saybit_core::platform::open_url(url);
                    }
                }
            });
            ui.horizontal(|ui| {
                theme::step_badge(ui, 2);
                ui.label(t("onb.keyStep2"));
            });
            ui.horizontal(|ui| {
                theme::step_badge(ui, 3);
                ui.label(t("onb.keyStep3"));
            });
            if providers::needs_prepaid_credit(&provider_id) {
                ui.label(RichText::new(format!("💳 {}", tf("onb.keyNeedsCredit", &[("provider", &provider_name)]))).color(theme::WARNING).size(12.5));
            }
        });
        ui.add_space(6.0);

        let placeholder = provider.as_ref().map(|p| p.key_placeholder.clone()).filter(|s| !s.is_empty()).unwrap_or_else(|| t("onb.keyPlaceholder"));
        let mut submit = false;
        ui.horizontal(|ui| {
            let edit = egui::TextEdit::singleline(&mut self.api_key)
                .password(!self.show_key)
                .hint_text(placeholder)
                .desired_width(ui.available_width() - 150.0);
            let resp = ui.add(edit);
            if resp.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter)) {
                submit = true;
            }
            let eye = if self.show_key { t("common.hide") } else { t("common.show") };
            if ui.button(eye).clicked() {
                self.show_key = !self.show_key;
            }
            if ui.button(t("onb.paste")).on_hover_text(t("onb.pasteFromClipboard")).clicked() && !self.smoke {
                // 交給 egui 貼到欄位（不另外讀剪貼簿）
                resp.request_focus();
                ui.ctx().send_viewport_cmd(egui::ViewportCommand::RequestPaste);
            }
        });

        ui.horizontal(|ui| {
            let testing = self.testing.is_some();
            let label = if testing { t("onb.testing") } else { t("onb.saveAndTest") };
            let enabled = !self.api_key.trim().is_empty() && !testing;
            if ui.add_enabled(enabled, theme::primary_button(label)).clicked() {
                submit = true;
            }
            if testing {
                ui.spinner();
            }
            if self.key_saved && self.test_result.is_none() && !testing {
                ui.label(RichText::new(format!("✔ {}", t("onb.apiKeySaved"))).color(theme::SUCCESS));
            }
        });
        if submit
            && self.testing.is_none()
            && !self.api_key.trim().is_empty()
            && self.save_and_test(ui.ctx(), settings)
        {
            out.push(OnboardingOutcome::SecretsChanged);
        }

        if let Some(r) = &self.test_result {
            let color = if r.ok { theme::SUCCESS } else { theme::DANGER };
            egui::Frame::new()
                .fill(color.linear_multiply(0.12))
                .corner_radius(8)
                .inner_margin(8)
                .show(ui, |ui| {
                    ui.set_width(ui.available_width());
                    ui.label(RichText::new(&r.message).color(color));
                    if let Some(h) = &r.hint {
                        theme::description(ui, h);
                    }
                });
        }
        ui.add_space(4.0);
        theme::description(ui, &t("onb.skipKeyHint"));
    }

    /// 存 key 並在背景測試；回傳是否有寫入 secure_store
    fn save_and_test(&mut self, ctx: &egui::Context, settings: &mut Settings) -> bool {
        let key = self.api_key.trim().to_string();
        let id = settings.selected_provider_id.clone();
        if self.smoke {
            return false;
        }
        if let Err(e) = secure_store::set(&secure_store::llm_account(&id), &key) {
            crate::applog::error("Onboarding", format!("API key 儲存失敗：{e}"));
            self.test_result = Some(TestResult { ok: false, message: t("common.saveFailed"), hint: None });
            return false;
        }
        self.api_key = key.clone();
        self.key_saved = true;
        self.test_result = None;
        let Some(provider) = providers::find(settings, &id) else { return true };
        let model = if settings.selected_model.trim().is_empty() {
            providers::default_model(&id).unwrap_or_default().to_string()
        } else {
            settings.selected_model.clone()
        };
        let (tx, rx) = crossbeam_channel::bounded(1);
        let ctx = ctx.clone();
        let name = provider.name.clone();
        std::thread::spawn(move || {
            let result = LlmClient::new().test_connection(&provider, Some(&key), &model);
            let r = match result {
                Ok(()) => TestResult { ok: true, message: t("onb.testSuccess"), hint: None },
                Err(e) => TestResult { ok: false, message: tf("onb.testFailed", &[("error", &e.to_string())]), hint: hint_for(&e, &name) },
            };
            let _ = tx.send(r);
            ctx.request_repaint();
        });
        self.testing = Some(rx);
        true
    }

    fn poll_test(&mut self, ctx: &egui::Context) {
        let Some(rx) = &self.testing else { return };
        match rx.try_recv() {
            Ok(r) => {
                self.test_result = Some(r);
                self.testing = None;
            }
            Err(TryRecvError::Empty) => ctx.request_repaint_after(Duration::from_millis(200)),
            Err(TryRecvError::Disconnected) => self.testing = None,
        }
    }

    // ── 5. 完成 ──
    fn done_step(&mut self, ui: &mut Ui, settings: &Settings) {
        ui.label(RichText::new(t("onb.doneTitle")).size(17.0).strong());
        ui.add_space(8.0);
        let hotkey = crate::hotkeys::display_label(&settings.hotkey);
        for (icon, text) in [
            ("⌨", tf("onb.doneHotkey", &[("hotkey", &hotkey)])),
            ("⚙", t("onb.doneSettings")),
            ("🎧", t("onb.doneOffline")),
        ] {
            ui.horizontal_top(|ui| {
                ui.label(RichText::new(icon).size(16.0).color(theme::ACCENT));
                ui.add(egui::Label::new(text).wrap());
            });
            ui.add_space(4.0);
        }
        let warn = |ui: &mut Ui, text: String| {
            ui.label(RichText::new(format!("⚠ {text}")).color(theme::WARNING));
        };
        let key_missing = self.choice == AiChoice::Cloud
            && !self.smoke
            && secure_store::get(&secure_store::llm_account(&settings.selected_provider_id)).is_none_or(|k| k.trim().is_empty());
        if key_missing {
            warn(ui, t("onb.doneNoKeyWarning"));
        }
        if self.choice == AiChoice::Server {
            warn(ui, t("onb.doneServerHint"));
        }
        if cfg!(target_os = "macos") && self.accessibility == Some(false) {
            warn(ui, format!("{}：{}", t("onb.accessibilityTitle"), t("common.notSet")));
        }
    }
}

fn select_provider(settings: &mut Settings, id: &str) {
    settings.selected_provider_id = id.to_string();
    if let Some(m) = providers::default_model(id) {
        settings.selected_model = m.to_string();
    }
}

fn perm_row(ui: &mut Ui, icon: &str, title: &str, desc: &str, granted: Option<bool>, open: &mut dyn FnMut()) {
    theme::glass_card().show(ui, |ui| {
        ui.set_width(ui.available_width());
        ui.horizontal(|ui| {
            ui.label(RichText::new(icon).size(18.0));
            ui.vertical(|ui| {
                ui.label(RichText::new(title).strong());
                theme::description(ui, desc);
            });
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                match granted {
                    Some(true) => {
                        ui.label(RichText::new(format!("✔ {}", t("onb.granted"))).color(theme::SUCCESS));
                    }
                    Some(false) => {
                        if ui.button(t("common.openSettings")).clicked() {
                            open();
                        }
                        ui.label(RichText::new(t("onb.notGranted")).color(theme::WARNING));
                    }
                    None => {
                        if ui.button(t("common.openSettings")).clicked() {
                            open();
                        }
                        ui.label(RichText::new(t("onb.micAskOnFirstUse")).color(theme::TEXT_DIM).size(12.0));
                    }
                }
            });
        });
    });
}

/// 401 / 402 / 網路錯誤給一句白話提示
pub fn hint_for(err: &anyhow::Error, provider_name: &str) -> Option<String> {
    match err.downcast_ref::<LlmError>()? {
        LlmError::Http { status: 401 | 403, .. } => Some(t("onb.testHint401")),
        LlmError::Http { status: 402, .. } => Some(tf("onb.testHint402", &[("provider", provider_name)])),
        LlmError::Network(_) => Some(t("onb.testHintNetwork")),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn server_choice_skips_api_key_step() {
        let mut o = Onboarding::new(&Settings::default(), true);
        o.step = Step::AiChoice;
        o.choice = AiChoice::Server;
        assert_eq!(o.next(), Step::Done);
        o.step = Step::Done;
        assert_eq!(o.previous(), Step::AiChoice);
        o.choice = AiChoice::Cloud;
        o.step = Step::AiChoice;
        assert_eq!(o.next(), Step::ApiKey);
        o.step = Step::Done;
        assert_eq!(o.previous(), Step::ApiKey);
    }

    #[test]
    fn http_errors_map_to_hints() {
        let e: anyhow::Error = LlmError::Http { status: 402, detail: String::new() }.into();
        assert!(hint_for(&e, "OpenRouter").unwrap().contains("OpenRouter"));
        let e: anyhow::Error = LlmError::Http { status: 401, detail: String::new() }.into();
        assert!(hint_for(&e, "x").is_some());
        let e: anyhow::Error = LlmError::Network("dns".into()).into();
        assert!(hint_for(&e, "x").is_some());
        let e: anyhow::Error = anyhow::anyhow!("other");
        assert!(hint_for(&e, "x").is_none());
    }
}

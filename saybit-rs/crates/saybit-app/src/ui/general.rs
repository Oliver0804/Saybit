//! 一般分頁（移植 GeneralSettingsView.swift 七卡：錄音／語音辨識／AI 理解／輸出／介面／系統／權限）
use super::l10n::{t, tf};
use super::widgets::{self, BgTask, SecretField};
use crate::app::AppState;
use egui::{RichText, Ui};
use saybit_core::audio::AudioEngine;
use saybit_core::models::ModelManager;
use saybit_core::*;
use std::collections::HashMap;

mod keys {
    pub const RECORDING: &[&str] = &[
        "錄音", "录音", "recording", "輸入裝置", "输入设备", "input", "device", "麥克風", "麦克风", "microphone", "mic", "靈敏度",
        "灵敏度", "sensitivity", "gain", "自動停止", "auto stop", "靜音", "silence", "自动停止", "音量", "volume", "duck", "音效", "sound",
    ];
    pub const RECOGNITION: &[&str] = &[
        "語音辨識", "语音识别", "speech", "STT", "engine", "whisper", "引擎", "sensevoice", "離線", "offline", "降噪", "noise",
        "模型", "model", "下載", "download", "groq", "openai", "阿里", "alibaba", "訊飛", "xunfei", "串流", "streaming", "apple",
    ];
    pub const AI: &[&str] = &[
        "AI", "上下文", "context", "選取", "selected", "嘈雜", "noisy", "whisper", "語氣", "tone", "規則", "rule",
    ];
    pub const OUTPUT: &[&str] = &[
        "輸出", "注入", "inject", "貼上", "paste", "keypress", "逐字", "取代", "replace", "預覽", "preview", "预览", "smart send",
        "智慧送出", "倒數", "countdown", "自動送出", "自动发送", "enter",
    ];
    pub const INTERFACE: &[&str] = &[
        "介面", "語言", "语言", "language", "言語", "膠囊", "胶囊", "capsule", "大小", "size", "縮放", "scale",
    ];
    pub const SYSTEM: &[&str] = &[
        "系統", "開機", "啟動", "登入", "launch", "login", "startup", "开机", "启动", "更新", "update", "version", "版本", "歷史",
        "history", "清理", "cleanup", "保留", "retention", "历史", "教學", "tutorial", "教程",
    ];
    pub const PERMISSIONS: &[&str] = &[
        "權限", "permission", "accessibility", "輔助使用", "麥克風", "microphone", "权限", "語音辨識", "speech",
    ];
    pub const ALL: &[&[&str]] = &[RECORDING, RECOGNITION, AI, OUTPUT, INTERFACE, SYSTEM, PERMISSIONS];
}

pub fn all_keywords() -> Vec<&'static str> {
    keys::ALL.iter().flat_map(|k| k.iter().copied()).collect()
}

pub enum DownloadMsg {
    Progress(f32),
    Done(Result<(), String>),
}

#[derive(Default)]
pub struct GeneralState {
    devices: Option<Vec<AudioDevice>>,
    supported: Option<Vec<SttEngineKind>>,
    mic_test: Option<AudioEngine>,
    mic_test_error: Option<String>,
    models: Option<ModelManager>,
    model_states: HashMap<ModelKind, ModelState>,
    downloads: HashMap<ModelKind, (BgTask<DownloadMsg>, f32)>,
    confirm_delete: Option<ModelKind>,
    stt_key: SecretField,
    accessibility: Option<Option<bool>>,
    rules_open: bool,
}

impl GeneralState {
    fn model_state(&mut self, kind: ModelKind) -> ModelState {
        if let Some((_, p)) = self.downloads.get(&kind) {
            return ModelState::Downloading { progress: *p };
        }
        if !self.model_states.contains_key(&kind) {
            let mm = self.models.get_or_insert_with(ModelManager::new);
            self.model_states.insert(kind, mm.state(kind));
        }
        self.model_states.get(&kind).cloned().unwrap_or(ModelState::NotInstalled)
    }
}

/// 離開一般分頁（或關閉設定視窗）時停掉麥克風測試
pub fn on_leave(g: &mut GeneralState) {
    if let Some(engine) = g.mic_test.take() {
        engine.stop();
    }
}

pub fn stt_engine_name(kind: SttEngineKind) -> String {
    t(match kind {
        SttEngineKind::SenseVoice => "enum.stt.senseVoice",
        SttEngineKind::WhisperLocal => "enum.stt.whisperLocal",
        SttEngineKind::CloudWhisper => "enum.stt.cloudWhisper",
        SttEngineKind::Streaming => "enum.stt.streaming",
        SttEngineKind::Apple => "enum.stt.apple",
    })
}

pub fn injection_mode_name(m: InjectionMode) -> String {
    let paste_mod = if cfg!(target_os = "macos") { "Cmd+V" } else { "Ctrl+V" };
    match m {
        InjectionMode::Paste => tf("enum.inject.paste", &[("shortcut", paste_mod)]),
        InjectionMode::Keypress => t("enum.inject.keypress"),
        InjectionMode::ReplaceSelection => t("enum.inject.replaceSelection"),
    }
}

pub fn tone_name(tone: ToneStyle) -> String {
    t(match tone {
        ToneStyle::Auto => "enum.tone.auto",
        ToneStyle::Formal => "enum.tone.formal",
        ToneStyle::Casual => "enum.tone.casual",
        ToneStyle::VeryCasual => "enum.tone.veryCasual",
    })
}

fn seconds(v: f32) -> String {
    format!("{v:.1} {}", t("general.seconds"))
}

const ALL_ENGINES: [SttEngineKind; 5] = [
    SttEngineKind::SenseVoice,
    SttEngineKind::WhisperLocal,
    SttEngineKind::CloudWhisper,
    SttEngineKind::Streaming,
    SttEngineKind::Apple,
];

const LANGUAGE_PREFS: [(&str, &str); 4] =
    [("zh-TW", "繁體中文（台灣）"), ("zh-CN", "简体中文"), ("en-US", "English"), ("ja-JP", "日本語")];

const APP_LANGUAGES: [(AppLanguage, &str); 4] = [
    (AppLanguage::ZhTw, "繁體中文"),
    (AppLanguage::ZhCn, "简体中文"),
    (AppLanguage::En, "English"),
    (AppLanguage::Ja, "日本語"),
];

pub fn show(ui: &mut Ui, state: &mut AppState) {
    poll_downloads(state);
    let q = state.ui.search.clone();
    let shows = |k: &[&str]| widgets::matches_search(k, &q);
    super::scroll_page(ui, "general", |ui| {
        if shows(keys::RECORDING) {
            recording_card(ui, state);
        }
        if shows(keys::RECOGNITION) {
            recognition_card(ui, state);
        }
        if shows(keys::AI) {
            ai_card(ui, state);
        }
        if shows(keys::OUTPUT) {
            output_card(ui, state);
        }
        if shows(keys::INTERFACE) {
            interface_card(ui, state);
        }
        if shows(keys::SYSTEM) {
            system_card(ui, state);
        }
        if shows(keys::PERMISSIONS) {
            permissions_card(ui, state);
        }
        if !q.trim().is_empty() && !keys::ALL.iter().any(|k| shows(k)) {
            widgets::no_results(ui);
        }
    });
    delete_model_dialog(ui.ctx(), state);
}

// ───────────────────────────── 錄音 ─────────────────────────────

fn recording_card(ui: &mut Ui, state: &mut AppState) {
    let s = &mut state.settings;
    let g = &mut state.ui.general;
    widgets::card(ui, |ui| {
        widgets::section_header(ui, "🎤", &t("general.sectionRecording"));

        let devices = g.devices.get_or_insert_with(AudioEngine::list_input_devices).clone();
        let missing = s.input_device_id.as_ref().is_some_and(|id| !devices.iter().any(|d| &d.id == id));
        widgets::setting_row(ui, &t("general.inputDevice"), Some(&t("general.selectMicDesc")), |ui| {
            if ui.small_button("⟳").on_hover_text(t("common.recheck")).clicked() {
                g.devices = None;
            }
            let selected = match &s.input_device_id {
                None => t("general.systemDefault"),
                Some(id) => devices
                    .iter()
                    .find(|d| &d.id == id)
                    .map(|d| d.name.clone())
                    .unwrap_or_else(|| t("general.deviceUnavailable")),
            };
            egui::ComboBox::from_id_salt("input_device").selected_text(selected).width(220.0).show_ui(ui, |ui| {
                ui.selectable_value(&mut s.input_device_id, None, t("general.systemDefault"));
                for d in &devices {
                    let label = if d.is_default { format!("{} ✓", d.name) } else { d.name.clone() };
                    ui.selectable_value(&mut s.input_device_id, Some(d.id.clone()), label);
                }
            });
        });
        if missing {
            widgets::warn_label(ui, &t("general.deviceUnavailable"));
        }

        // 麥克風測試：自己開一個 AudioEngine 看音量
        ui.horizontal(|ui| {
            let testing = g.mic_test.is_some();
            let label = if testing { t("general.stopTest") } else { t("general.testMic") };
            if ui.button(label).clicked() {
                if testing {
                    if let Some(engine) = g.mic_test.take() {
                        engine.stop();
                    }
                } else {
                    let engine = AudioEngine::new();
                    match engine.start(s.input_device_id.as_deref(), s.enable_voice_bandpass, s.mic_sensitivity) {
                        Ok(()) => {
                            g.mic_test = Some(engine);
                            g.mic_test_error = None;
                        }
                        Err(e) => g.mic_test_error = Some(e.to_string()),
                    }
                }
            }
            if let Some(engine) = &g.mic_test {
                let level = engine.level().clamp(0.0, 1.0);
                ui.add(egui::ProgressBar::new(level).desired_width(ui.available_width().min(260.0)));
                ui.ctx().request_repaint_after(std::time::Duration::from_millis(50));
            }
        });
        if g.mic_test.is_some() {
            widgets::description(ui, &t("general.micTestHint"));
        }
        if let Some(e) = &g.mic_test_error {
            widgets::warn_label(ui, e);
        }

        widgets::setting_slider(
            ui,
            &t("general.gainMultiplier"),
            &format!("{:.1}x", s.mic_sensitivity),
            &mut s.mic_sensitivity,
            0.5..=5.0,
            0.5,
            Some(&t("general.micSensitivityDesc")),
        );

        widgets::setting_toggle(ui, &t("general.enableAutoStop"), Some(&t("general.silenceAutoStopDesc")), &mut s.enable_auto_stop);
        if s.enable_auto_stop {
            widgets::setting_indent(ui, |ui| {
                let txt = seconds(s.silence_timeout_secs);
                widgets::setting_slider(ui, &t("general.silenceTimeout"), &txt, &mut s.silence_timeout_secs, 0.5..=5.0, 0.5, None);
            });
        }
        widgets::setting_toggle(ui, &t("general.ducking"), Some(&t("general.duckingDesc")), &mut s.enable_ducking);
        widgets::setting_toggle(ui, &t("general.soundFeedback"), None, &mut s.enable_sound_feedback);
    });
}

// ───────────────────────────── 語音辨識 ─────────────────────────────

fn recognition_card(ui: &mut Ui, state: &mut AppState) {
    let mut secrets_changed = false;
    widgets::card(ui, |ui| {
        widgets::section_header(ui, "〰", &t("general.sectionRecognition"));
        let supported = state.ui.general.supported.get_or_insert_with(stt::supported_kinds).clone();
        let s = &mut state.settings;
        widgets::setting_row(ui, &t("general.sttEnginePicker"), None, |ui| {
            egui::ComboBox::from_id_salt("stt_engine").selected_text(stt_engine_name(s.stt_engine)).width(220.0).show_ui(
                ui,
                |ui| {
                    for kind in ALL_ENGINES {
                        let ok = supported.contains(&kind);
                        ui.add_enabled_ui(ok, |ui| {
                            let r = ui.selectable_value(&mut s.stt_engine, kind, stt_engine_name(kind));
                            if !ok {
                                r.on_disabled_hover_text(t("general.engineUnsupported"));
                            }
                        });
                    }
                },
            );
        });
        if !supported.contains(&s.stt_engine) {
            widgets::warn_label(ui, &t("general.engineUnsupported"));
        }

        match state.settings.stt_engine {
            SttEngineKind::SenseVoice => {
                model_row(ui, state, ModelKind::SenseVoice, &t("sherpa.modelTitle"), &t("sherpa.modelDesc"));
            }
            SttEngineKind::WhisperLocal => {
                model_row(ui, state, ModelKind::WhisperLocal, &t("general.whisperLocalTitle"), &t("general.whisperLocalDesc"));
            }
            SttEngineKind::CloudWhisper => {
                secrets_changed |= cloud_whisper_section(ui, state);
            }
            SttEngineKind::Streaming => {
                secrets_changed |= streaming_section(ui, state);
            }
            SttEngineKind::Apple => {
                widgets::setting_toggle(
                    ui,
                    &t("general.onDeviceSTT"),
                    Some(&t("general.onDeviceSTTDesc")),
                    &mut state.settings.apple_on_device_only,
                );
            }
        }

        widgets::setting_toggle(
            ui,
            &t("general.voiceBandpass"),
            Some(&t("general.voiceBandpassDesc")),
            &mut state.settings.enable_voice_bandpass,
        );
    });
    if secrets_changed {
        super::mark_secrets_dirty(state);
    }
}

fn cloud_whisper_section(ui: &mut Ui, state: &mut AppState) -> bool {
    let s = &mut state.settings;
    let g = &mut state.ui.general;
    widgets::setting_row(ui, &t("general.whisperProvider"), None, |ui| {
        let before = s.whisper_cloud_provider.clone();
        let name = |p: &str| match p {
            "groq" => "Groq".to_string(),
            "custom" => t("general.whisperCustom"),
            _ => "OpenAI".to_string(),
        };
        egui::ComboBox::from_id_salt("whisper_provider").selected_text(name(&s.whisper_cloud_provider)).show_ui(ui, |ui| {
            for p in ["openai", "groq", "custom"] {
                ui.selectable_value(&mut s.whisper_cloud_provider, p.to_string(), name(p));
            }
        });
        if before != s.whisper_cloud_provider {
            match s.whisper_cloud_provider.as_str() {
                "openai" => {
                    s.whisper_cloud_base_url = "https://api.openai.com/v1".into();
                    s.whisper_cloud_model = "whisper-1".into();
                }
                "groq" => {
                    s.whisper_cloud_base_url = "https://api.groq.com/openai/v1".into();
                    s.whisper_cloud_model = "whisper-large-v3-turbo".into();
                }
                _ => {}
            }
        }
    });
    if s.whisper_cloud_provider == "custom" {
        ui.horizontal(|ui| {
            ui.label("Base URL");
            ui.add(egui::TextEdit::singleline(&mut s.whisper_cloud_base_url).desired_width(ui.available_width()));
        });
        base_url_hint(ui, &s.whisper_cloud_base_url);
    }
    ui.horizontal(|ui| {
        ui.label(t("api.model"));
        ui.add(egui::TextEdit::singleline(&mut s.whisper_cloud_model).desired_width(220.0));
    });
    ui.label(t("general.whisperAPIKey"));
    let account = secure_store::stt_account(&s.whisper_cloud_provider);
    let changed = g.stt_key.ui(ui, &account, "sk-…");
    widgets::description(ui, &t("general.whisperDesc"));
    changed
}

fn streaming_section(ui: &mut Ui, state: &mut AppState) -> bool {
    let s = &mut state.settings;
    let g = &mut state.ui.general;
    let name = |p: StreamingProvider| match p {
        StreamingProvider::Alibaba => t("enum.streaming.alibaba"),
        StreamingProvider::Xunfei => t("enum.streaming.xunfei"),
    };
    widgets::setting_row(ui, &t("general.streamingProvider"), None, |ui| {
        egui::ComboBox::from_id_salt("streaming_provider").selected_text(name(s.streaming_provider)).show_ui(ui, |ui| {
            for p in [StreamingProvider::Alibaba, StreamingProvider::Xunfei] {
                ui.selectable_value(&mut s.streaming_provider, p, name(p));
            }
        });
    });
    let (account, hint) = match s.streaming_provider {
        StreamingProvider::Alibaba => (secure_store::stt_account("alibaba"), "sk-…"),
        StreamingProvider::Xunfei => (secure_store::stt_account("xunfei"), "appid:apikey"),
    };
    ui.label("API Key");
    let changed = g.stt_key.ui(ui, &account, hint);
    widgets::description(ui, &t("general.streamingDesc"));
    changed
}

/// http(s) 端點檢查提示（共用：AI 分頁自訂端點也用）
pub fn base_url_hint(ui: &mut Ui, url: &str) -> settings::BaseUrlValidation {
    let v = settings::validate_base_url(url);
    match v {
        settings::BaseUrlValidation::Ok => {
            if url.trim_start().to_ascii_lowercase().starts_with("http://") {
                widgets::info_label(ui, &t("api.localHTTPNote"));
            }
        }
        settings::BaseUrlValidation::InsecureRemote => widgets::warn_label(ui, &t("api.insecureURLWarning")),
        settings::BaseUrlValidation::Invalid => {
            if !url.trim().is_empty() {
                widgets::warn_label(ui, &t("api.invalidURL"));
            }
        }
    }
    v
}

fn model_row(ui: &mut Ui, state: &mut AppState, kind: ModelKind, title: &str, desc: &str) {
    let g = &mut state.ui.general;
    let st = g.model_state(kind);
    let size = widgets::format_bytes(ModelManager::total_bytes(kind));
    widgets::setting_row(ui, title, Some(desc), |ui| match &st {
        ModelState::Installed => {
            ui.menu_button("⋯", |ui| {
                if ui.button(t("sherpa.showInFinder")).clicked() {
                    let dir = g.models.get_or_insert_with(ModelManager::new).dir(kind);
                    platform::reveal_in_file_manager(&dir);
                    ui.close();
                }
                if ui.button(tf("sherpa.deleteModel", &[("size", &size)])).clicked() {
                    g.confirm_delete = Some(kind);
                    ui.close();
                }
            })
            .response
            .on_hover_text(t("sherpa.moreActions"));
            widgets::status_label(ui, true, &t("sherpa.installed"));
        }
        ModelState::NotInstalled => {
            if ui.button(format!("⬇ {}", tf("sherpa.download", &[("size", &size)]))).clicked() {
                start_download(ui.ctx(), g, kind);
            }
        }
        ModelState::Downloading { progress } => {
            if ui.button(t("common.cancel")).clicked() {
                if let Some((task, _)) = g.downloads.get(&kind) {
                    task.cancel.cancel();
                }
            }
            ui.add(egui::ProgressBar::new(*progress).show_percentage().desired_width(160.0));
        }
        ModelState::Failed(msg) => {
            if ui.button(t("sherpa.retry")).clicked() {
                start_download(ui.ctx(), g, kind);
            }
            ui.label(RichText::new(msg).color(ui.visuals().error_fg_color)).on_hover_text(msg);
        }
        ModelState::Unsupported(msg) => {
            ui.label(RichText::new(msg).color(ui.visuals().weak_text_color()));
        }
    });
}

fn start_download(ctx: &egui::Context, g: &mut GeneralState, kind: ModelKind) {
    let task = BgTask::spawn(ctx, move |tx, cancel| {
        let mm = ModelManager::new();
        let mut last = -1.0f32;
        let res = mm.download(
            kind,
            &mut |p| {
                if (p - last).abs() >= 0.005 || p >= 1.0 {
                    last = p;
                    tx.send(DownloadMsg::Progress(p));
                }
            },
            &cancel,
        );
        tx.send(DownloadMsg::Done(res.map_err(|e| e.to_string())));
    });
    g.downloads.insert(kind, (task, 0.0));
}

fn poll_downloads(state: &mut AppState) {
    let g = &mut state.ui.general;
    let mut finished = Vec::new();
    for (kind, (task, progress)) in g.downloads.iter_mut() {
        for msg in task.poll() {
            match msg {
                DownloadMsg::Progress(p) => *progress = p,
                DownloadMsg::Done(r) => finished.push((*kind, r, task.cancel.is_cancelled())),
            }
        }
    }
    for (kind, r, cancelled) in finished {
        g.downloads.remove(&kind);
        g.model_states.remove(&kind);
        if let Err(e) = r {
            if !cancelled {
                g.model_states.insert(kind, ModelState::Failed(e));
            }
        }
    }
}

fn delete_model_dialog(ctx: &egui::Context, state: &mut AppState) {
    let g = &mut state.ui.general;
    let Some(kind) = g.confirm_delete else { return };
    let size = widgets::format_bytes(ModelManager::total_bytes(kind));
    let mut close = false;
    egui::Modal::new(egui::Id::unique("delete_model_modal")).show(ctx, |ui| {
        ui.set_max_width(360.0);
        ui.heading(t("sherpa.deleteConfirmTitle"));
        ui.label(tf("sherpa.deleteConfirmMessage", &[("size", &size)]));
        ui.horizontal(|ui| {
            if ui.button(RichText::new(t("common.delete")).color(ui.visuals().error_fg_color)).clicked() {
                let mm = g.models.get_or_insert_with(ModelManager::new);
                if let Err(e) = mm.delete(kind) {
                    log::warn!("delete model failed: {e}");
                }
                g.model_states.remove(&kind);
                close = true;
            }
            if ui.button(t("common.cancel")).clicked() {
                close = true;
            }
        });
    });
    if close {
        g.confirm_delete = None;
    }
}

// ───────────────────────────── AI 理解 ─────────────────────────────

fn ai_card(ui: &mut Ui, state: &mut AppState) {
    let s = &mut state.settings;
    let g = &mut state.ui.general;
    widgets::card(ui, |ui| {
        widgets::section_header(ui, "✨", &t("general.sectionAI"));
        widgets::setting_toggle(
            ui,
            &t("general.contextAwareness"),
            Some(&t("general.contextAwarenessDesc")),
            &mut s.enable_context_awareness,
        );
        if s.enable_context_awareness {
            widgets::setting_indent(ui, |ui| {
                widgets::setting_row(ui, &t("general.contextRules"), Some(&t("general.contextRulesDesc")), |ui| {
                    let label = if g.rules_open { t("common.done") } else { t("general.contextRulesManage") };
                    if ui.button(label).clicked() {
                        g.rules_open = !g.rules_open;
                    }
                });
                if g.rules_open {
                    context_rules_editor(ui, &mut s.context_rules);
                }
            });
        }
        widgets::setting_toggle(ui, &t("general.whisperMode"), Some(&t("general.whisperModeDesc")), &mut s.enable_whisper_mode);
    });
}

const RULE_APPS: [&str; 8] = ["slack", "mail", "terminal", "vscode", "discord", "line", "notion", "browser"];

fn context_rules_editor(ui: &mut Ui, rules: &mut Vec<ContextRule>) {
    if rules.is_empty() {
        widgets::description(ui, &t("general.contextRulesEmpty"));
    }
    let mut remove = None;
    for (i, rule) in rules.iter_mut().enumerate() {
        egui::Frame::group(ui.style()).show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.horizontal(|ui| {
                widgets::toggle_switch(ui, &mut rule.enabled).on_hover_text(t("general.contextRuleEnabled"));
                ui.label(t("general.contextRuleApp"));
                ui.add(egui::TextEdit::singleline(&mut rule.app_identifier).desired_width(140.0).hint_text("slack"));
                egui::ComboBox::from_id_salt(("rule_app", i)).selected_text("▾").width(30.0).show_ui(ui, |ui| {
                    for app in RULE_APPS {
                        ui.selectable_value(&mut rule.app_identifier, app.to_string(), app);
                    }
                });
                ui.label(t("general.contextRuleTone"));
                let label = rule.tone_override.map(tone_name).unwrap_or_else(|| "—".into());
                egui::ComboBox::from_id_salt(("rule_tone", i)).selected_text(label).show_ui(ui, |ui| {
                    ui.selectable_value(&mut rule.tone_override, None, "—");
                    for tone in [ToneStyle::Formal, ToneStyle::Casual, ToneStyle::VeryCasual] {
                        ui.selectable_value(&mut rule.tone_override, Some(tone), tone_name(tone));
                    }
                });
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    if ui.small_button("🗑").on_hover_text(t("common.delete")).clicked() {
                        remove = Some(i);
                    }
                });
            });
            ui.add(
                egui::TextEdit::multiline(&mut rule.extra_prompt)
                    .hint_text(t("general.contextRulePromptPlaceholder"))
                    .desired_rows(2)
                    .desired_width(f32::INFINITY),
            );
        });
    }
    if let Some(i) = remove {
        rules.remove(i);
    }
    if ui.button(format!("＋ {}", t("general.contextRuleAddNew"))).clicked() {
        rules.push(ContextRule {
            id: new_id(),
            app_identifier: String::new(),
            tone_override: None,
            extra_prompt: String::new(),
            enabled: true,
        });
    }
}

/// 不引入 uuid：時間戳＋亂數夠用（只當 Vec 內的識別）
pub fn new_id() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let n = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    format!("{n:x}")
}

// ───────────────────────────── 輸出 ─────────────────────────────

fn output_card(ui: &mut Ui, state: &mut AppState) {
    let s = &mut state.settings;
    widgets::card(ui, |ui| {
        widgets::section_header(ui, "⌶", &t("general.sectionOutput"));
        widgets::setting_row(ui, &t("general.injectionMode"), Some(&t("general.injectionModeDesc")), |ui| {
            egui::ComboBox::from_id_salt("inject_mode").selected_text(injection_mode_name(s.injection_mode)).show_ui(ui, |ui| {
                for m in [InjectionMode::Paste, InjectionMode::Keypress, InjectionMode::ReplaceSelection] {
                    ui.selectable_value(&mut s.injection_mode, m, injection_mode_name(m));
                }
            });
        });
        widgets::setting_toggle(ui, &t("general.enablePreview"), Some(&t("general.previewDesc")), &mut s.enable_preview_before_inject);
        if s.enable_preview_before_inject {
            widgets::setting_indent(ui, |ui| {
                let txt = seconds(s.preview_timeout_secs);
                widgets::setting_slider(
                    ui,
                    &t("general.previewTimeout"),
                    &txt,
                    &mut s.preview_timeout_secs,
                    1.0..=10.0,
                    0.5,
                    Some(&t("general.previewTimeoutDesc")),
                );
            });
        }
        widgets::setting_toggle(ui, &t("general.enableSmartSend"), Some(&t("general.smartSendDesc")), &mut s.enable_smart_send);
        if s.enable_smart_send {
            widgets::setting_indent(ui, |ui| {
                let txt = seconds(s.smart_send_delay_secs);
                widgets::setting_slider(
                    ui,
                    &t("general.countdownSeconds"),
                    &txt,
                    &mut s.smart_send_delay_secs,
                    1.0..=10.0,
                    0.5,
                    Some(&t("general.smartSendCancelHint")),
                );
            });
        }
    });
}

// ───────────────────────────── 介面 ─────────────────────────────

fn interface_card(ui: &mut Ui, state: &mut AppState) {
    let s = &mut state.settings;
    widgets::card(ui, |ui| {
        widgets::section_header(ui, "🖵", &t("general.sectionInterface"));
        widgets::setting_row(ui, &t("general.appLanguage"), None, |ui| {
            let cur = APP_LANGUAGES.iter().find(|(l, _)| *l == s.app_language).map(|(_, n)| *n).unwrap_or("");
            egui::ComboBox::from_id_salt("app_language").selected_text(cur).show_ui(ui, |ui| {
                for (l, n) in APP_LANGUAGES {
                    ui.selectable_value(&mut s.app_language, l, n);
                }
            });
        });
        widgets::setting_row(ui, &t("general.preferredLanguage"), Some(&t("general.preferredLanguageDesc")), |ui| {
            let cur = LANGUAGE_PREFS
                .iter()
                .find(|(c, _)| *c == s.language_preference)
                .map(|(_, n)| n.to_string())
                .unwrap_or_else(|| s.language_preference.clone());
            egui::ComboBox::from_id_salt("language_pref").selected_text(cur).show_ui(ui, |ui| {
                for (c, n) in LANGUAGE_PREFS {
                    ui.selectable_value(&mut s.language_preference, c.to_string(), n);
                }
            });
        });
        if s.stt_engine == SttEngineKind::CloudWhisper {
            widgets::setting_indent(ui, |ui| {
                widgets::setting_toggle(
                    ui,
                    &t("general.autoLanguageDetection"),
                    Some(&t("general.autoLanguageDetectionDesc")),
                    &mut s.auto_language_detection,
                );
            });
        }
        widgets::setting_slider(
            ui,
            &t("general.capsuleSize"),
            &format!("{:.0}%", s.capsule_scale * 100.0),
            &mut s.capsule_scale,
            0.5..=2.0,
            0.1,
            Some(&t("general.capsuleSizeDesc")),
        );
    });
}

// ───────────────────────────── 系統 ─────────────────────────────

fn system_card(ui: &mut Ui, state: &mut AppState) {
    let s = &mut state.settings;
    widgets::card(ui, |ui| {
        widgets::section_header(ui, "⚙", &t("general.sectionSystem"));

        // 實際呼叫 platform::set_launch_at_login 由 A1 在套用設定時處理
        widgets::setting_toggle(ui, &t("general.enableLaunchAtLogin"), Some(&t("general.launchAtLoginDesc")), &mut s.launch_at_login);

        widgets::setting_toggle(
            ui,
            &t("general.enableAutoUpdateCheck"),
            Some(&t("general.autoUpdateCheckDesc")),
            &mut s.enable_auto_update_check,
        );
        if s.enable_auto_update_check && !s.available_update_tag.is_empty() {
            widgets::setting_indent(ui, |ui| {
                ui.horizontal(|ui| {
                    ui.label(tf(
                        "update.newer",
                        &[("latest", &s.available_update_tag), ("current", update_checker::current_version())],
                    ));
                    if !s.available_update_url.is_empty() {
                        widgets::link(ui, &t("update.viewRelease"), &s.available_update_url);
                    }
                });
            });
        }

        widgets::setting_toggle(ui, &t("general.autoCleanup"), Some(&t("general.historyCleanupDesc")), &mut s.enable_history_auto_cleanup);
        if s.enable_history_auto_cleanup {
            widgets::setting_indent(ui, |ui| {
                let mut days = s.history_retention_days as f32;
                let txt = format!("{} {}", s.history_retention_days, t("general.days"));
                if widgets::setting_slider(ui, &t("general.retentionDays"), &txt, &mut days, 7.0..=90.0, 1.0, None) {
                    s.history_retention_days = days.round() as u32;
                }
            });
        }

        widgets::setting_row(ui, &t("general.tutorial"), Some(&t("general.tutorialDesc")), |ui| {
            if ui.button(format!("▶ {}", t("general.replayTutorial"))).clicked() {
                // A1 的引導看到 has_completed_onboarding = false 會重新顯示
                s.has_completed_onboarding = false;
            }
        });
    });
}

// ───────────────────────────── 權限 ─────────────────────────────

fn permissions_card(ui: &mut Ui, state: &mut AppState) {
    let g = &mut state.ui.general;
    let ax = *g.accessibility.get_or_insert_with(platform::accessibility_trusted);
    widgets::card(ui, |ui| {
        ui.horizontal(|ui| {
            widgets::section_header(ui, "🔒", &t("general.permissionStatus"));
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if ui.button(format!("⟳ {}", t("common.recheck"))).clicked() {
                    g.accessibility = None;
                }
            });
        });
        widgets::setting_row(ui, &t("general.accessibility"), Some(&t("general.accessibilityDesc")), |ui| match ax {
            Some(true) => widgets::status_label(ui, true, &t("common.authorized")),
            Some(false) => {
                if ui.button(t("common.openSettings")).clicked() {
                    platform::request_accessibility();
                    platform::open_privacy_settings("accessibility");
                    g.accessibility = None;
                }
                ui.label(RichText::new(t("general.requiredBadge")).small().color(ui.visuals().warn_fg_color));
                widgets::status_label(ui, false, &t("common.notAuthorized"));
            }
            None => {
                ui.label(RichText::new(t("general.notApplicable")).color(ui.visuals().weak_text_color()));
            }
        });
        widgets::setting_row(ui, &t("general.microphone"), Some(&t("general.microphoneDesc")), |ui| {
            if ui.button(t("common.openSettings")).clicked() {
                platform::open_privacy_settings("microphone");
            }
        });
    });
}

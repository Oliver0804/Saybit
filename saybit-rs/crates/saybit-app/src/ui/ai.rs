//! AI 引擎分頁（移植 APISettingsView.swift：服務商、Key、模型列表、進階參數、Prompt 風格、語調）
use super::general::{base_url_hint, new_id, tone_name};
use super::l10n::{t, tf};
use super::widgets::{self, BgTask, SecretField};
use crate::app::AppState;
use egui::{RichText, Ui};
use saybit_core::llm::client::LlmClient;
use saybit_core::llm::{providers, refiner};
use saybit_core::*;

mod keys {
    pub const PROVIDER: &[&str] = &[
        "AI", "API", "provider", "服務商", "服务商", "OpenRouter", "Ollama", "LM Studio", "自訂", "custom", "key", "金鑰", "密钥",
        "連線", "connection", "測試", "本機", "離線", "模型", "model",
    ];
    pub const ADVANCED: &[&str] = &["进阶", "進階", "advanced", "max_tokens", "參數", "temperature", "top p"];
    pub const PROMPT: &[&str] = &["prompt", "風格", "style", "提示詞", "typeless", "wispr"];
    pub const TONE: &[&str] = &["語氣", "tone", "語調", "语调", "正式", "口語"];
    pub const ALL: &[&[&str]] = &[PROVIDER, ADVANCED, PROMPT, TONE];
}

const LM_STUDIO_ID: &str = "lmstudio";
const OLLAMA_ID: &str = "ollama";

pub enum TestMsg {
    Ok(String),
    Err(String),
}

#[derive(Default)]
pub struct AiState {
    key: SecretField,
    test: Option<BgTask<TestMsg>>,
    test_result: Option<Result<String, String>>,
    models_task: Option<BgTask<Result<Vec<String>, String>>>,
    /// (provider id, 結果)
    models: Option<(String, Result<Vec<String>, String>)>,
    models_search: String,
    add_open: bool,
    new_name: String,
    new_url: String,
    last_provider: String,
}

fn is_local(p: &LlmProvider) -> bool {
    p.id == OLLAMA_ID || p.id == LM_STUDIO_ID
}

/// 送出前用的 provider（LM Studio 套用使用者填的位址）
fn effective_provider(s: &Settings, p: &LlmProvider) -> LlmProvider {
    let mut p = p.clone();
    if p.id == LM_STUDIO_ID && !s.lm_studio_base_url.trim().is_empty() {
        p.base_url = providers::normalize_local_base_url(&s.lm_studio_base_url);
    }
    p
}

pub fn show(ui: &mut Ui, state: &mut AppState) {
    poll(state);
    let all = providers::all(&state.settings);
    let current = all
        .iter()
        .find(|p| p.id == state.settings.selected_provider_id)
        .or_else(|| all.first())
        .cloned();

    // 換服務商：清掉上一家的測試結果；本機服務自動偵測一次
    if let Some(p) = &current {
        if state.ui.ai.last_provider != p.id {
            state.ui.ai.last_provider = p.id.clone();
            state.ui.ai.test_result = None;
            state.ui.ai.models_search.clear();
            if state.ui.ai.models.as_ref().is_some_and(|(id, _)| id != &p.id) {
                state.ui.ai.models = None;
            }
            if is_local(p) {
                fetch_models(ui.ctx(), state, p);
            }
        }
    }

    let q = state.ui.search.clone();
    let shows = |k: &[&str]| widgets::matches_search(k, &q);
    let mut secrets_changed = false;
    super::scroll_page(ui, "ai", |ui| {
        if shows(keys::PROVIDER) {
            if let Some(p) = &current {
                secrets_changed = provider_card(ui, state, &all, p);
            }
        }
        if shows(keys::ADVANCED) {
            advanced_card(ui, &mut state.settings);
        }
        if shows(keys::PROMPT) {
            prompt_card(ui, &mut state.settings);
        }
        if shows(keys::TONE) {
            tone_card(ui, &mut state.settings);
        }
        if !q.trim().is_empty() && !keys::ALL.iter().any(|k| shows(k)) {
            widgets::no_results(ui);
        }
    });
    add_custom_dialog(ui.ctx(), state);
    if secrets_changed {
        super::mark_secrets_dirty(state);
    }
}

fn poll(state: &mut AppState) {
    let a = &mut state.ui.ai;
    if let Some(task) = &a.test {
        if let Some(msg) = task.poll().into_iter().next() {
            a.test_result = Some(match msg {
                TestMsg::Ok(s) => Ok(s),
                TestMsg::Err(e) => Err(e),
            });
            a.test = None;
        }
    }
    if let Some(task) = &a.models_task {
        if let Some(r) = task.poll().into_iter().next() {
            let id = state.settings.selected_provider_id.clone();
            a.models = Some((id, r));
            a.models_task = None;
        }
    }
}

fn api_key_for(state: &mut AppState, p: &LlmProvider) -> Option<String> {
    state
        .ui
        .ai
        .key
        .pending_input()
        .or_else(|| secure_store::get(&secure_store::llm_account(&p.id)))
        .filter(|k| !k.is_empty())
}

fn fetch_models(ctx: &egui::Context, state: &mut AppState, p: &LlmProvider) {
    let provider = effective_provider(&state.settings, p);
    let key = api_key_for(state, p);
    state.ui.ai.models = None;
    state.ui.ai.models_task = Some(BgTask::spawn(ctx, move |tx, _| {
        let r = LlmClient::new().list_models(&provider, key.as_deref()).map_err(|e| refiner::friendly_error(&e));
        tx.send(r);
    }));
}

fn start_test(ctx: &egui::Context, state: &mut AppState, p: &LlmProvider) {
    let provider = effective_provider(&state.settings, p);
    let key = api_key_for(state, p);
    let model = state.settings.selected_model.clone();
    state.ui.ai.test_result = None;
    state.ui.ai.test = Some(BgTask::spawn(ctx, move |tx, _| {
        match LlmClient::new().test_connection(&provider, key.as_deref(), &model) {
            Ok(()) => tx.send(TestMsg::Ok(model)),
            Err(e) => tx.send(TestMsg::Err(refiner::friendly_error(&e))),
        }
    }));
}

fn provider_card(ui: &mut Ui, state: &mut AppState, all: &[LlmProvider], current: &LlmProvider) -> bool {
    let mut secrets_changed = false;
    let mut remove: Option<String> = None;
    widgets::card(ui, |ui| {
        widgets::section_header(ui, "🖧", &t("api.provider"));
        let s = &mut state.settings;
        widgets::setting_row(ui, &t("api.providerPicker"), None, |ui| {
            if ui.button(format!("＋ {}", t("api.addCustomEndpoint"))).clicked() {
                state.ui.ai.add_open = true;
                state.ui.ai.new_name.clear();
                state.ui.ai.new_url.clear();
            }
            if !current.is_built_in
                && ui.small_button("🗑").on_hover_text(tf("api.removeProvider", &[("name", &current.name)])).clicked()
            {
                remove = Some(current.id.clone());
            }
            let before = s.selected_provider_id.clone();
            egui::ComboBox::from_id_salt("llm_provider").selected_text(&current.name).width(220.0).show_ui(ui, |ui| {
                for p in all {
                    ui.selectable_value(&mut s.selected_provider_id, p.id.clone(), &p.name);
                }
            });
            if before != s.selected_provider_id {
                if let Some(m) = providers::default_model(&s.selected_provider_id) {
                    s.selected_model = m.to_string();
                }
            }
        });

        // Key 欄位上方：申請連結與儲值提醒
        if current.requires_api_key {
            if let Some(url) = providers::key_portal_url(&current.id) {
                ui.horizontal(|ui| {
                    ui.label("🔑");
                    widgets::link(ui, &tf("api.getProviderKey", &[("name", &current.name)]), url);
                });
            }
            if providers::needs_prepaid_credit(&current.id) {
                widgets::info_label(ui, &tf("api.keyNeedsCredit", &[("provider", &current.name)]));
            }
            ui.label("API Key");
            let account = secure_store::llm_account(&current.id);
            secrets_changed |= state.ui.ai.key.ui(ui, &account, &current.key_placeholder);
        } else {
            // 本機 / 自訂端點：伺服器位址＋選填 key
            ui.label(t("api.serverAddress"));
            if current.id == LM_STUDIO_ID {
                let r = ui.add(egui::TextEdit::singleline(&mut s.lm_studio_base_url).desired_width(f32::INFINITY));
                if r.lost_focus() {
                    s.lm_studio_base_url = providers::normalize_local_base_url(&s.lm_studio_base_url);
                }
                base_url_hint(ui, &providers::normalize_local_base_url(&s.lm_studio_base_url));
                widgets::description(ui, &t("api.lmStudioHint"));
            } else if let Some(cp) = s.custom_providers.iter_mut().find(|p| p.id == current.id) {
                ui.add(egui::TextEdit::singleline(&mut cp.base_url).desired_width(f32::INFINITY));
                base_url_hint(ui, &cp.base_url);
            } else {
                ui.label(RichText::new(&current.base_url).monospace().color(ui.visuals().weak_text_color()));
                if current.id == OLLAMA_ID {
                    widgets::description(ui, &t("api.ollamaHint"));
                }
            }
            ui.label(t("api.apiKeyOptional"));
            let account = secure_store::llm_account(&current.id);
            secrets_changed |= state.ui.ai.key.ui(ui, &account, &current.key_placeholder);

            if is_local(current) {
                ui.horizontal(|ui| {
                    match (&state.ui.ai.models_task, &state.ui.ai.models) {
                        (Some(_), _) => {
                            ui.spinner();
                            ui.label(t("api.checking"));
                        }
                        (None, Some((_, Ok(list)))) => {
                            widgets::status_label(ui, true, &tf("api.connectedModels", &[("count", &list.len().to_string())]))
                        }
                        (None, Some((_, Err(_)))) => {
                            widgets::status_label(ui, false, &tf("api.notDetectedServer", &[("name", &current.name)]))
                        }
                        (None, None) => {}
                    }
                    if ui.button(format!("⟳ {}", t("common.recheck"))).clicked() {
                        fetch_models(ui.ctx(), state, current);
                    }
                });
            }
        }

        ui.separator();
        model_section(ui, state, current);

        ui.horizontal(|ui| {
            let busy = state.ui.ai.test.is_some();
            if ui.add_enabled(!busy, egui::Button::new(format!("⚡ {}", t("common.testConnection")))).clicked() {
                start_test(ui.ctx(), state, current);
            }
            if busy {
                ui.spinner();
            }
            match &state.ui.ai.test_result {
                Some(Ok(model)) => widgets::status_label(ui, true, &format!("{} ({model})", t("common.connectionSuccess"))),
                Some(Err(e)) => {
                    ui.add(egui::Label::new(RichText::new(format!("✖ {e}")).color(ui.visuals().error_fg_color)).wrap());
                }
                None => {}
            }
        });
    });
    if let Some(id) = remove {
        state.settings.custom_providers.retain(|p| p.id != id);
        if state.settings.selected_provider_id == id {
            state.settings.selected_provider_id = "openrouter".into();
        }
    }
    secrets_changed
}

fn model_section(ui: &mut Ui, state: &mut AppState, current: &LlmProvider) {
    ui.horizontal(|ui| {
        ui.label(t("api.model"));
        let w = (ui.available_width() - 120.0).max(160.0);
        ui.add(
            egui::TextEdit::singleline(&mut state.settings.selected_model)
                .hint_text(current.model_hint.clone())
                .desired_width(w),
        );
        let busy = state.ui.ai.models_task.is_some();
        if ui.add_enabled(!busy, egui::Button::new(format!("⟳ {}", t("apimodels.listButton")))).clicked() {
            fetch_models(ui.ctx(), state, current);
        }
    });
    if !current.model_hint.is_empty() {
        widgets::description(ui, &tf("api.commonModels", &[("hint", &current.model_hint)]));
    }
    let a = &mut state.ui.ai;
    match &a.models {
        Some((_, Err(e))) => widgets::warn_label(ui, &tf("apimodels.fetchFailed", &[("msg", e)])),
        Some((_, Ok(list))) if list.is_empty() => widgets::warn_label(ui, &t("apimodels.emptyResponse")),
        Some((_, Ok(list))) => {
            ui.add(egui::TextEdit::singleline(&mut a.models_search).hint_text(t("apimodels.searchPlaceholder")));
            let q = a.models_search.trim().to_lowercase();
            let filtered: Vec<&String> = list.iter().filter(|m| q.is_empty() || m.to_lowercase().contains(&q)).collect();
            let summary = if q.is_empty() {
                tf("apimodels.count", &[("n", &list.len().to_string())])
            } else {
                tf(
                    "apimodels.filteredCount",
                    &[("query", &a.models_search), ("total", &list.len().to_string()), ("matched", &filtered.len().to_string())],
                )
            };
            widgets::description(ui, &summary);
            egui::ScrollArea::vertical().id_salt("model_chips").max_height(160.0).show(ui, |ui| {
                ui.horizontal_wrapped(|ui| {
                    for m in filtered {
                        let sel = &state.settings.selected_model == m;
                        if ui.selectable_label(sel, m).clicked() {
                            state.settings.selected_model = m.clone();
                        }
                    }
                });
            });
        }
        None => {}
    }
}

fn add_custom_dialog(ctx: &egui::Context, state: &mut AppState) {
    if !state.ui.ai.add_open {
        return;
    }
    let mut close = false;
    let mut add = false;
    egui::Modal::new(egui::Id::unique("add_custom_endpoint")).show(ctx, |ui| {
        let a = &mut state.ui.ai;
        ui.set_width(460.0);
        ui.heading(t("api.addCustomTitle"));
        ui.add(egui::TextEdit::singleline(&mut a.new_name).hint_text(t("api.nameHint")).desired_width(f32::INFINITY));
        ui.add(egui::TextEdit::singleline(&mut a.new_url).hint_text(t("api.baseURLHint")).desired_width(f32::INFINITY));
        let v = if a.new_url.trim().is_empty() { None } else { Some(base_url_hint(ui, a.new_url.trim())) };
        let ok = !a.new_name.trim().is_empty() && v == Some(settings::BaseUrlValidation::Ok);
        ui.horizontal(|ui| {
            if ui.button(t("common.cancel")).clicked() {
                close = true;
            }
            if ui.add_enabled(ok, egui::Button::new(t("common.add"))).clicked() {
                add = true;
            }
        });
    });
    if add {
        let a = &mut state.ui.ai;
        let id = format!("custom-{}", new_id());
        state.settings.custom_providers.push(LlmProvider {
            id: id.clone(),
            name: a.new_name.trim().to_string(),
            base_url: a.new_url.trim().to_string(),
            extra_headers: Vec::new(),
            key_placeholder: String::new(),
            model_hint: String::new(),
            is_built_in: false,
            requires_api_key: false,
        });
        state.settings.selected_provider_id = id;
        close = true;
    }
    if close {
        state.ui.ai.add_open = false;
    }
}

fn advanced_card(ui: &mut Ui, s: &mut Settings) {
    widgets::card(ui, |ui| {
        widgets::section_header(ui, "🎚", &t("api.advancedParams"));
        widgets::setting_toggle(ui, &t("api.useCustomParams"), Some(&t("api.advancedParamsDesc")), &mut s.use_custom_llm_params);
        if s.use_custom_llm_params {
            widgets::setting_indent(ui, |ui| {
                widgets::setting_row(ui, &t("api.maxTokens"), None, |ui| {
                    ui.add(egui::DragValue::new(&mut s.llm_max_tokens).range(256..=16384).speed(256.0));
                });
                let txt = format!("{:.2}", s.llm_temperature);
                widgets::setting_slider(ui, &t("api.temperature"), &txt, &mut s.llm_temperature, 0.0..=2.0, 0.05, None);
                let txt = format!("{:.2}", s.llm_top_p);
                widgets::setting_slider(ui, &t("api.topP"), &txt, &mut s.llm_top_p, 0.0..=1.0, 0.05, None);
            });
        }
    });
}

fn prompt_card(ui: &mut Ui, s: &mut Settings) {
    widgets::card(ui, |ui| {
        widgets::section_header(ui, "💬", &t("prompt.promptStyle"));
        for (style, name, desc) in [
            (PromptStyle::Typeless, "Typeless", "prompt.typelessDesc"),
            (PromptStyle::WisprFlow, "Wispr Flow", "prompt.wisprFlowDesc"),
        ] {
            ui.radio_value(&mut s.prompt_style, style, name);
            widgets::setting_indent(ui, |ui| widgets::description(ui, &t(desc)));
        }
    });
}

fn tone_card(ui: &mut Ui, s: &mut Settings) {
    widgets::card(ui, |ui| {
        widgets::section_header(ui, "🎭", &t("prompt.tone"));
        ui.horizontal(|ui| {
            for tone in [ToneStyle::Auto, ToneStyle::Formal, ToneStyle::Casual, ToneStyle::VeryCasual] {
                ui.selectable_value(&mut s.tone_style, tone, tone_name(tone));
            }
        });
        widgets::description(ui, &t("prompt.toneAutoDesc"));
    });
}

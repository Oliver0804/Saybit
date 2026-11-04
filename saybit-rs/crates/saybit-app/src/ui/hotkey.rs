//! 快捷鍵分頁（移植 HotKeySettingsView.swift + VoiceModesSection.swift）
use super::l10n::{t, tf};
use super::widgets::{self, hotkey_eq};
use crate::hotkeys::{display_label as hotkey_display, HotkeyRecorder, RecorderEvent, RECORDER_TIMEOUT};
use crate::app::AppState;
use egui::{RichText, Ui};
use saybit_core::*;
use std::collections::HashSet;
use std::time::Instant;

mod keys {
    pub const HOTKEY: &[&str] = &["快捷鍵", "hotkey", "shortcut", "快捷键", "鍵盤", "keyboard", "錄製", "record"];
    pub const TRIGGER: &[&str] = &["觸發", "trigger", "toggle", "hold", "按住", "雙擊", "double tap", "說明", "使用方式", "usage"];
    pub const MODES: &[&str] = &["語音模式", "模式", "mode", "email", "翻譯", "條列", "指令", "instructions"];
    pub const URL: &[&str] = &["url", "raycast", "捷徑", "shortcuts", "stream deck", "saybit://", "其他 App", "other apps"];
    pub const ALL: &[&[&str]] = &[HOTKEY, TRIGGER, MODES, URL];
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum RecordTarget {
    Main,
    Mode(String),
}

#[derive(Default)]
pub struct HotkeyState {
    recorder: HotkeyRecorder,
    target: Option<RecordTarget>,
    /// 倒數顯示用（A1 的錄製器不對外提供剩餘秒數）
    started_at: Option<Instant>,
    expanded: HashSet<String>,
    pending_delete: Option<String>,
}

/// 離開快捷鍵分頁／關窗：取消錄製（A1 錄製期間會暫停全域快捷鍵，不能留著）
pub fn on_leave(h: &mut HotkeyState) {
    if h.target.is_some() || h.recorder.is_active() {
        h.recorder.cancel();
        h.target = None;
        h.started_at = None;
    }
}

impl HotkeyState {
    fn remaining_secs(&self) -> u64 {
        self.started_at.map(|s| RECORDER_TIMEOUT.as_secs().saturating_sub(s.elapsed().as_secs())).unwrap_or(0)
    }
}

pub fn trigger_mode_name(m: HotkeyTriggerMode) -> String {
    t(match m {
        HotkeyTriggerMode::Toggle => "enum.trigger.toggle",
        HotkeyTriggerMode::Hold => "enum.trigger.hold",
        HotkeyTriggerMode::DoubleTap => "enum.trigger.doubleTap",
    })
}

fn trigger_mode_desc(m: HotkeyTriggerMode) -> String {
    t(match m {
        HotkeyTriggerMode::Toggle => "enum.triggerDesc.toggle",
        HotkeyTriggerMode::Hold => "enum.triggerDesc.hold",
        HotkeyTriggerMode::DoubleTap => "enum.triggerDesc.doubleTap",
    })
}

pub fn show(ui: &mut Ui, state: &mut AppState) {
    // 錄製中：每幀讀按鍵
    if state.ui.hotkey.target.is_some() {
        if let Some(ev) = state.ui.hotkey.recorder.poll(ui.ctx()) {
            let target = state.ui.hotkey.target.take();
            state.ui.hotkey.started_at = None;
            if let (RecorderEvent::Captured(combo), Some(target)) = (ev, target) {
                match target {
                    RecordTarget::Main => state.settings.hotkey = combo,
                    RecordTarget::Mode(id) => {
                        if let Some(m) = state.settings.voice_modes.iter_mut().find(|m| m.id == id) {
                            m.hotkey = Some(combo);
                        }
                    }
                }
            }
        }
    }

    let q = state.ui.search.clone();
    let shows = |k: &[&str]| widgets::matches_search(k, &q);
    super::scroll_page(ui, "hotkey", |ui| {
        if shows(keys::HOTKEY) {
            hotkey_card(ui, state);
        }
        if shows(keys::TRIGGER) {
            trigger_card(ui, &mut state.settings);
            usage_card(ui, state.settings.hotkey_trigger_mode);
        }
        if shows(keys::MODES) {
            modes_card(ui, state);
        }
        if shows(keys::URL) {
            url_card(ui, &mut state.settings);
        }
        if !q.trim().is_empty() && !keys::ALL.iter().any(|k| shows(k)) {
            widgets::no_results(ui);
        }
    });
    delete_mode_dialog(ui.ctx(), state);
}

fn hotkey_card(ui: &mut Ui, state: &mut AppState) {
    let h = &mut state.ui.hotkey;
    let recording_main = h.target == Some(RecordTarget::Main);
    widgets::card(ui, |ui| {
        widgets::section_header(ui, "⌘", &t("hotkey.hotkey"));
        widgets::setting_row(ui, &t("hotkey.currentHotkey"), None, |ui| {
            if recording_main {
                if ui.button(t("common.cancel")).clicked() {
                    h.recorder.cancel();
                    h.target = None;
                    h.started_at = None;
                }
            } else if ui.button(t("hotkey.recordNew")).clicked() {
                h.recorder.start();
                h.target = Some(RecordTarget::Main);
                h.started_at = Some(Instant::now());
            }
            let text = if recording_main {
                tf("voicemodes.pressHotkey", &[("remaining", &h.remaining_secs().to_string())])
            } else {
                hotkey_display(&state.settings.hotkey)
            };
            egui::Frame::group(ui.style()).show(ui, |ui| {
                ui.label(RichText::new(text).monospace().size(15.0));
            });
        });
        if recording_main {
            widgets::description(ui, &h.recorder.prompt());
        }
        widgets::description(ui, &t(if recording_main { "hotkey.recordingHint" } else { "hotkey.requirement" }));
        if let Some(m) = state.settings.voice_modes.iter().find(|m| m.hotkey.as_deref().is_some_and(|k| hotkey_eq(k, &state.settings.hotkey))) {
            widgets::warn_label(ui, &tf("hotkey.conflictsWithMode", &[("name", &m.name)]));
        }
    });
}

fn trigger_card(ui: &mut Ui, s: &mut Settings) {
    widgets::card(ui, |ui| {
        widgets::section_header(ui, "☝", &t("hotkey.triggerMode"));
        for m in [HotkeyTriggerMode::Toggle, HotkeyTriggerMode::Hold, HotkeyTriggerMode::DoubleTap] {
            ui.radio_value(&mut s.hotkey_trigger_mode, m, trigger_mode_name(m));
            widgets::setting_indent(ui, |ui| widgets::description(ui, &trigger_mode_desc(m)));
        }
    });
}

fn usage_card(ui: &mut Ui, mode: HotkeyTriggerMode) {
    let steps: &[&str] = match mode {
        HotkeyTriggerMode::Toggle => &["hotkey.toggleStep1", "hotkey.toggleStep2", "hotkey.toggleStep3", "hotkey.toggleStep4"],
        HotkeyTriggerMode::Hold => &["hotkey.holdStep1", "hotkey.holdStep2", "hotkey.holdStep3"],
        HotkeyTriggerMode::DoubleTap => {
            &["hotkey.doubleTapStep1", "hotkey.doubleTapStep2", "hotkey.doubleTapStep3", "hotkey.doubleTapStep4"]
        }
    };
    widgets::card(ui, |ui| {
        widgets::section_header(ui, "❓", &t("hotkey.usageGuide"));
        for (i, k) in steps.iter().enumerate() {
            ui.horizontal(|ui| {
                ui.label(RichText::new(format!("{}", i + 1)).strong().color(ui.visuals().selection.bg_fill));
                ui.label(t(k));
            });
        }
    });
}

fn modes_card(ui: &mut Ui, state: &mut AppState) {
    let main_hotkey = state.settings.hotkey.clone();
    let h = &mut state.ui.hotkey;
    let modes = &mut state.settings.voice_modes;
    widgets::card(ui, |ui| {
        ui.horizontal(|ui| {
            widgets::section_header(ui, "🗂", &t("voicemodes.title"));
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if ui.button(format!("＋ {}", t("voicemodes.addMode"))).clicked() {
                    let id = super::general::new_id();
                    modes.push(VoiceMode { id: id.clone(), name: t("voicemodes.newModeName"), instructions: String::new(), hotkey: None });
                    h.expanded.insert(id);
                }
            });
        });
        widgets::description(ui, &t("voicemodes.desc"));

        for m in modes.iter_mut() {
            let expanded = h.expanded.contains(&m.id);
            let recording = h.target.as_ref() == Some(&RecordTarget::Mode(m.id.clone()));
            egui::Frame::group(ui.style()).show(ui, |ui| {
                ui.set_width(ui.available_width());
                ui.horizontal(|ui| {
                    let arrow = if expanded { "⏷" } else { "⏵" };
                    if ui.small_button(arrow).on_hover_text(t("general.expand")).clicked() {
                        if expanded {
                            h.expanded.remove(&m.id);
                        } else {
                            h.expanded.insert(m.id.clone());
                        }
                    }
                    ui.add(egui::TextEdit::singleline(&mut m.name).hint_text(t("voicemodes.namePlaceholder")).desired_width(180.0));
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if ui.small_button("🗑").on_hover_text(t("voicemodes.deleteMode")).clicked() {
                            h.pending_delete = Some(m.id.clone());
                        }
                        if m.hotkey.is_some()
                            && !recording
                            && ui.small_button("✖").on_hover_text(t("voicemodes.clearHotkey")).clicked()
                        {
                            m.hotkey = None;
                        }
                        let label = if recording {
                            tf("voicemodes.pressHotkey", &[("remaining", &h.remaining_secs().to_string())])
                        } else {
                            m.hotkey.as_deref().map(hotkey_display).unwrap_or_else(|| t("voicemodes.setHotkey"))
                        };
                        let help = if recording { t("voicemodes.cancelRecordingHelp") } else { t("voicemodes.setHotkey") };
                        if ui.button(label).on_hover_text(help).clicked() {
                            if recording {
                                h.recorder.cancel();
                                h.target = None;
                                h.started_at = None;
                            } else {
                                h.recorder.start();
                                h.target = Some(RecordTarget::Mode(m.id.clone()));
                                h.started_at = Some(Instant::now());
                            }
                        }
                    });
                });
                if m.hotkey.as_deref().is_some_and(|k| hotkey_eq(k, &main_hotkey)) {
                    widgets::warn_label(ui, &t("voicemodes.conflictsWithMain"));
                }
                if expanded {
                    ui.label(RichText::new(t("voicemodes.instructions")).strong());
                    ui.add(egui::TextEdit::multiline(&mut m.instructions).desired_rows(3).desired_width(f32::INFINITY));
                    widgets::description(ui, &t("voicemodes.instructionsExample"));
                }
            });
        }
    });
}

fn delete_mode_dialog(ctx: &egui::Context, state: &mut AppState) {
    let Some(id) = state.ui.hotkey.pending_delete.clone() else { return };
    let name = state.settings.voice_modes.iter().find(|m| m.id == id).map(|m| m.name.clone()).unwrap_or_default();
    let mut close = false;
    egui::Modal::new(egui::Id::unique("delete_voice_mode")).show(ctx, |ui| {
        ui.set_max_width(360.0);
        ui.heading(tf("voicemodes.deleteConfirm", &[("name", &name)]));
        ui.label(t("voicemodes.deleteMessage"));
        ui.horizontal(|ui| {
            if ui.button(RichText::new(t("common.delete")).color(ui.visuals().error_fg_color)).clicked() {
                state.settings.voice_modes.retain(|m| m.id != id);
                close = true;
            }
            if ui.button(t("common.cancel")).clicked() {
                close = true;
            }
        });
    });
    if close {
        state.ui.hotkey.pending_delete = None;
    }
}

fn url_card(ui: &mut Ui, s: &mut Settings) {
    widgets::card(ui, |ui| {
        widgets::section_header(ui, "🔗", &t("voicemodes.externalTrigger"));
        egui::Frame::group(ui.style()).show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.label(RichText::new(t("voicemodes.urlHelp")).monospace());
        });
        let mut allowed = s.url_scheme_decision != UrlSchemeDecision::Deny;
        if widgets::setting_toggle(ui, &t("voicemodes.urlControlToggle"), Some(&t("voicemodes.urlControlDesc")), &mut allowed) {
            s.url_scheme_decision = if allowed { UrlSchemeDecision::Ask } else { UrlSchemeDecision::Deny };
        }
        if allowed {
            widgets::setting_indent(ui, |ui| {
                widgets::setting_row(ui, &t("voicemodes.urlDecision"), None, |ui| {
                    ui.selectable_value(&mut s.url_scheme_decision, UrlSchemeDecision::Allow, t("enum.urlDecision.allow"));
                    ui.selectable_value(&mut s.url_scheme_decision, UrlSchemeDecision::Ask, t("enum.urlDecision.ask"));
                });
            });
        }
    });
}

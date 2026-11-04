//! 字典／技能分頁（移植 DictionarySettingsView.swift）
use super::l10n::{t, tf};
use super::widgets;
use crate::app::AppState;
use egui::{RichText, Ui};
use saybit_core::{DictionaryEntry, Skill};

mod keys {
    pub const DICT: &[&str] = &["字典", "dictionary", "詞彙", "词汇", "辞書", "詞條", "更正", "偏好", "preferred"];
    pub const SKILLS: &[&str] = &["技能", "skill", "snippet", "觸發詞", "trigger", "prompt"];
    pub const ALL: &[&[&str]] = &[DICT, SKILLS];
}

#[derive(Default)]
pub struct DictionaryState {
    entries: Option<Vec<DictionaryEntry>>,
    skills: Option<Vec<Skill>>,
    error: Option<String>,
    new_term: String,
    new_preferred: String,
    filter: String,
    new_trigger: String,
    new_content: String,
}

/// 新詞是否已存在（不分大小寫、去頭尾空白）
pub fn is_duplicate_term(entries: &[DictionaryEntry], term: &str) -> bool {
    let t = term.trim().to_lowercase();
    !t.is_empty() && entries.iter().any(|e| e.term.trim().to_lowercase() == t)
}

/// 篩選：原始詞或偏好寫法包含 query（不分大小寫）
pub fn filter_entries<'a>(entries: &'a [DictionaryEntry], query: &str) -> Vec<&'a DictionaryEntry> {
    let q = query.trim().to_lowercase();
    entries
        .iter()
        .filter(|e| q.is_empty() || e.term.to_lowercase().contains(&q) || e.preferred.to_lowercase().contains(&q))
        .collect()
}

fn reload(state: &mut AppState) {
    let storage = match state.ui.storage() {
        Ok(s) => s,
        Err(e) => {
            state.ui.dictionary.error = Some(e);
            return;
        }
    };
    let d = &mut state.ui.dictionary;
    match (storage.dictionary(), storage.skills()) {
        (Ok(e), Ok(s)) => {
            d.entries = Some(e);
            d.skills = Some(s);
            d.error = None;
        }
        (Err(e), _) | (_, Err(e)) => {
            d.entries = Some(Vec::new());
            d.skills = Some(Vec::new());
            d.error = Some(e.to_string());
        }
    }
}

enum Action {
    AddEntry,
    DeleteEntry(i64),
    AddSkill,
    DeleteSkill(i64),
}

pub fn show(ui: &mut Ui, state: &mut AppState) {
    if state.ui.dictionary.entries.is_none() {
        reload(state);
    }
    let q = state.ui.search.clone();
    let shows = |k: &[&str]| widgets::matches_search(k, &q);
    let mut action = None;
    super::scroll_page(ui, "dictionary", |ui| {
        let d = &mut state.ui.dictionary;
        if let Some(e) = &d.error {
            widgets::warn_label(ui, e);
        }
        if shows(keys::DICT) {
            dictionary_card(ui, d, &mut action);
        }
        if shows(keys::SKILLS) {
            add_skill_card(ui, d, &mut action);
            skill_list_card(ui, d, &mut action);
        }
        if !q.trim().is_empty() && !keys::ALL.iter().any(|k| shows(k)) {
            widgets::no_results(ui);
        }
    });
    if let Some(a) = action {
        apply(state, a);
    }
}

fn apply(state: &mut AppState, action: Action) {
    let storage = match state.ui.storage() {
        Ok(s) => s,
        Err(e) => {
            state.ui.dictionary.error = Some(e);
            return;
        }
    };
    let d = &mut state.ui.dictionary;
    let r = match action {
        Action::AddEntry => {
            let (term, pref) = (d.new_term.trim().to_string(), d.new_preferred.trim().to_string());
            if term.is_empty() || pref.is_empty() {
                return;
            }
            let r = storage.upsert_dictionary(&term, &pref);
            if r.is_ok() {
                d.new_term.clear();
                d.new_preferred.clear();
            }
            r
        }
        Action::DeleteEntry(id) => storage.delete_dictionary(id),
        Action::AddSkill => {
            let (trigger, content) = (d.new_trigger.trim().to_string(), d.new_content.trim().to_string());
            if trigger.is_empty() || content.is_empty() {
                return;
            }
            let r = storage.add_skill(&trigger, &content);
            if r.is_ok() {
                d.new_trigger.clear();
                d.new_content.clear();
            }
            r
        }
        Action::DeleteSkill(id) => storage.delete_skill(id),
    };
    if let Err(e) = r {
        d.error = Some(e.to_string());
    } else {
        reload(state);
    }
}

fn dictionary_card(ui: &mut Ui, d: &mut DictionaryState, action: &mut Option<Action>) {
    let entries = d.entries.clone().unwrap_or_default();
    widgets::card(ui, |ui| {
        widgets::section_header(ui, "📖", &t("dict.dictList"));
        ui.horizontal(|ui| {
            let w = ((ui.available_width() - 80.0) / 2.0).max(100.0);
            let r1 = ui.add(egui::TextEdit::singleline(&mut d.new_term).hint_text(t("dict.originalTerm")).desired_width(w));
            ui.label("→");
            let r2 = ui.add(egui::TextEdit::singleline(&mut d.new_preferred).hint_text(t("dict.preferredForm")).desired_width(w));
            let enter = (r1.lost_focus() || r2.lost_focus()) && ui.input(|i| i.key_pressed(egui::Key::Enter));
            let valid = !d.new_term.trim().is_empty() && !d.new_preferred.trim().is_empty();
            if (ui.add_enabled(valid, egui::Button::new(t("common.add"))).clicked() || enter) && valid {
                *action = Some(Action::AddEntry);
            }
        });
        if is_duplicate_term(&entries, &d.new_term) {
            widgets::info_label(ui, &tf("dict.duplicateTerm", &[("term", d.new_term.trim())]));
        }
        widgets::description(ui, &t("dict.dictDesc"));
        ui.separator();

        if entries.is_empty() {
            ui.label(RichText::new(t("dict.emptyDict")).color(ui.visuals().weak_text_color()));
            return;
        }
        ui.horizontal(|ui| {
            ui.label("🔍");
            ui.add(egui::TextEdit::singleline(&mut d.filter).hint_text(t("dict.filterPlaceholder")).desired_width(220.0));
            if !d.filter.is_empty() && ui.small_button("✖").on_hover_text(t("common.clearSearch")).clicked() {
                d.filter.clear();
            }
            ui.label(RichText::new(format!("{}", entries.len())).color(ui.visuals().weak_text_color()));
        });
        let shown = filter_entries(&entries, &d.filter);
        if shown.is_empty() {
            widgets::description(ui, &tf("dict.noFilterMatch", &[("q", d.filter.trim())]));
        }
        for e in shown {
            // hover 才顯示刪除鈕
            ui.horizontal(|ui| {
                let hovered = ui.rect_contains_pointer(ui.max_rect());
                ui.label(RichText::new(&e.term).monospace());
                ui.label(RichText::new("→").color(ui.visuals().weak_text_color()));
                ui.label(RichText::new(&e.preferred).strong());
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    if hovered && ui.small_button("🗑").on_hover_text(t("common.delete")).clicked() {
                        *action = Some(Action::DeleteEntry(e.id));
                    }
                });
            });
        }
    });
}

fn add_skill_card(ui: &mut Ui, d: &mut DictionaryState, action: &mut Option<Action>) {
    widgets::card(ui, |ui| {
        widgets::section_header(ui, "✨", &t("dict.addSkill"));
        ui.horizontal(|ui| {
            ui.add(egui::TextEdit::singleline(&mut d.new_trigger).hint_text(t("dict.triggerWord")).desired_width(240.0));
            let valid = !d.new_trigger.trim().is_empty() && !d.new_content.trim().is_empty();
            if ui.add_enabled(valid, egui::Button::new(t("common.add"))).clicked() {
                *action = Some(Action::AddSkill);
            }
        });
        ui.label(t("dict.promptInstruction"));
        ui.add(egui::TextEdit::multiline(&mut d.new_content).desired_rows(3).desired_width(f32::INFINITY));
        widgets::description(ui, &t("dict.skillDesc"));
        ui.label(RichText::new(t("dict.example")).small().strong());
        widgets::description(ui, &format!("• {}", t("dict.exampleWrite")));
        widgets::description(ui, &format!("• {}", t("dict.exampleSummary")));
    });
}

fn skill_list_card(ui: &mut Ui, d: &mut DictionaryState, action: &mut Option<Action>) {
    let skills = d.skills.clone().unwrap_or_default();
    widgets::card(ui, |ui| {
        widgets::section_header(ui, "★", &t("dict.skillList"));
        if skills.is_empty() {
            ui.label(RichText::new(t("dict.emptySkills")).color(ui.visuals().weak_text_color()));
        }
        for s in &skills {
            egui::Frame::group(ui.style()).show(ui, |ui| {
                ui.set_width(ui.available_width());
                ui.horizontal(|ui| {
                    ui.label(RichText::new(&s.trigger).strong());
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if ui.small_button("🗑").on_hover_text(t("dict.deleteSkill")).clicked() {
                            *action = Some(Action::DeleteSkill(s.id));
                        }
                    });
                });
                widgets::description(ui, &s.content);
            });
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn e(term: &str, preferred: &str) -> DictionaryEntry {
        DictionaryEntry { id: 0, term: term.into(), preferred: preferred.into() }
    }

    #[test]
    fn duplicate_is_case_insensitive() {
        let list = vec![e("Saybit", "Saybit"), e("鄭", "John")];
        assert!(is_duplicate_term(&list, " saybit "));
        assert!(is_duplicate_term(&list, "鄭"));
        assert!(!is_duplicate_term(&list, "say"));
        assert!(!is_duplicate_term(&list, "  "));
    }

    #[test]
    fn filter_matches_both_columns() {
        let list = vec![e("jon", "John"), e("gpt", "GPT")];
        assert_eq!(filter_entries(&list, "JOHN").len(), 1);
        assert_eq!(filter_entries(&list, "").len(), 2);
        assert_eq!(filter_entries(&list, "x").len(), 0);
    }
}

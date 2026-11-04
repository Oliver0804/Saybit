//! 日誌分頁（移植 LogsView.swift：等級／分類篩選、搜尋、自動捲動、匯出遮罩版、清除）
use super::l10n::t;
use super::widgets;
use crate::app::AppState;
use chrono::Local;
use egui::{Color32, RichText, Ui};
use saybit_core::{logging, LogEntry, LogLevel};
use std::time::{Duration, Instant};

const MAX_ENTRIES: usize = 2000;

pub struct LogsState {
    entries: Vec<LogEntry>,
    fetched_at: Option<Instant>,
    level: Option<LogLevel>,
    category: Option<String>,
    search: String,
    auto_scroll: bool,
    status: Option<String>,
}

impl Default for LogsState {
    fn default() -> Self {
        Self {
            entries: Vec::new(),
            fetched_at: None,
            level: None,
            category: None,
            search: String::new(),
            auto_scroll: true,
            status: None,
        }
    }
}

/// 等級完全相符、分類相符、訊息或分類包含搜尋字（不分大小寫）
pub fn filter_logs<'a>(entries: &'a [LogEntry], level: Option<LogLevel>, category: Option<&str>, search: &str) -> Vec<&'a LogEntry> {
    let q = search.trim().to_lowercase();
    entries
        .iter()
        .filter(|e| level.is_none_or(|l| e.level == l))
        .filter(|e| category.is_none_or(|c| e.category == c))
        .filter(|e| q.is_empty() || e.message.to_lowercase().contains(&q) || e.category.to_lowercase().contains(&q))
        .collect()
}

pub fn categories(entries: &[LogEntry]) -> Vec<String> {
    let mut v: Vec<String> = entries.iter().map(|e| e.category.clone()).collect();
    v.sort();
    v.dedup();
    v
}

fn level_name(l: LogLevel) -> &'static str {
    match l {
        LogLevel::Debug => "DEBUG",
        LogLevel::Info => "INFO",
        LogLevel::Warn => "WARN",
        LogLevel::Error => "ERROR",
    }
}

fn level_color(ui: &Ui, l: Option<LogLevel>) -> Color32 {
    match l {
        Some(LogLevel::Debug) => Color32::GRAY,
        Some(LogLevel::Info) => Color32::from_rgb(0, 122, 255),
        Some(LogLevel::Warn) => Color32::from_rgb(255, 149, 0),
        Some(LogLevel::Error) => Color32::from_rgb(255, 59, 48),
        None => ui.visuals().text_color(),
    }
}

pub fn show(ui: &mut Ui, state: &mut AppState) {
    let s = &mut state.ui.logs;
    if s.fetched_at.is_none_or(|t| t.elapsed() > Duration::from_secs(1)) {
        s.entries = logging::recent(MAX_ENTRIES);
        s.fetched_at = Some(Instant::now());
    }
    ui.ctx().request_repaint_after(Duration::from_secs(1));

    egui::Frame::new().inner_margin(egui::Margin::same(16)).show(ui, |ui| {
        widgets::section_header(ui, "📄", &t("logs.logs"));
        ui.horizontal_wrapped(|ui| {
            ui.label(t("logs.logLevel"));
            for l in [None, Some(LogLevel::Debug), Some(LogLevel::Info), Some(LogLevel::Warn), Some(LogLevel::Error)] {
                let label = l.map(level_name).map(str::to_string).unwrap_or_else(|| t("common.all"));
                let color = level_color(ui, l);
                let text = RichText::new(label).monospace().small().color(if s.level == l { color } else { ui.visuals().weak_text_color() });
                if ui.selectable_label(s.level == l, text).clicked() {
                    s.level = l;
                }
            }
            ui.separator();
            ui.label(t("logs.logCategory"));
            let cats = categories(&s.entries);
            egui::ComboBox::from_id_salt("log_category")
                .selected_text(s.category.clone().unwrap_or_else(|| t("common.all")))
                .show_ui(ui, |ui| {
                    ui.selectable_value(&mut s.category, None, t("common.all"));
                    for c in cats {
                        ui.selectable_value(&mut s.category, Some(c.clone()), c);
                    }
                });
            ui.separator();
            ui.checkbox(&mut s.auto_scroll, t("logs.logAutoScroll"));
        });
        ui.horizontal(|ui| {
            ui.label("🔍");
            ui.add(egui::TextEdit::singleline(&mut s.search).hint_text(t("logs.logSearch")).desired_width(240.0));
            if !s.search.is_empty() && ui.small_button("✖").on_hover_text(t("common.clearSearch")).clicked() {
                s.search.clear();
            }
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if ui.button(format!("🗑 {}", t("logs.logClear"))).clicked() {
                    logging::clear();
                    s.entries.clear();
                    s.fetched_at = None;
                }
                if ui.button(format!("⬆ {}", t("logs.logExport"))).clicked() {
                    let name = format!("saybit-logs-{}.txt", Local::now().format("%Y-%m-%dT%H-%M-%S"));
                    if let Some(path) = rfd::FileDialog::new().set_file_name(name).add_filter("txt", &["txt"]).save_file() {
                        // 匯出一律用遮罩版
                        s.status = Some(match std::fs::write(&path, logging::export_text()) {
                            Ok(()) => path.display().to_string(),
                            Err(e) => e.to_string(),
                        });
                    }
                }
                if let Some(st) = &s.status {
                    ui.label(RichText::new(st).small().weak());
                }
            });
        });
        ui.separator();

        let shown = filter_logs(&s.entries, s.level, s.category.as_deref(), &s.search);
        if shown.is_empty() {
            ui.vertical_centered(|ui| {
                ui.add_space(40.0);
                ui.label(RichText::new(t("logs.logEmpty")).weak());
            });
            return;
        }
        let row_h = ui.text_style_height(&egui::TextStyle::Monospace) + 4.0;
        egui::ScrollArea::vertical()
            .id_salt("log_rows")
            .auto_shrink([false, false])
            .stick_to_bottom(s.auto_scroll)
            .show_rows(ui, row_h, shown.len(), |ui, range| {
                for e in &shown[range] {
                    ui.horizontal(|ui| {
                        let ts = e.timestamp.with_timezone(&Local).format("%H:%M:%S%.3f").to_string();
                        ui.label(RichText::new(ts).monospace().small().weak());
                        ui.label(RichText::new(format!("{:<5}", level_name(e.level))).monospace().small().color(level_color(ui, Some(e.level))));
                        ui.label(RichText::new(format!("[{}]", e.category)).monospace().small().weak());
                        ui.add(egui::Label::new(RichText::new(&e.message).monospace().small()).truncate().selectable(true))
                            .on_hover_text(&e.message);
                    });
                }
            });
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;

    fn e(level: LogLevel, cat: &str, msg: &str) -> LogEntry {
        LogEntry { timestamp: Utc::now(), level, category: cat.into(), message: msg.into(), sensitive: false }
    }

    #[test]
    fn filters_combine() {
        let list = vec![e(LogLevel::Info, "STT", "start"), e(LogLevel::Error, "LLM", "HTTP 401"), e(LogLevel::Info, "LLM", "ok")];
        assert_eq!(filter_logs(&list, None, None, "").len(), 3);
        assert_eq!(filter_logs(&list, Some(LogLevel::Info), None, "").len(), 2);
        assert_eq!(filter_logs(&list, None, Some("LLM"), "").len(), 2);
        assert_eq!(filter_logs(&list, None, None, "http").len(), 1);
        assert_eq!(filter_logs(&list, None, None, "stt").len(), 1, "搜尋也比對分類");
        assert_eq!(filter_logs(&list, Some(LogLevel::Info), Some("LLM"), "o").len(), 1);
        assert_eq!(categories(&list), vec!["LLM".to_string(), "STT".to_string()]);
    }
}

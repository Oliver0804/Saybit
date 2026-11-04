//! 歷史分頁（移植 HistoryView.swift：搜尋、分頁載入、右鍵、刪除確認、匯出 JSON/MD/CSV）
use super::l10n::{t, tf};
use super::widgets;
use crate::app::AppState;
use chrono::{DateTime, Datelike, Local, Utc};
use egui::{RichText, Ui};
use saybit_core::llm::pricing;
use saybit_core::HistoryRecord;

const PAGE_SIZE: usize = 50;

#[derive(Debug, Clone, Copy, PartialEq)]
enum Confirm {
    One(i64),
    All,
    Older(u32),
}

#[derive(Debug, Clone, Copy)]
enum ExportFormat {
    Json,
    Markdown,
    Csv,
}

impl ExportFormat {
    fn ext(self) -> &'static str {
        match self {
            Self::Json => "json",
            Self::Markdown => "md",
            Self::Csv => "csv",
        }
    }
}

pub struct HistoryState {
    records: Option<Vec<HistoryRecord>>,
    total: usize,
    limit: usize,
    search: String,
    loaded_search: String,
    selected: Option<i64>,
    confirm: Option<Confirm>,
    error: Option<String>,
    cleaned: bool,
}

impl Default for HistoryState {
    fn default() -> Self {
        Self {
            records: None,
            total: 0,
            limit: PAGE_SIZE,
            search: String::new(),
            loaded_search: String::new(),
            selected: None,
            confirm: None,
            error: None,
            cleaned: false,
        }
    }
}

// ───────────────────────────── 純邏輯 ─────────────────────────────

/// 今天「15:49」、昨天「昨天 15:49」、今年「11/2 15:49」、跨年「2025/11/2 15:49」
pub fn short_time(ts: DateTime<Local>, now: DateTime<Local>) -> String {
    let time = ts.format("%H:%M").to_string();
    let (d, today) = (ts.date_naive(), now.date_naive());
    if d == today {
        time
    } else if today.pred_opt() == Some(d) {
        format!("{} {time}", t("history.yesterday"))
    } else if d.year() == today.year() {
        format!("{}/{} {time}", d.month(), d.day())
    } else {
        format!("{}/{}/{} {time}", d.year(), d.month(), d.day())
    }
}

/// CSV 欄位：以 = + - @ Tab CR 開頭前置單引號（防公式注入），雙引號跳脫，整欄加引號
pub fn csv_escape(s: &str) -> String {
    let mut v = String::with_capacity(s.len() + 3);
    if s.starts_with(['=', '+', '-', '@', '\t', '\r']) {
        v.push('\'');
    }
    v.push_str(s);
    format!("\"{}\"", v.replace('"', "\"\""))
}

fn iso(ts: &DateTime<Utc>) -> String {
    ts.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

pub fn encode_csv(records: &[HistoryRecord]) -> String {
    let mut out = String::from("timestamp,app,mode,model,duration_s,prompt_tokens,completion_tokens,total_tokens,raw,processed\n");
    for r in records {
        let row = [
            csv_escape(&iso(&r.timestamp)),
            csv_escape(&r.app_name),
            csv_escape(&r.mode),
            csv_escape(&r.model_name),
            format!("{:.2}", r.duration_secs),
            r.prompt_tokens.to_string(),
            r.completion_tokens.to_string(),
            r.total_tokens.to_string(),
            csv_escape(&r.raw_transcript),
            csv_escape(&r.processed_text),
        ];
        out.push_str(&row.join(","));
        out.push('\n');
    }
    out
}

pub fn encode_json(records: &[HistoryRecord]) -> String {
    let arr: Vec<serde_json::Value> = records
        .iter()
        .map(|r| {
            serde_json::json!({
                "id": r.id,
                "timestamp": iso(&r.timestamp),
                "appContext": r.app_name,
                "mode": r.mode,
                "rawTranscript": r.raw_transcript,
                "processedText": r.processed_text,
                "duration": r.duration_secs,
                "modelName": r.model_name,
                "promptTokens": r.prompt_tokens,
                "completionTokens": r.completion_tokens,
                "totalTokens": r.total_tokens,
                "costUsd": r.cost_usd,
            })
        })
        .collect();
    serde_json::to_string_pretty(&arr).unwrap_or_else(|_| "[]".into())
}

pub fn encode_markdown(records: &[HistoryRecord]) -> String {
    let mut out = format!("# {}\n\n{}\n\n---\n\n", t("history.mdTitle"), tf("history.mdCount", &[("n", &records.len().to_string())]));
    for r in records {
        let ts = r.timestamp.with_timezone(&Local).format("%Y-%m-%d %H:%M:%S");
        out.push_str(&format!("## {ts}\n\n"));
        if !r.app_name.is_empty() {
            out.push_str(&format!("- App: `{}`\n", r.app_name));
        }
        if !r.model_name.is_empty() {
            out.push_str(&format!("- Model: `{}`\n", r.model_name));
        }
        if r.total_tokens > 0 {
            let tok = tf(
                "history.mdTokens",
                &[("p", &r.prompt_tokens.to_string()), ("c", &r.completion_tokens.to_string()), ("t", &r.total_tokens.to_string())],
            );
            out.push_str(&format!("- Tokens: {tok}\n"));
        }
        out.push_str(&format!("- {}: {:.1}s\n\n", t("history.mdDuration"), r.duration_secs));
        if !r.raw_transcript.is_empty() {
            out.push_str(&format!("**{}**\n\n> {}\n\n", t("history.mdRaw"), r.raw_transcript.replace('\n', "\n> ")));
        }
        if !r.processed_text.is_empty() {
            out.push_str(&format!("**{}**\n\n{}\n\n", t("history.mdProcessed"), r.processed_text));
        }
        out.push_str("---\n\n");
    }
    out
}

fn record_cost(r: &HistoryRecord) -> Option<f64> {
    r.cost_usd.or_else(|| pricing::cost_usd(&r.model_name, r.prompt_tokens, r.completion_tokens))
}

pub fn mode_display_name(mode: &str) -> String {
    match mode {
        "dictation" => t("enum.mode.dictation"),
        "command" => t("enum.mode.command"),
        "edit" => t("enum.mode.edit"),
        _ => mode.to_string(),
    }
}

// ───────────────────────────── 資料 ─────────────────────────────

fn reload(state: &mut AppState) {
    let storage = match state.ui.storage() {
        Ok(s) => s,
        Err(e) => {
            state.ui.history.error = Some(e);
            state.ui.history.records = Some(Vec::new());
            return;
        }
    };
    let h = &mut state.ui.history;
    if !h.cleaned {
        h.cleaned = true;
        if state.settings.enable_history_auto_cleanup && state.settings.history_retention_days > 0 {
            let _ = storage.delete_history_older_than(state.settings.history_retention_days);
        }
    }
    let q = h.search.trim().to_string();
    let r = if q.is_empty() {
        storage.list_history(h.limit, 0).and_then(|list| Ok((list, storage.history_count()?)))
    } else {
        storage.search_history(&q, h.limit).map(|list| {
            let n = list.len();
            (list, n)
        })
    };
    match r {
        Ok((list, total)) => {
            h.total = total;
            if h.selected.is_some_and(|id| !list.iter().any(|r| r.id == id)) {
                h.selected = None;
            }
            h.records = Some(list);
            h.error = None;
        }
        Err(e) => {
            h.error = Some(e.to_string());
            h.records = Some(Vec::new());
        }
    }
    h.loaded_search = h.search.clone();
}

fn export(state: &mut AppState, fmt: ExportFormat) {
    let storage = match state.ui.storage() {
        Ok(s) => s,
        Err(e) => {
            state.ui.history.error = Some(e);
            return;
        }
    };
    let stamp = Local::now().format("%Y-%m-%dT%H-%M-%S");
    let Some(path) = rfd::FileDialog::new()
        .set_title(t("export.savePanelTitle"))
        .set_file_name(format!("saybit-history-{stamp}.{}", fmt.ext()))
        .add_filter(fmt.ext(), &[fmt.ext()])
        .save_file()
    else {
        return;
    };
    let r = storage.all_history().map_err(|e| e.to_string()).and_then(|all| {
        let body = match fmt {
            ExportFormat::Json => encode_json(&all),
            ExportFormat::Markdown => encode_markdown(&all),
            ExportFormat::Csv => encode_csv(&all),
        };
        std::fs::write(&path, body).map_err(|e| e.to_string())
    });
    if let Err(e) = r {
        state.ui.history.error = Some(e);
    }
}

fn perform(state: &mut AppState, c: Confirm) {
    let storage = match state.ui.storage() {
        Ok(s) => s,
        Err(e) => {
            state.ui.history.error = Some(e);
            return;
        }
    };
    let r = match c {
        Confirm::One(id) => storage.delete_history(id),
        Confirm::All => storage.delete_all_history(),
        Confirm::Older(days) => storage.delete_history_older_than(days).map(|_| ()),
    };
    if let Err(e) = r {
        state.ui.history.error = Some(e.to_string());
    }
    if c == Confirm::All {
        state.ui.history.limit = PAGE_SIZE;
    }
    reload(state);
}

// ───────────────────────────── UI ─────────────────────────────

pub fn show(ui: &mut Ui, state: &mut AppState) {
    if state.ui.history.records.is_none() || state.ui.history.search != state.ui.history.loaded_search {
        if state.ui.history.search != state.ui.history.loaded_search {
            state.ui.history.limit = PAGE_SIZE;
        }
        reload(state);
    }

    let mut want_more = false;
    let mut export_fmt = None;
    egui::Panel::left("history_list").default_size(340.0).resizable(true).show(ui, |ui| {
        list_panel(ui, state, &mut want_more, &mut export_fmt);
    });
    egui::CentralPanel::default().show(ui, |ui| detail_panel(ui, state));

    if want_more {
        state.ui.history.limit += PAGE_SIZE;
        reload(state);
    }
    if let Some(f) = export_fmt {
        export(state, f);
    }
    confirm_dialog(ui.ctx(), state);
}

fn list_panel(ui: &mut Ui, state: &mut AppState, want_more: &mut bool, export_fmt: &mut Option<ExportFormat>) {
    let h = &mut state.ui.history;
    ui.add_space(8.0);
    ui.horizontal(|ui| {
        ui.label("🔍");
        ui.add(egui::TextEdit::singleline(&mut h.search).hint_text(t("history.searchPlaceholder")).desired_width(f32::INFINITY));
    });
    if let Some(e) = &h.error {
        widgets::warn_label(ui, e);
    }
    let records = h.records.clone().unwrap_or_default();

    // 底部列（先畫在底部，列表填剩下空間）
    egui::Panel::bottom("history_bottom").show(ui, |ui| {
        ui.horizontal(|ui| {
            ui.label(RichText::new(format!("{} {}", h.total, t("history.recordCount"))).small());
            if records.len() < h.total {
                ui.label(RichText::new(tf("history.showing", &[("displayed", &records.len().to_string())])).small().weak());
            }
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                ui.menu_button(format!("🗑 {}", t("history.cleanup")), |ui| {
                    if ui.button(t("history.deleteOlder7")).clicked() {
                        h.confirm = Some(Confirm::Older(7));
                        ui.close();
                    }
                    if ui.button(t("history.deleteOlder30")).clicked() {
                        h.confirm = Some(Confirm::Older(30));
                        ui.close();
                    }
                    ui.separator();
                    if ui.button(RichText::new(t("history.deleteAll")).color(ui.visuals().error_fg_color)).clicked() {
                        h.confirm = Some(Confirm::All);
                        ui.close();
                    }
                });
                ui.menu_button(format!("⬆ {}", t("export.menuLabel")), |ui| {
                    for (f, k) in [(ExportFormat::Json, "export.asJSON"), (ExportFormat::Markdown, "export.asMarkdown"), (ExportFormat::Csv, "export.asCSV")] {
                        if ui.button(t(k)).clicked() {
                            *export_fmt = Some(f);
                            ui.close();
                        }
                    }
                });
            });
        });
    });

    if records.is_empty() && h.search.trim().is_empty() {
        ui.vertical_centered(|ui| {
            ui.add_space(60.0);
            ui.label(RichText::new("🕘").size(32.0).weak());
            ui.label(RichText::new(t("history.emptyTitle")).strong());
            ui.label(RichText::new(t("history.emptyDesc")).weak());
        });
        return;
    }

    let now = Local::now();
    egui::ScrollArea::vertical().id_salt("history_rows").auto_shrink([false, false]).show(ui, |ui| {
        let n = records.len();
        for (i, r) in records.iter().enumerate() {
            let selected = h.selected == Some(r.id);
            let text = if r.processed_text.is_empty() { &r.raw_transcript } else { &r.processed_text };
            let resp = egui::Frame::new()
                .fill(if selected { ui.visuals().selection.bg_fill.gamma_multiply(0.35) } else { egui::Color32::TRANSPARENT })
                .corner_radius(6)
                .inner_margin(6)
                .show(ui, |ui| {
                    ui.set_width(ui.available_width());
                    ui.add(egui::Label::new(text.as_str()).truncate());
                    ui.horizontal(|ui| {
                        ui.label(RichText::new(&r.app_name).small().weak());
                        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                            ui.label(RichText::new(short_time(r.timestamp.with_timezone(&Local), now)).small().weak());
                        });
                    });
                })
                .response
                .interact(egui::Sense::click());
            if resp.clicked() {
                h.selected = Some(r.id);
            }
            resp.context_menu(|ui| {
                if ui.button(t("history.copyResult")).clicked() {
                    ui.ctx().copy_text(text.clone());
                    ui.close();
                }
                if ui.button(t("history.copyRaw")).clicked() {
                    ui.ctx().copy_text(r.raw_transcript.clone());
                    ui.close();
                }
                ui.separator();
                if ui.button(RichText::new(t("common.delete")).color(ui.visuals().error_fg_color)).clicked() {
                    h.confirm = Some(Confirm::One(r.id));
                    ui.close();
                }
            });
            // 捲到最後一筆就載入下一頁
            if i + 1 == n && n < h.total && ui.is_rect_visible(resp.rect) {
                *want_more = true;
            }
        }
    });
}

fn detail_panel(ui: &mut Ui, state: &mut AppState) {
    let h = &mut state.ui.history;
    let Some(r) = h.selected.and_then(|id| h.records.as_ref()?.iter().find(|r| r.id == id).cloned()) else {
        ui.centered_and_justified(|ui| {
            ui.label(RichText::new(t("history.selectRecord")).weak());
        });
        return;
    };
    super::scroll_page(ui, "history_detail", |ui| {
        widgets::card(ui, |ui| {
            widgets::section_header(ui, "🎤", &t("history.rawTranscript"));
            ui.add(egui::Label::new(if r.raw_transcript.is_empty() { "-" } else { &r.raw_transcript }).selectable(true).wrap());
        });
        widgets::card(ui, |ui| {
            widgets::section_header(ui, "✔", &t("history.processedText"));
            ui.add(egui::Label::new(if r.processed_text.is_empty() { "-" } else { &r.processed_text }).selectable(true).wrap());
        });
        widgets::card(ui, |ui| {
            ui.spacing_mut().item_spacing.y = 6.0;
            ui.horizontal(|ui| {
                ui.label(RichText::new(format!("▣ {}", if r.app_name.is_empty() { "-" } else { &r.app_name })).small());
                ui.label(RichText::new(format!("· {}", mode_display_name(&r.mode))).small().weak());
                if r.duration_secs > 0.0 {
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        ui.label(RichText::new(format!("⏱ {:.1}s", r.duration_secs)).small());
                    });
                }
            });
            ui.separator();
            if !r.model_name.is_empty() {
                ui.label(RichText::new(format!("🖥 {}", r.model_name)).small().weak());
            }
            if r.total_tokens > 0 {
                ui.horizontal(|ui| {
                    ui.label(RichText::new(tf("history.inputTokens", &[("n", &r.prompt_tokens.to_string())])).small().weak());
                    ui.label(RichText::new(tf("history.outputTokens", &[("n", &r.completion_tokens.to_string())])).small().weak());
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        ui.label(RichText::new(tf("history.totalTokensLabel", &[("n", &r.total_tokens.to_string())])).small().weak());
                    });
                });
                if let Some(c) = record_cost(&r) {
                    ui.label(RichText::new(tf("cost.perRecord", &[("formatted", &pricing::format_usd(c))])).small().weak());
                }
            }
            ui.label(RichText::new(format!("📅 {}", r.timestamp.with_timezone(&Local).format("%Y-%m-%d %H:%M:%S"))).small().weak());
        });
        ui.horizontal(|ui| {
            if ui.button(format!("⎘ {}", t("history.copyResult"))).clicked() {
                ui.ctx().copy_text(r.processed_text.clone());
            }
            if ui.button(format!("⎘ {}", t("history.copyRaw"))).clicked() {
                ui.ctx().copy_text(r.raw_transcript.clone());
            }
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if ui.button(RichText::new(format!("🗑 {}", t("common.delete"))).color(ui.visuals().error_fg_color)).clicked() {
                    h.confirm = Some(Confirm::One(r.id));
                }
            });
        });
    });
}

fn confirm_dialog(ctx: &egui::Context, state: &mut AppState) {
    let Some(c) = state.ui.history.confirm else { return };
    let (title, msg, button) = match c {
        Confirm::One(_) => (t("history.confirmDelete"), t("history.cannotUndo"), t("common.delete")),
        Confirm::All => (
            t("history.confirmDeleteAll"),
            tf("history.deleteAllMessage", &[("count", &state.ui.history.total.to_string())]),
            t("history.deleteAll"),
        ),
        Confirm::Older(d) => (
            t("history.confirmDeleteOlder"),
            t("history.cannotUndo"),
            t(if d == 30 { "history.deleteOlder30" } else { "history.deleteOlder7" }),
        ),
    };
    let mut result = None;
    egui::Modal::new(egui::Id::unique("history_confirm")).show(ctx, |ui| {
        ui.set_max_width(380.0);
        ui.heading(title);
        ui.label(msg);
        ui.horizontal(|ui| {
            if ui.button(RichText::new(button).color(ui.visuals().error_fg_color)).clicked() {
                result = Some(true);
            }
            if ui.button(t("common.cancel")).clicked() {
                result = Some(false);
            }
        });
    });
    if let Some(ok) = result {
        state.ui.history.confirm = None;
        if ok {
            perform(state, c);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn rec(raw: &str, processed: &str) -> HistoryRecord {
        HistoryRecord {
            id: 1,
            timestamp: Utc.with_ymd_and_hms(2026, 11, 2, 7, 49, 0).unwrap(),
            raw_transcript: raw.into(),
            processed_text: processed.into(),
            app_name: "Slack".into(),
            mode: "dictation".into(),
            model_name: "gpt-4.1-nano".into(),
            duration_secs: 2.5,
            prompt_tokens: 10,
            completion_tokens: 5,
            total_tokens: 15,
            cost_usd: None,
        }
    }

    #[test]
    fn csv_escape_blocks_formula_injection() {
        assert_eq!(csv_escape("hello"), "\"hello\"");
        assert_eq!(csv_escape("=SUM(A1)"), "\"'=SUM(A1)\"");
        assert_eq!(csv_escape("+1"), "\"'+1\"");
        assert_eq!(csv_escape("-1"), "\"'-1\"");
        assert_eq!(csv_escape("@cmd"), "\"'@cmd\"");
        assert_eq!(csv_escape("\tx"), "\"'\tx\"");
        assert_eq!(csv_escape("say \"hi\""), "\"say \"\"hi\"\"\"");
        assert_eq!(csv_escape("a,b\nc"), "\"a,b\nc\"");
    }

    #[test]
    fn csv_has_header_and_rows() {
        let csv = encode_csv(&[rec("=1+1", "ok")]);
        let mut lines = csv.lines();
        assert!(lines.next().unwrap().starts_with("timestamp,app,mode"));
        let row = lines.next().unwrap();
        assert!(row.contains("\"'=1+1\""));
        assert!(row.contains(",2.50,10,5,15,"));
    }

    #[test]
    fn json_export_is_array() {
        let v: serde_json::Value = serde_json::from_str(&encode_json(&[rec("a", "b")])).unwrap();
        assert_eq!(v[0]["processedText"], "b");
        assert_eq!(v[0]["totalTokens"], 15);
    }

    #[test]
    fn short_time_formats() {
        let now = Local.with_ymd_and_hms(2026, 11, 4, 12, 0, 0).unwrap();
        let today = Local.with_ymd_and_hms(2026, 11, 4, 9, 5, 0).unwrap();
        let yesterday = Local.with_ymd_and_hms(2026, 11, 3, 15, 49, 0).unwrap();
        let earlier = Local.with_ymd_and_hms(2026, 1, 2, 8, 0, 0).unwrap();
        let last_year = Local.with_ymd_and_hms(2025, 12, 31, 23, 59, 0).unwrap();
        assert_eq!(short_time(today, now), "09:05");
        assert!(short_time(yesterday, now).ends_with(" 15:49"));
        assert_eq!(short_time(earlier, now), "1/2 08:00");
        assert_eq!(short_time(last_year, now), "2025/12/31 23:59");
    }
}

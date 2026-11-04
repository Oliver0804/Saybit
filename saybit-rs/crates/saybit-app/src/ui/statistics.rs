//! 統計分頁（移植 StatisticsView.swift：每日次數補齊空白日、Token 趨勢、常用 App、模式分佈、成本估算）
use super::history::mode_display_name;
use super::l10n::{t, tf};
use super::widgets;
use crate::app::AppState;
use chrono::{Local, NaiveDate};
use egui::{Color32, RichText, Ui};
use egui_plot::{Bar, BarChart, Line, Plot, PlotPoints};
use saybit_core::llm::pricing;
use saybit_core::HistoryRecord;
use std::collections::HashMap;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum TimeRange {
    #[default]
    Week,
    Month,
    All,
}

#[derive(Default)]
pub struct StatisticsState {
    range: TimeRange,
    records: Option<Vec<HistoryRecord>>,
    loaded_at: Option<Instant>,
    error: Option<String>,
}

// ───────────────────────────── 純邏輯 ─────────────────────────────

fn local_day(r: &HistoryRecord) -> NaiveDate {
    r.timestamp.with_timezone(&Local).date_naive()
}

/// 時間範圍內的紀錄（7 天 = 今天往回 6 天起算）
pub fn filter_range(records: &[HistoryRecord], range: TimeRange, today: NaiveDate) -> Vec<&HistoryRecord> {
    let start = match range {
        TimeRange::Week => today - chrono::Days::new(6),
        TimeRange::Month => today - chrono::Days::new(29),
        TimeRange::All => NaiveDate::MIN,
    };
    records.iter().filter(|r| local_day(r) >= start).collect()
}

/// 圖表要畫的每一天（沒用的日子也要有）；「全部」從最早一筆起算
pub fn chart_days(range: TimeRange, records: &[&HistoryRecord], today: NaiveDate) -> Vec<NaiveDate> {
    let start = match range {
        TimeRange::Week => today - chrono::Days::new(6),
        TimeRange::Month => today - chrono::Days::new(29),
        TimeRange::All => records.iter().map(|r| local_day(r)).min().unwrap_or(today).min(today),
    };
    start.iter_days().take_while(|d| *d <= today).collect()
}

/// 每天的 (次數, token)，順序同 days；沒紀錄的日子補 0
pub fn daily_series(records: &[&HistoryRecord], days: &[NaiveDate]) -> Vec<(usize, u64)> {
    let mut map: HashMap<NaiveDate, (usize, u64)> = HashMap::new();
    for r in records {
        let e = map.entry(local_day(r)).or_default();
        e.0 += 1;
        e.1 += r.total_tokens as u64;
    }
    days.iter().map(|d| map.get(d).copied().unwrap_or_default()).collect()
}

/// 依 key 分組計數，次數多的在前（同數依名稱）
fn count_by<'a>(records: &[&'a HistoryRecord], key: impl Fn(&'a HistoryRecord) -> String) -> Vec<(String, usize)> {
    let mut map: HashMap<String, usize> = HashMap::new();
    for r in records {
        *map.entry(key(r)).or_default() += 1;
    }
    let mut v: Vec<_> = map.into_iter().collect();
    v.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    v
}

pub fn top_apps(records: &[&HistoryRecord]) -> Vec<(String, usize)> {
    count_by(records, |r| if r.app_name.is_empty() { "Unknown".into() } else { r.app_name.clone() })
}

pub fn mode_distribution(records: &[&HistoryRecord]) -> Vec<(String, usize)> {
    count_by(records, |r| if r.mode.is_empty() { "dictation".into() } else { r.mode.clone() })
}

/// (估算總成本, 無法估算的筆數)；沒用到 token 的紀錄不算未知
pub fn cost_summary(records: &[&HistoryRecord]) -> (f64, usize) {
    let mut total = 0.0;
    let mut unknown = 0;
    for r in records {
        if r.total_tokens == 0 {
            continue;
        }
        match r.cost_usd.or_else(|| pricing::cost_usd(&r.model_name, r.prompt_tokens, r.completion_tokens)) {
            Some(c) => total += c,
            None => unknown += 1,
        }
    }
    (total, unknown)
}

pub fn format_number(n: u64) -> String {
    if n >= 1_000_000 {
        format!("{:.1}M", n as f64 / 1_000_000.0)
    } else if n >= 1_000 {
        format!("{:.1}K", n as f64 / 1_000.0)
    } else {
        n.to_string()
    }
}

fn mode_color(mode: &str) -> Color32 {
    match mode {
        "dictation" => Color32::from_rgb(0, 122, 255),
        "command" => Color32::from_rgb(255, 149, 0),
        "edit" => Color32::from_rgb(52, 199, 89),
        _ => Color32::GRAY,
    }
}

// ───────────────────────────── UI ─────────────────────────────

fn reload(state: &mut AppState) {
    let st = &mut state.ui.statistics;
    st.loaded_at = Some(Instant::now());
    let r = state.ui.storage().and_then(|s| s.all_history().map_err(|e| e.to_string()));
    let st = &mut state.ui.statistics;
    match r {
        Ok(v) => {
            st.records = Some(v);
            st.error = None;
        }
        Err(e) => {
            st.records = Some(Vec::new());
            st.error = Some(e);
        }
    }
}

pub fn show(ui: &mut Ui, state: &mut AppState) {
    if state.ui.statistics.loaded_at.is_none_or(|t| t.elapsed() > Duration::from_secs(30)) {
        reload(state);
    }
    let st = &mut state.ui.statistics;
    let all = st.records.clone().unwrap_or_default();
    let today = Local::now().date_naive();
    let records = filter_range(&all, st.range, today);
    let days = chart_days(st.range, &records, today);
    let series = daily_series(&records, &days);

    super::scroll_page(ui, "statistics", |ui| {
        ui.horizontal(|ui| {
            ui.label(t("stats.timeRange"));
            for (r, k) in [(TimeRange::Week, "stats.week"), (TimeRange::Month, "stats.month"), (TimeRange::All, "stats.all")] {
                ui.selectable_value(&mut st.range, r, t(k));
            }
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if ui.small_button("⟳").on_hover_text(t("common.recheck")).clicked() {
                    st.loaded_at = None;
                }
            });
        });
        if let Some(e) = &st.error {
            widgets::warn_label(ui, e);
        }

        summary_row(ui, &records, today);
        cost_card(ui, &records);

        let labels: Vec<String> = days.iter().map(|d| d.format("%-m/%-d").to_string()).collect();
        widgets::card(ui, |ui| {
            widgets::section_header(ui, "📊", &t("stats.dailyUsage"));
            let bars: Vec<Bar> = series
                .iter()
                .enumerate()
                .map(|(i, (c, _))| Bar::new(i as f64, *c as f64).name(&labels[i]).width(0.7))
                .collect();
            let chart = BarChart::new(t("stats.chartCount"), bars).color(Color32::from_rgb(0, 122, 255));
            date_plot(ui, "daily_usage_plot", &labels).show(ui, |p| p.bar_chart(chart));
        });
        widgets::card(ui, |ui| {
            widgets::section_header(ui, "📈", &t("stats.tokenTrend"));
            let pts: PlotPoints = series.iter().enumerate().map(|(i, (_, tok))| [i as f64, *tok as f64]).collect();
            let line = Line::new("Token", pts).color(Color32::from_rgb(175, 82, 222)).width(2.0);
            date_plot(ui, "token_trend_plot", &labels).show(ui, |p| p.line(line));
        });

        ui.columns(2, |cols| {
            top_apps_card(&mut cols[0], &records);
            modes_card(&mut cols[1], &records);
        });
    });
}

fn date_plot<'a>(_ui: &Ui, id: &'a str, labels: &'a [String]) -> Plot<'a> {
    let n = labels.len();
    let step = if n <= 10 { 1 } else if n <= 40 { 7 } else { (n / 8).max(1) };
    Plot::new(id)
        .height(180.0)
        .allow_zoom(false)
        .allow_drag(false)
        .allow_scroll(false)
        .allow_boxed_zoom(false)
        .allow_double_click_reset(false)
        .show_x(false)
        .include_y(0.0)
        .x_axis_formatter(move |mark, _| {
            let i = mark.value.round();
            if (mark.value - i).abs() > 1e-6 || i < 0.0 {
                return String::new();
            }
            let i = i as usize;
            if i < n && i.is_multiple_of(step) {
                labels[i].clone()
            } else {
                String::new()
            }
        })
}

fn stat_tile(ui: &mut Ui, title: &str, value: &str, icon: &str) {
    widgets::card(ui, |ui| {
        ui.label(RichText::new(format!("{icon} {title}")).small().weak());
        ui.label(RichText::new(value).size(22.0).strong());
    });
}

fn summary_row(ui: &mut Ui, records: &[&HistoryRecord], today: NaiveDate) {
    let total = records.len();
    let tokens: u64 = records.iter().map(|r| r.total_tokens as u64).sum();
    let avg = if total == 0 { 0.0 } else { records.iter().map(|r| r.duration_secs as f64).sum::<f64>() / total as f64 };
    let today_count = records.iter().filter(|r| local_day(r) == today).count();
    ui.columns(4, |cols| {
        stat_tile(&mut cols[0], &t("stats.totalCount"), &total.to_string(), "#");
        stat_tile(&mut cols[1], &t("stats.totalTokens"), &format_number(tokens), "◆");
        stat_tile(&mut cols[2], &t("stats.avgDuration"), &format!("{avg:.1}s"), "⏱");
        stat_tile(&mut cols[3], &t("stats.todayCount"), &today_count.to_string(), "☀");
    });
}

fn cost_card(ui: &mut Ui, records: &[&HistoryRecord]) {
    let (total, unknown) = cost_summary(records);
    widgets::card(ui, |ui| {
        ui.horizontal(|ui| {
            ui.label(RichText::new("$").strong());
            ui.label(t("cost.totalEstimate"));
            ui.label(RichText::new(pricing::format_usd(total)).size(18.0).strong());
            if unknown > 0 {
                ui.label(RichText::new(tf("cost.unknownIgnored", &[("n", &unknown.to_string())])).small().weak());
            }
        });
    });
}

fn top_apps_card(ui: &mut Ui, records: &[&HistoryRecord]) {
    let apps = top_apps(records);
    widgets::card(ui, |ui| {
        widgets::section_header(ui, "▣", &t("stats.topApps"));
        if apps.is_empty() {
            ui.label(RichText::new(t("stats.noData")).weak());
            return;
        }
        let max = apps[0].1.max(1) as f32;
        for (app, count) in apps.iter().take(5) {
            ui.horizontal(|ui| {
                ui.label(app);
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    ui.label(RichText::new(format!("{count} {}", t("stats.times"))).small().weak());
                });
            });
            ui.add(egui::ProgressBar::new(*count as f32 / max).desired_height(6.0));
        }
    });
}

fn modes_card(ui: &mut Ui, records: &[&HistoryRecord]) {
    let modes = mode_distribution(records);
    widgets::card(ui, |ui| {
        widgets::section_header(ui, "◔", &t("stats.modeDistribution"));
        if modes.is_empty() {
            ui.label(RichText::new(t("stats.noData")).weak());
            return;
        }
        let total: usize = modes.iter().map(|m| m.1).sum();
        // 一條分段比例條＋圖例（egui_plot 沒有圓餅圖）
        let (rect, _) = ui.allocate_exact_size(egui::vec2(ui.available_width(), 12.0), egui::Sense::hover());
        let mut x = rect.left();
        for (mode, count) in &modes {
            let w = rect.width() * *count as f32 / total.max(1) as f32;
            let r = egui::Rect::from_min_size(egui::pos2(x, rect.top()), egui::vec2(w, rect.height()));
            ui.painter().rect_filled(r, 2.0, mode_color(mode));
            x += w;
        }
        for (mode, count) in &modes {
            ui.horizontal(|ui| {
                ui.label(RichText::new("●").color(mode_color(mode)));
                ui.label(RichText::new(mode_display_name(mode)).small());
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    ui.label(RichText::new(count.to_string()).small().weak());
                });
            });
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{TimeZone, Utc};

    fn rec(day: u32, tokens: u32, app: &str, mode: &str) -> HistoryRecord {
        // 中午 UTC：任何時區都落在同一個本地日期附近；測試以本地日期換算
        let ts = Local.with_ymd_and_hms(2026, 11, day, 12, 0, 0).unwrap().with_timezone(&Utc);
        HistoryRecord {
            id: day as i64,
            timestamp: ts,
            raw_transcript: String::new(),
            processed_text: String::new(),
            app_name: app.into(),
            mode: mode.into(),
            model_name: String::new(),
            duration_secs: 1.0,
            prompt_tokens: 0,
            completion_tokens: 0,
            total_tokens: tokens,
            cost_usd: Some(0.001),
        }
    }

    #[test]
    fn week_fills_empty_days() {
        let today = NaiveDate::from_ymd_opt(2026, 11, 10).unwrap();
        let all = vec![rec(10, 5, "Slack", "dictation"), rec(10, 7, "Mail", "command"), rec(6, 3, "Slack", "dictation"), rec(1, 1, "X", "")];
        let records = filter_range(&all, TimeRange::Week, today);
        assert_eq!(records.len(), 3, "11/1 在 7 天外");
        let days = chart_days(TimeRange::Week, &records, today);
        assert_eq!(days.len(), 7);
        assert_eq!(days[0], NaiveDate::from_ymd_opt(2026, 11, 4).unwrap());
        let s = daily_series(&records, &days);
        assert_eq!(s.len(), 7);
        assert_eq!(s[6], (2, 12));
        assert_eq!(s[2], (1, 3));
        assert_eq!(s[0], (0, 0));
    }

    #[test]
    fn all_range_starts_at_first_record() {
        let today = NaiveDate::from_ymd_opt(2026, 11, 10).unwrap();
        let all = vec![rec(1, 1, "X", ""), rec(10, 1, "X", "")];
        let records = filter_range(&all, TimeRange::All, today);
        let days = chart_days(TimeRange::All, &records, today);
        assert_eq!(days.len(), 10);
        let empty: Vec<&HistoryRecord> = Vec::new();
        assert_eq!(chart_days(TimeRange::All, &empty, today), vec![today]);
    }

    #[test]
    fn grouping_and_cost() {
        let all = [rec(1, 5, "Slack", "dictation"), rec(2, 0, "Slack", ""), rec(3, 5, "", "command")];
        let refs: Vec<&HistoryRecord> = all.iter().collect();
        assert_eq!(top_apps(&refs)[0], ("Slack".to_string(), 2));
        assert_eq!(mode_distribution(&refs)[0], ("dictation".to_string(), 2));
        let (total, unknown) = cost_summary(&refs);
        assert!((total - 0.002).abs() < 1e-9);
        assert_eq!(unknown, 0);
    }

    #[test]
    fn number_format() {
        assert_eq!(format_number(999), "999");
        assert_eq!(format_number(1_500), "1.5K");
        assert_eq!(format_number(2_000_000), "2.0M");
    }
}

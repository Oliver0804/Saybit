//! 設定頁共用元件（對應 SettingsView.swift 的 GlassCard / SettingRow / SettingToggle / SettingSlider / SettingIndent / SettingDescription）
//! 與背景任務、快捷鍵錄製的 fallback。
use super::l10n::t;
use crossbeam_channel::{Receiver, Sender};
use egui::{Align, Color32, Layout, Margin, RichText, Stroke, Ui, Vec2};
use saybit_core::CancelToken;
use std::time::{Duration, Instant};

// ───────────────────────────── 搜尋 ─────────────────────────────

/// 關鍵字任一項（不分大小寫）包含 query 就算符合；空 query 一律符合（移植 settingsMatchesSearch）
pub fn matches_search(keywords: &[&str], query: &str) -> bool {
    let q = query.trim().to_lowercase();
    if q.is_empty() {
        return true;
    }
    keywords.iter().any(|k| k.to_lowercase().contains(&q))
}

// ───────────────────────────── 卡片與列 ─────────────────────────────

/// 卡片 frame：用 A1 的 `theme::glass_card()`
pub fn card_frame(_ui: &Ui) -> egui::Frame {
    crate::theme::glass_card()
}

/// 一張卡片：寬度撐滿
pub fn card<R>(ui: &mut Ui, add: impl FnOnce(&mut Ui) -> R) -> R {
    card_frame(ui)
        .show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.spacing_mut().item_spacing.y = 10.0;
            add(ui)
        })
        .inner
}

pub fn section_header(ui: &mut Ui, icon: &str, title: &str) {
    crate::theme::section_header(ui, icon, title);
}

/// 說明文字（callout 大小、次要色、自動換行）
pub fn description(ui: &mut Ui, text: &str) {
    ui.add(egui::Label::new(RichText::new(text).size(12.5).color(ui.visuals().weak_text_color())).wrap());
}

/// 左邊標題＋說明，右邊控制項（靠右）
pub fn setting_row(ui: &mut Ui, title: &str, desc: Option<&str>, trailing: impl FnOnce(&mut Ui)) {
    ui.horizontal(|ui| {
        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
            trailing(ui);
            ui.add_space(12.0);
            let w = ui.available_width().max(80.0);
            ui.allocate_ui_with_layout(Vec2::new(w, 0.0), Layout::top_down(Align::Min), |ui| {
                ui.spacing_mut().item_spacing.y = 3.0;
                ui.add(egui::Label::new(title).wrap());
                if let Some(d) = desc.filter(|d| !d.is_empty()) {
                    description(ui, d);
                }
            });
        });
    });
}

/// 開關列；回傳是否變更
pub fn setting_toggle(ui: &mut Ui, title: &str, desc: Option<&str>, on: &mut bool) -> bool {
    let mut changed = false;
    setting_row(ui, title, desc, |ui| {
        changed = toggle_switch(ui, on).changed();
    });
    changed
}

/// 滑桿列：標題＋目前數值，下方滑桿；回傳是否變更
#[allow(clippy::too_many_arguments)]
pub fn setting_slider(
    ui: &mut Ui,
    title: &str,
    value_text: &str,
    value: &mut f32,
    range: std::ops::RangeInclusive<f32>,
    step: f64,
    desc: Option<&str>,
) -> bool {
    ui.horizontal(|ui| {
        ui.label(title);
        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
            ui.label(RichText::new(value_text).monospace().color(ui.visuals().weak_text_color()));
        });
    });
    let changed = ui
        .scope(|ui| {
            ui.spacing_mut().slider_width = (ui.available_width() - 8.0).max(80.0);
            ui.add(egui::Slider::new(value, range).step_by(step).show_value(false)).changed()
        })
        .inner;
    if let Some(d) = desc {
        description(ui, d);
    }
    changed
}

/// 子設定往內縮，左側一條細線
pub fn setting_indent<R>(ui: &mut Ui, add: impl FnOnce(&mut Ui) -> R) -> R {
    let line = ui.visuals().widgets.noninteractive.bg_stroke.color;
    let resp = egui::Frame::new()
        .inner_margin(Margin { left: 14, right: 0, top: 0, bottom: 0 })
        .show(ui, |ui| {
            ui.set_width(ui.available_width());
            add(ui)
        });
    let r = resp.response.rect;
    ui.painter().line_segment(
        [egui::pos2(r.left() + 1.0, r.top()), egui::pos2(r.left() + 1.0, r.bottom())],
        Stroke::new(2.0, line),
    );
    resp.inner
}

/// 沒有符合搜尋的項目
pub fn no_results(ui: &mut Ui) {
    ui.vertical_centered(|ui| {
        ui.add_space(60.0);
        ui.label(RichText::new("🔍").size(28.0).color(ui.visuals().weak_text_color()));
        ui.label(RichText::new(t("common.noResults")).color(ui.visuals().weak_text_color()));
    });
}

/// iOS 風格開關（egui demo 的 toggle_switch）
pub fn toggle_switch(ui: &mut Ui, on: &mut bool) -> egui::Response {
    let size = ui.spacing().interact_size.y * egui::vec2(1.8, 0.9);
    let (rect, mut response) = ui.allocate_exact_size(size, egui::Sense::click());
    if response.clicked() {
        *on = !*on;
        response.mark_changed();
    }
    response.widget_info(|| egui::WidgetInfo::selected(egui::Role::Switch, ui.is_enabled(), *on, ""));
    if ui.is_rect_visible(rect) {
        let how_on = ui.ctx().animate_bool_responsive(response.id, *on);
        let visuals = ui.style().interact_selectable(&response, *on);
        let rect = rect.expand(visuals.expansion);
        let radius = 0.5 * rect.height();
        let fill = if *on { ui.visuals().selection.bg_fill } else { visuals.bg_fill };
        ui.painter().rect(rect, radius, fill, visuals.bg_stroke, egui::StrokeKind::Inside);
        let cx = egui::lerp((rect.left() + radius)..=(rect.right() - radius), how_on);
        let center = egui::pos2(cx, rect.center().y);
        ui.painter().circle(center, 0.75 * radius, Color32::WHITE, visuals.fg_stroke);
    }
    response
}

/// 綠勾／紅叉狀態字
pub fn status_label(ui: &mut Ui, ok: bool, text: &str) {
    let color = if ok { Color32::from_rgb(52, 168, 83) } else { ui.visuals().error_fg_color };
    let icon = if ok { "✔" } else { "✖" };
    ui.label(RichText::new(format!("{icon} {text}")).color(color));
}

pub fn warn_label(ui: &mut Ui, text: &str) {
    ui.add(egui::Label::new(RichText::new(format!("⚠ {text}")).color(ui.visuals().warn_fg_color)).wrap());
}

pub fn info_label(ui: &mut Ui, text: &str) {
    ui.add(egui::Label::new(RichText::new(format!("ℹ {text}")).color(ui.visuals().weak_text_color())).wrap());
}

/// 外部連結：交給 platform::open_url（不在 egui 內開）
pub fn link(ui: &mut Ui, text: &str, url: &str) {
    if ui.link(text).on_hover_text(url).clicked() {
        saybit_core::platform::open_url(url);
    }
}

/// 格式化位元組（MB / GB）
pub fn format_bytes(bytes: u64) -> String {
    let mb = bytes as f64 / 1_000_000.0;
    if mb >= 1000.0 {
        format!("{:.1} GB", mb / 1000.0)
    } else {
        format!("{mb:.0} MB")
    }
}

// ───────────────────────────── API key 欄位 ─────────────────────────────

/// API key 輸入欄（存 secure_store）。不把已存的 key 回填到欄位，只顯示已設定／未設定。
#[derive(Default)]
pub struct SecretField {
    account: String,
    input: String,
    show: bool,
    has_key: Option<bool>,
    status: Option<(String, Instant)>,
}

impl SecretField {
    fn sync(&mut self, account: &str) {
        if self.account != account || self.has_key.is_none() {
            self.account = account.to_string();
            self.input.clear();
            self.status = None;
            self.has_key = Some(saybit_core::secure_store::get(account).is_some_and(|k| !k.is_empty()));
        }
    }

    /// 目前欄位內容（未儲存的也算）；空字串回 None
    pub fn pending_input(&self) -> Option<String> {
        let s = self.input.trim();
        (!s.is_empty()).then(|| s.to_string())
    }

    pub fn flash(&mut self, msg: String) {
        self.status = Some((msg, Instant::now()));
    }

    /// 回傳 true = key 已變更（存或清除）
    pub fn ui(&mut self, ui: &mut Ui, account: &str, placeholder: &str) -> bool {
        self.sync(account);
        let mut changed = false;
        ui.horizontal(|ui| {
            let w = (ui.available_width() - 210.0).max(120.0);
            let resp = ui.add(
                egui::TextEdit::singleline(&mut self.input)
                    .password(!self.show)
                    .hint_text(placeholder.to_string())
                    .desired_width(w),
            );
            if ui.small_button(if self.show { t("common.hide") } else { t("common.show") }).clicked() {
                self.show = !self.show;
            }
            let enter = resp.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter));
            if (ui.add_enabled(self.pending_input().is_some(), egui::Button::new(t("common.save"))).clicked() || enter)
                && self.pending_input().is_some()
            {
                let key = self.pending_input().unwrap_or_default();
                match saybit_core::secure_store::set(account, &key) {
                    Ok(()) => {
                        self.input.clear();
                        self.has_key = Some(true);
                        self.flash(t("common.saved"));
                        changed = true;
                    }
                    Err(e) => self.flash(format!("{}：{e}", t("common.saveFailed"))),
                }
            }
            if self.has_key == Some(true) && ui.small_button(t("api.clear")).clicked() {
                match saybit_core::secure_store::delete(account) {
                    Ok(()) => {
                        self.has_key = Some(false);
                        self.flash(t("common.cleared"));
                        changed = true;
                    }
                    Err(e) => self.flash(e.to_string()),
                }
            }
        });
        ui.horizontal(|ui| {
            status_label(ui, self.has_key == Some(true), &t(if self.has_key == Some(true) { "common.set" } else { "common.notSet" }));
            if let Some((msg, at)) = &self.status {
                if at.elapsed() < Duration::from_secs(3) {
                    ui.label(RichText::new(msg).color(ui.visuals().weak_text_color()));
                    ui.ctx().request_repaint_after(Duration::from_millis(500));
                }
            }
        });
        changed
    }
}

// ───────────────────────────── 背景任務 ─────────────────────────────

/// 背景執行緒回報器：每次送出都順便叫醒 UI 重畫
pub struct Reporter<T> {
    tx: Sender<T>,
    ctx: egui::Context,
}

impl<T> Reporter<T> {
    pub fn send(&self, v: T) {
        let _ = self.tx.send(v);
        self.ctx.request_repaint();
    }
}

/// 背景任務把手：UI 每幀 `poll()` 取訊息；drop 不會中止執行緒，要中止用 `cancel()`
pub struct BgTask<T> {
    rx: Receiver<T>,
    pub cancel: CancelToken,
}

impl<T: Send + 'static> BgTask<T> {
    pub fn spawn(ctx: &egui::Context, f: impl FnOnce(Reporter<T>, CancelToken) + Send + 'static) -> Self {
        let (tx, rx) = crossbeam_channel::unbounded();
        let cancel = CancelToken::new();
        let reporter = Reporter { tx, ctx: ctx.clone() };
        let c = cancel.clone();
        std::thread::spawn(move || f(reporter, c));
        Self { rx, cancel }
    }

    pub fn poll(&self) -> Vec<T> {
        self.rx.try_iter().collect()
    }
}

// ───────────────────────────── 快捷鍵 ─────────────────────────────

/// 比較兩組快捷鍵是否相同（不分大小寫、修飾鍵順序無關）
pub fn hotkey_eq(a: &str, b: &str) -> bool {
    fn norm(s: &str) -> Vec<String> {
        let mut v: Vec<String> = s
            .split('+')
            .map(|p| match p.trim().to_ascii_lowercase().as_str() {
                "control" => "ctrl".into(),
                "option" => "alt".into(),
                "command" | "super" => "cmd".into(),
                x => x.to_string(),
            })
            .collect();
        v.sort();
        v
    }
    norm(a) == norm(b)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn search_matches_case_insensitive_and_empty() {
        assert!(matches_search(&["OpenRouter", "模型"], ""));
        assert!(matches_search(&["OpenRouter", "模型"], "openr"));
        assert!(matches_search(&["OpenRouter", "模型"], " 模型 "));
        assert!(!matches_search(&["OpenRouter"], "whisper"));
    }

    #[test]
    fn hotkey_eq_ignores_order_and_case() {
        assert!(hotkey_eq("Ctrl+Alt+Space", "alt+control+space"));
        assert!(!hotkey_eq("Ctrl+Alt+Space", "Ctrl+Space"));
    }

    #[test]
    fn bytes_format() {
        assert_eq!(format_bytes(237_115_547), "237 MB");
        assert_eq!(format_bytes(1_600_000_000), "1.6 GB");
    }
}

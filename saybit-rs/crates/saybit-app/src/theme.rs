//! 深色主題與共用外觀元件（A1 提供，A2 的設定分頁共用）。
//! 對照原生版 GlassCard / GlassSectionHeader：半透明深色卡片、細白邊、12pt 圓角。

use egui::{Color32, CornerRadius, Frame, Margin, RichText, Shadow, Stroke};

/// 主色（原生版 AccentColor 的紫藍）
pub const ACCENT: Color32 = Color32::from_rgb(124, 108, 255);
pub const BG: Color32 = Color32::from_rgb(22, 22, 26);
pub const PANEL: Color32 = Color32::from_rgb(28, 28, 33);
pub const CARD: Color32 = Color32::from_rgba_premultiplied(40, 40, 46, 235);
pub const TEXT: Color32 = Color32::from_rgb(232, 232, 236);
pub const TEXT_DIM: Color32 = Color32::from_rgb(160, 160, 170);
pub const SUCCESS: Color32 = Color32::from_rgb(52, 199, 89);
pub const WARNING: Color32 = Color32::from_rgb(255, 159, 10);
pub const DANGER: Color32 = Color32::from_rgb(255, 69, 58);
pub const MODE_PURPLE: Color32 = Color32::from_rgb(140, 82, 220);

/// 套用整體深色風格。字型大小沿用 egui 預設再略放大，接近 macOS 13pt body。
pub fn apply(ctx: &egui::Context) {
    let mut visuals = egui::Visuals::dark();
    visuals.panel_fill = PANEL;
    visuals.window_fill = BG;
    visuals.extreme_bg_color = Color32::from_rgb(16, 16, 19);
    visuals.faint_bg_color = Color32::from_rgb(34, 34, 40);
    visuals.selection.bg_fill = ACCENT.linear_multiply(0.55);
    visuals.selection.stroke = Stroke::new(1.0, ACCENT);
    visuals.hyperlink_color = Color32::from_rgb(140, 170, 255);
    visuals.window_corner_radius = CornerRadius::same(12);
    visuals.menu_corner_radius = CornerRadius::same(8);
    visuals.widgets.noninteractive.fg_stroke = Stroke::new(1.0, TEXT);
    visuals.widgets.inactive.corner_radius = CornerRadius::same(6);
    visuals.widgets.hovered.corner_radius = CornerRadius::same(6);
    visuals.widgets.active.corner_radius = CornerRadius::same(6);
    visuals.widgets.inactive.bg_fill = Color32::from_rgb(52, 52, 60);
    visuals.widgets.inactive.weak_bg_fill = Color32::from_rgb(52, 52, 60);
    visuals.widgets.hovered.weak_bg_fill = Color32::from_rgb(64, 64, 74);
    ctx.set_visuals_of(egui::Theme::Dark, visuals.clone());
    ctx.set_visuals_of(egui::Theme::Light, visuals);
    ctx.set_theme(egui::ThemePreference::Dark);
    ctx.all_styles_mut(|style| {
        style.spacing.item_spacing = egui::vec2(8.0, 6.0);
        style.spacing.button_padding = egui::vec2(10.0, 4.0);
        style.spacing.interact_size.y = 24.0;
        use egui::{FontFamily, FontId, TextStyle};
        style.text_styles = [
            (TextStyle::Heading, FontId::new(20.0, FontFamily::Proportional)),
            (TextStyle::Body, FontId::new(14.0, FontFamily::Proportional)),
            (TextStyle::Button, FontId::new(14.0, FontFamily::Proportional)),
            (TextStyle::Small, FontId::new(11.5, FontFamily::Proportional)),
            (TextStyle::Monospace, FontId::new(13.0, FontFamily::Monospace)),
        ]
        .into();
    });
}

/// 玻璃卡片外框（GlassCard）。用法：`theme::glass_card().show(ui, |ui| { ... });`
pub fn glass_card() -> Frame {
    Frame::new()
        .fill(CARD)
        .stroke(Stroke::new(1.0, Color32::from_white_alpha(22)))
        .corner_radius(CornerRadius::same(12))
        .inner_margin(Margin::same(14))
        .outer_margin(Margin::symmetric(0, 4))
        .shadow(Shadow { offset: [0, 2], blur: 10, spread: 0, color: Color32::from_black_alpha(60) })
}

/// 卡片標題（GlassSectionHeader）：小圖示字元＋粗體標題
pub fn section_header(ui: &mut egui::Ui, icon: &str, title: &str) {
    ui.horizontal(|ui| {
        if !icon.is_empty() {
            ui.label(RichText::new(icon).color(ACCENT).size(15.0));
        }
        ui.label(RichText::new(title).strong().size(15.0).color(TEXT));
    });
    ui.add_space(4.0);
}

/// 說明文字（SettingDescription，對應 .callout）
pub fn description(ui: &mut egui::Ui, text: &str) {
    ui.label(RichText::new(text).size(12.5).color(TEXT_DIM));
}

/// 主要按鈕（強調色底）
pub fn primary_button(text: impl Into<String>) -> egui::Button<'static> {
    egui::Button::new(RichText::new(text.into()).color(Color32::WHITE).strong())
        .fill(ACCENT)
        .corner_radius(CornerRadius::same(7))
}

/// 小圓形步驟編號
pub fn step_badge(ui: &mut egui::Ui, n: usize) {
    let (rect, _) = ui.allocate_exact_size(egui::vec2(20.0, 20.0), egui::Sense::hover());
    ui.painter().circle_filled(rect.center(), 10.0, ACCENT);
    ui.painter().text(
        rect.center(),
        egui::Align2::CENTER_CENTER,
        n.to_string(),
        egui::FontId::proportional(12.0),
        Color32::WHITE,
    );
}

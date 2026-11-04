//! 浮動膠囊（對照 UI/Overlay/OverlayView.swift、OverlayWindow.swift）。
//!
//! egui deferred viewport：透明、無邊框、置頂、不在工作列。視窗大小貼著膠囊（＋光暈留白），
//! 以「上緣中央」為錨點（`settings.overlay_position = (center_x, top_y)`，單位 point），內容變寬時左右對稱長。
//! 拖曳自己處理：按住移動 ≥ 4 pt 才算拖，否則放開＝點擊（聆聽模式切換／停止）。
//! egui 的右鍵選單只能畫在視窗內，選單開著時把視窗暫時放大。

use crate::theme;
use crate::ui::l10n::{t, tf};
use egui::text::LayoutJob;
use egui::{
    pos2, vec2, Color32, CornerRadius, FontId, Frame, Margin, Pos2, Rect, Sense, Shadow, Stroke, TextFormat, Ui,
    UiBuilder, Vec2, ViewportBuilder, ViewportCommand, ViewportId,
};
use parking_lot::Mutex;
use saybit_core::{PendingAction, PipelineCommand, PipelineSnapshot, PipelineState};
use std::collections::VecDeque;
use std::sync::Arc;
use std::time::{Duration, Instant};

pub const DRAG_THRESHOLD: f32 = 4.0;
pub const WAVE_BARS: usize = 20;
pub const TOAST_DURATION: Duration = Duration::from_secs(3);
/// 選單開著時視窗至少這麼大（point，不跟 capsule_scale 縮放）
const MENU_WINDOW: Vec2 = Vec2::new(240.0, 230.0);

pub fn overlay_id() -> ViewportId {
    ViewportId::from_hash_of("saybit-overlay")
}

// ───────────────────────────── 純邏輯 ─────────────────────────────

/// 按下後移動 ≥ 4 pt 才算拖曳
#[derive(Debug, Default, Clone)]
pub struct DragGate {
    press: Option<Pos2>,
    dragging: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DragOutcome {
    None,
    Click,
    DragEnd,
}

impl DragGate {
    pub fn press(&mut self, at: Pos2) {
        self.press = Some(at);
        self.dragging = false;
    }
    pub fn is_pressed(&self) -> bool {
        self.press.is_some()
    }
    /// 回傳目前是否在拖曳（超過門檻後一直為 true 直到放開）
    pub fn update(&mut self, at: Pos2) -> bool {
        if let Some(p) = self.press {
            if !self.dragging && p.distance(at) >= DRAG_THRESHOLD {
                self.dragging = true;
            }
        }
        self.dragging
    }
    pub fn press_origin(&self) -> Option<Pos2> {
        self.press
    }
    pub fn release(&mut self) -> DragOutcome {
        let out = match (self.press.take(), self.dragging) {
            (None, _) => DragOutcome::None,
            (Some(_), true) => DragOutcome::DragEnd,
            (Some(_), false) => DragOutcome::Click,
        };
        self.dragging = false;
        out
    }
}

/// 錨點（上緣中央）＋視窗大小 → 視窗左上角
pub fn top_left(anchor: Pos2, size: Vec2) -> Pos2 {
    pos2(anchor.x - size.x / 2.0, anchor.y)
}

/// 讓 (anchor, size) 對應的視窗完整落在某個螢幕內：先找相交面積最大的螢幕，沒有相交就找中心最近的。
pub fn clamp_anchor(anchor: Pos2, size: Vec2, displays: &[Rect]) -> Pos2 {
    if displays.is_empty() {
        return anchor;
    }
    let rect = Rect::from_min_size(top_left(anchor, size), size);
    let area = |r: &Rect| {
        let i = r.intersect(rect);
        if i.is_positive() { i.area() } else { 0.0 }
    };
    let best = displays
        .iter()
        .max_by(|a, b| area(a).total_cmp(&area(b)))
        .filter(|d| area(d) > 0.0)
        .or_else(|| {
            displays.iter().min_by(|a, b| {
                a.center().distance(rect.center()).total_cmp(&b.center().distance(rect.center()))
            })
        })
        .copied()
        .unwrap_or(rect);
    let w = size.x.min(best.width());
    let h = size.y.min(best.height());
    let x = rect.min.x.clamp(best.min.x, best.max.x - w);
    let y = rect.min.y.clamp(best.min.y, best.max.y - h);
    pos2(x + size.x / 2.0, y)
}

/// 主螢幕上方中央（macOS 讓出選單列）
pub fn default_anchor(displays: &[Rect]) -> Pos2 {
    let d = displays.first().copied().unwrap_or(Rect::from_min_size(Pos2::ZERO, vec2(1440.0, 900.0)));
    let top_inset = if cfg!(target_os = "macos") { 34.0 } else { 12.0 };
    pos2(d.center().x, d.min.y + top_inset)
}

/// 所有螢幕的範圍（point；主螢幕排第一）。拿不到就回空陣列。
pub fn displays() -> Vec<Rect> {
    let Ok(mut all) = display_info::DisplayInfo::all() else { return Vec::new() };
    all.sort_by_key(|d| !d.is_primary);
    all.iter()
        .map(|d| {
            // macOS 回 point；Windows / X11 回實體像素，除以縮放
            let s = if cfg!(target_os = "macos") { 1.0 } else { d.scale_factor.max(1.0) };
            Rect::from_min_size(pos2(d.x as f32 / s, d.y as f32 / s), vec2(d.width as f32 / s, d.height as f32 / s))
        })
        .collect()
}

// ───────────────────────────── 共用狀態 ─────────────────────────────

#[derive(Debug, Clone)]
pub enum OverlayAction {
    Pipeline(PipelineCommand),
    /// 會注入文字的命令：macOS 先把焦點還給外部 App 再送
    RefocusThen(PipelineCommand),
    ToggleSmartSend,
    ResetPosition,
    OpenSettings,
    Quit,
    /// 拖曳結束後的新錨點（已 clamp）
    SavePosition(Pos2),
    /// 引導未完成時點膠囊
    NotAllowed,
}

pub struct OverlayShared {
    pub snapshot: PipelineSnapshot,
    pub levels: VecDeque<f32>,
    pub scale: f32,
    pub smart_send: bool,
    pub supports_actions: bool,
    pub recording_allowed: bool,
    pub toast: Option<(String, Instant)>,
    pub anchor: Pos2,
    pub displays: Vec<Rect>,
    pub outbox: Vec<OverlayAction>,
    win_size: Vec2,
    capsule_rect: Rect,
    drag: DragGate,
    menu_open: bool,
}

pub type Shared = Arc<Mutex<OverlayShared>>;

impl OverlayShared {
    pub fn new(anchor: Pos2, displays: Vec<Rect>) -> Shared {
        Arc::new(Mutex::new(Self {
            snapshot: PipelineSnapshot::default(),
            levels: VecDeque::from(vec![0.0; WAVE_BARS]),
            scale: 1.0,
            smart_send: false,
            supports_actions: false,
            recording_allowed: true,
            toast: None,
            anchor,
            displays,
            outbox: Vec::new(),
            win_size: vec2(160.0, 60.0),
            capsule_rect: Rect::NOTHING,
            drag: DragGate::default(),
            menu_open: false,
        }))
    }

    pub fn push_level(&mut self, level: f32) {
        if self.levels.len() >= WAVE_BARS {
            self.levels.pop_front();
        }
        self.levels.push_back(level.clamp(0.0, 1.0));
    }

    pub fn toast_active(&self) -> bool {
        self.toast.as_ref().is_some_and(|(_, at)| at.elapsed() < TOAST_DURATION)
    }
}

/// 在 root 的 ui pass 呼叫（每幀都要呼叫，膠囊才會存在）
pub fn show(ctx: &egui::Context, shared: &Shared) {
    let (pos, size) = {
        let s = shared.lock();
        (top_left(s.anchor, s.win_size), s.win_size)
    };
    let builder = ViewportBuilder::default()
        .with_title("Saybit Overlay")
        .with_decorations(false)
        .with_transparent(true)
        .with_resizable(false)
        .with_always_on_top()
        .with_taskbar(false)
        .with_has_shadow(false)
        .with_active(false)
        .with_inner_size(size)
        .with_position(pos);
    let shared = shared.clone();
    ctx.show_viewport_deferred(overlay_id(), builder, move |ui, _class| draw(ui, &shared));
}

// ───────────────────────────── 繪製 ─────────────────────────────

fn draw(ui: &mut Ui, shared: &Shared) {
    let ctx = ui.ctx().clone();
    let mut sh = shared.lock();
    let s = sh.scale.clamp(0.5, 2.0);
    let pad = 16.0 * s;
    let snap = sh.snapshot.clone();
    let time = ctx.input(|i| i.time) as f32;
    let mut actions: Vec<OverlayAction> = Vec::new();

    // 背景互動區（用上一幀的膠囊範圍；先註冊，按鈕在上層會優先）
    let bg_resp = ui.interact(sh.capsule_rect, ui.scope_id().with("capsule-bg"), Sense::click_and_drag());
    handle_pointer(&ctx, &mut sh, &bg_resp, &snap, &mut actions);

    let previewing = matches!(snap.state, PipelineState::Previewing);
    let radius = if previewing { (16.0 * s) as u8 } else { 255 };
    let (fill, border, glow) = colors(&snap.state, time);
    let frame = Frame::new()
        .fill(fill)
        .stroke(Stroke::new(1.5 * s, border))
        .corner_radius(CornerRadius::same(radius))
        .inner_margin(if previewing {
            Margin::symmetric((16.0 * s) as i8, (10.0 * s) as i8)
        } else {
            Margin::symmetric((14.0 * s) as i8, (6.0 * s) as i8)
        })
        .shadow(Shadow { offset: [0, (3.0 * s) as i8], blur: (12.0 * s) as u8, spread: 0, color: glow });

    let (min_w, min_h) = min_size(&snap);
    let area = Rect::from_min_size(pos2(pad, pad), vec2(2000.0, 2000.0));
    let capsule = ui
        .scope_builder(UiBuilder::new().max_rect(area), |ui| {
            frame
                .show(ui, |ui| {
                    let inner_min = vec2(min_w * s - 28.0 * s, min_h * s - 12.0 * s);
                    ui.set_min_size(inner_min);
                    if previewing {
                        // 卡片寬度固定，分隔線等元件才不會撐到整個可用寬度
                        ui.set_max_width(inner_min.x.max(340.0 * s - 32.0 * s));
                        preview_content(ui, &snap, s, sh.supports_actions, &mut actions);
                    } else {
                        ui.set_max_width(440.0 * s);
                        ui.allocate_ui_with_layout(
                            vec2(440.0 * s, inner_min.y),
                            egui::Layout::left_to_right(egui::Align::Center),
                            |ui| {
                                ui.set_min_height(inner_min.y);
                                ui.spacing_mut().item_spacing.x = 7.0 * s;
                                state_content(ui, &snap, &sh.levels, s, time, &mut actions);
                            },
                        );
                    }
                })
                .response
                .rect
        })
        .inner;
    sh.capsule_rect = capsule;

    // 右鍵選單
    let listening = matches!(snap.state, PipelineState::Listening);
    let smart_send = sh.smart_send;
    let menu = bg_resp.context_menu(|ui| {
        ui.set_min_width(180.0);
        let mut l = listening;
        if ui.checkbox(&mut l, t("overlay.listeningMode")).clicked() {
            actions.push(OverlayAction::Pipeline(if listening {
                PipelineCommand::CancelListening
            } else {
                PipelineCommand::StartListening
            }));
            ui.close();
        }
        let mut ss = smart_send;
        if ui.checkbox(&mut ss, t("tray.smartSend")).clicked() {
            actions.push(OverlayAction::ToggleSmartSend);
            ui.close();
        }
        ui.separator();
        if ui.button(t("overlay.resetPosition")).clicked() {
            actions.push(OverlayAction::ResetPosition);
            ui.close();
        }
        if ui.button(t("tray.settings")).clicked() {
            actions.push(OverlayAction::OpenSettings);
            ui.close();
        }
        ui.separator();
        if ui.button(t("common.quit")).clicked() {
            actions.push(OverlayAction::Quit);
            ui.close();
        }
    });
    sh.menu_open = menu.is_some();

    // toast（膠囊下方 3 秒）
    let mut bottom = capsule.max.y;
    let mut right = capsule.max.x;
    if let Some((text, at)) = sh.toast.clone() {
        if at.elapsed() < TOAST_DURATION {
            let toast_area = Rect::from_min_size(pos2(pad, capsule.max.y + 6.0 * s), vec2(380.0 * s, 200.0));
            let r = ui
                .scope_builder(UiBuilder::new().max_rect(toast_area), |ui| {
                    Frame::new()
                        .fill(Color32::from_rgba_unmultiplied(28, 28, 32, 235))
                        .stroke(Stroke::new(1.0, Color32::from_white_alpha(40)))
                        .corner_radius(CornerRadius::same((12.0 * s) as u8))
                        .inner_margin(Margin::symmetric((12.0 * s) as i8, (6.0 * s) as i8))
                        .show(ui, |ui| {
                            ui.add(egui::Label::new(limited(&text, 3, 12.0 * s, Color32::WHITE, 360.0 * s)).wrap());
                        })
                        .response
                        .rect
                })
                .inner;
            bottom = r.max.y;
            right = right.max(r.max.x);
            ctx.request_repaint_after(TOAST_DURATION.saturating_sub(at.elapsed()));
        } else {
            sh.toast = None;
        }
    }

    // 視窗大小跟著內容走（錨點固定在上緣中央）
    let mut want = vec2(right + pad, bottom + pad).ceil();
    if sh.menu_open {
        want = want.max(MENU_WINDOW);
    }
    if (want - sh.win_size).length() > 1.0 && !sh.drag.is_pressed() {
        sh.win_size = want;
        ctx.send_viewport_cmd(ViewportCommand::InnerSize(want));
        ctx.send_viewport_cmd(ViewportCommand::OuterPosition(top_left(sh.anchor, want)));
        ctx.request_repaint_of(ViewportId::ROOT);
    }

    if matches!(
        snap.state,
        PipelineState::Listening | PipelineState::Recording | PipelineState::Processing | PipelineState::Confirming { .. }
    ) {
        ctx.request_repaint_after(Duration::from_millis(50));
    }

    if !actions.is_empty() {
        sh.outbox.extend(actions);
        ctx.request_repaint_of(ViewportId::ROOT);
    }
}

fn handle_pointer(
    ctx: &egui::Context,
    sh: &mut OverlayShared,
    bg: &egui::Response,
    snap: &PipelineSnapshot,
    actions: &mut Vec<OverlayAction>,
) {
    let (pressed, released, down, pos, outer) = ctx.input(|i| {
        (
            i.pointer.primary_pressed(),
            i.pointer.primary_released(),
            i.pointer.primary_down(),
            i.pointer.latest_pos(),
            i.viewport().outer_rect,
        )
    });
    if pressed && bg.hovered() {
        if let Some(p) = pos {
            sh.drag.press(p);
        }
    }
    if down && sh.drag.is_pressed() {
        if let (Some(p), Some(origin), Some(outer)) = (pos, sh.drag.press_origin(), outer) {
            if sh.drag.update(p) {
                // 視窗跟著游標走：游標在視窗內的相對位置維持在按下時的位置
                let delta = p - origin;
                if delta.length() > 0.5 {
                    let new_min = outer.min + delta;
                    sh.anchor = pos2(new_min.x + sh.win_size.x / 2.0, new_min.y);
                    ctx.send_viewport_cmd(ViewportCommand::OuterPosition(new_min));
                }
            }
        }
    }
    if released {
        match sh.drag.release() {
            DragOutcome::Click => {
                if let Some(a) = tap_action(&snap.state, sh.recording_allowed) {
                    actions.push(a);
                }
            }
            DragOutcome::DragEnd => {
                sh.anchor = clamp_anchor(sh.anchor, sh.win_size, &sh.displays);
                ctx.send_viewport_cmd(ViewportCommand::OuterPosition(top_left(sh.anchor, sh.win_size)));
                actions.push(OverlayAction::SavePosition(sh.anchor));
            }
            DragOutcome::None => {}
        }
    }
}

/// 點膠囊（移植 handleCapsuleTap）
pub fn tap_action(state: &PipelineState, recording_allowed: bool) -> Option<OverlayAction> {
    match state {
        PipelineState::Idle | PipelineState::Confirming { .. } if !recording_allowed => Some(OverlayAction::NotAllowed),
        PipelineState::Idle => Some(OverlayAction::Pipeline(PipelineCommand::StartListening)),
        PipelineState::Listening => Some(OverlayAction::Pipeline(PipelineCommand::CancelListening)),
        PipelineState::Recording => Some(OverlayAction::RefocusThen(PipelineCommand::StopRecording)),
        PipelineState::Confirming { .. } => Some(OverlayAction::Pipeline(PipelineCommand::ToggleRecording { mode: None })),
        _ => None,
    }
}

fn min_size(snap: &PipelineSnapshot) -> (f32, f32) {
    match &snap.state {
        PipelineState::Idle => (120.0, 36.0),
        PipelineState::Listening => (200.0, 36.0),
        PipelineState::Recording => (if snap.raw_transcript.is_empty() { 200.0 } else { 240.0 }, 36.0),
        PipelineState::Processing => (160.0, 36.0),
        PipelineState::Done => (160.0, 36.0),
        PipelineState::Previewing => (340.0, 80.0),
        PipelineState::Confirming { .. } => (180.0, 36.0),
        PipelineState::Error(_) => (if snap.can_retry { 320.0 } else { 260.0 }, 36.0),
    }
}

fn pulse(time: f32, period: f32) -> f32 {
    // 0..1 來回
    (1.0 - (time * std::f32::consts::TAU / period).cos()) / 2.0
}

/// (底色, 邊框, 外光暈)
fn colors(state: &PipelineState, time: f32) -> (Color32, Color32, Color32) {
    let fill = Color32::from_rgba_unmultiplied(24, 24, 28, 225);
    let breathe = 0.4 + 0.6 * (1.0 - pulse(time, 1.6));
    let (border, glow) = match state {
        PipelineState::Idle => (Color32::from_white_alpha(50), Color32::from_black_alpha(80)),
        PipelineState::Listening => (alpha(Color32::ORANGE, 0.5), alpha(Color32::ORANGE, 0.35)),
        PipelineState::Recording => (alpha(Color32::RED, 0.6), alpha(Color32::RED, 0.3)),
        PipelineState::Processing => (alpha(Color32::ORANGE, 0.5), Color32::from_black_alpha(80)),
        PipelineState::Done => (alpha(theme::SUCCESS, 0.5), Color32::from_black_alpha(80)),
        PipelineState::Previewing => (alpha(Color32::LIGHT_BLUE, 0.5), alpha(Color32::LIGHT_BLUE, 0.3)),
        PipelineState::Confirming { .. } => (alpha(CYAN, 0.6), alpha(CYAN, 0.4 * breathe)),
        PipelineState::Error(_) => (alpha(Color32::RED, 0.5), Color32::from_black_alpha(80)),
    };
    (fill, border, glow)
}

const CYAN: Color32 = Color32::from_rgb(50, 210, 235);

fn alpha(c: Color32, a: f32) -> Color32 {
    Color32::from_rgba_unmultiplied(c.r(), c.g(), c.b(), (a.clamp(0.0, 1.0) * 255.0) as u8)
}

/// 最多 `rows` 行、超過寬度自動換行並以 … 結尾（中日文可任意斷行）
fn limited(text: &str, rows: usize, size: f32, color: Color32, max_width: f32) -> LayoutJob {
    let mut job = LayoutJob::single_section(text.to_string(), TextFormat::simple(FontId::proportional(size), color));
    job.wrap.max_width = max_width;
    job.wrap.max_rows = rows;
    job.wrap.break_anywhere = true;
    job.wrap.overflow_character = Some('…');
    job
}

fn text(ui: &mut Ui, s: impl Into<String>, size: f32, color: Color32) {
    ui.label(egui::RichText::new(s).size(size).color(color));
}

fn mode_tag(ui: &mut Ui, snap: &PipelineSnapshot, s: f32) {
    let Some(name) = snap.mode_name.as_deref().filter(|n| !n.is_empty()) else { return };
    Frame::new()
        .fill(alpha(theme::MODE_PURPLE, 0.8))
        .corner_radius(CornerRadius::same(255))
        .inner_margin(Margin::symmetric((7.0 * s) as i8, (2.0 * s) as i8))
        .show(ui, |ui| {
            ui.label(egui::RichText::new(name).size(10.0 * s).strong().color(Color32::WHITE));
        });
}

fn waveform(ui: &mut Ui, levels: &VecDeque<f32>, width: f32, height: f32, s: f32) {
    let (rect, _) = ui.allocate_exact_size(vec2(width * s, height * s), Sense::hover());
    let n = levels.len().max(1);
    // 窄波形（聆聽模式 40 pt）時縮小間距，長條才不會畫出範圍外
    let gap = (2.0 * s).min(rect.width() / (n as f32 * 2.0));
    let bar_w = ((rect.width() - gap * (n as f32 - 1.0)) / n as f32).max(1.0);
    for (i, level) in levels.iter().enumerate() {
        let h = (level * 20.0 * s).clamp(2.0 * s, rect.height());
        let x = rect.min.x + i as f32 * (bar_w + gap);
        let r = Rect::from_center_size(pos2(x + bar_w / 2.0, rect.center().y), vec2(bar_w, h));
        ui.painter().rect_filled(r, CornerRadius::same(1), Color32::from_white_alpha(215));
    }
}

fn shown_text(snap: &PipelineSnapshot) -> &str {
    if snap.processed_text.is_empty() { &snap.raw_transcript } else { &snap.processed_text }
}

fn format_duration(d: Duration) -> String {
    let secs = d.as_secs();
    format!("{}:{:02}", secs / 60, secs % 60)
}

pub fn format_usd(v: f64) -> String {
    if v < 0.01 { format!("${v:.4}") } else { format!("${v:.2}") }
}

fn state_content(
    ui: &mut Ui,
    snap: &PipelineSnapshot,
    levels: &VecDeque<f32>,
    s: f32,
    time: f32,
    actions: &mut Vec<OverlayAction>,
) {
    let dim = Color32::from_white_alpha(180);
    match &snap.state {
        PipelineState::Idle => {
            text(ui, "🎤", 13.0 * s, Color32::from_white_alpha(205));
            text(ui, "Saybit", 12.5 * s, dim);
        }
        PipelineState::Listening => {
            let k = 1.0 + 0.3 * pulse(time, 1.6);
            text(ui, "🎤", 13.0 * s * k, Color32::ORANGE);
            waveform(ui, levels, 40.0, 16.0, s);
            text(ui, t("overlay.listening"), 11.5 * s, alpha(Color32::ORANGE, 0.85));
        }
        PipelineState::Recording => {
            let (rect, _) = ui.allocate_exact_size(vec2(14.0 * s, 14.0 * s), Sense::hover());
            let k = 1.0 + 0.4 * pulse(time, 1.2);
            ui.painter().circle_filled(rect.center(), 5.0 * s * k, Color32::RED);
            mode_tag(ui, snap, s);
            waveform(ui, levels, 80.0, 20.0, s);
            let elapsed = snap.recording_started_at.map(|t| t.elapsed()).unwrap_or_default();
            ui.label(
                egui::RichText::new(format_duration(elapsed))
                    .font(FontId::monospace(11.0 * s))
                    .color(Color32::from_white_alpha(128)),
            );
            let n = snap.raw_transcript.chars().count();
            if n > 0 {
                ui.label(
                    egui::RichText::new(format!("{n} {}", t("overlay.chars")))
                        .font(FontId::monospace(10.0 * s))
                        .color(Color32::from_white_alpha(90)),
                );
            }
        }
        PipelineState::Processing => {
            ui.add(egui::Spinner::new().size(12.0 * s).color(Color32::WHITE));
            mode_tag(ui, snap, s);
            text(ui, t("overlay.processing"), 12.5 * s, dim);
            let dots = ((time / 0.4) as usize % 3) + 1;
            ui.add_sized(
                vec2(20.0 * s, 12.0 * s),
                egui::Label::new(egui::RichText::new(".".repeat(dots)).size(12.5 * s).strong().color(Color32::from_white_alpha(128))),
            );
        }
        PipelineState::Done => {
            text(ui, "✔", 12.5 * s, theme::SUCCESS);
            ui.vertical(|ui| {
                ui.spacing_mut().item_spacing.y = 2.0 * s;
                ui.add(egui::Label::new(limited(shown_text(snap), 2, 12.5 * s, Color32::WHITE, 340.0 * s)));
                if snap.usage.total_tokens > 0 {
                    let line = match snap.cost_usd {
                        Some(c) => format!("{} tokens · {}", snap.usage.total_tokens, format_usd(c)),
                        None => format!("{} tokens", snap.usage.total_tokens),
                    };
                    ui.label(egui::RichText::new(line).font(FontId::monospace(9.5 * s)).color(Color32::from_white_alpha(80)));
                }
            });
        }
        PipelineState::Confirming { remaining_secs } => {
            let breathe = 0.4 + 0.6 * (1.0 - pulse(time, 1.6));
            let n = remaining_secs.max(0.0).ceil() as i64;
            ui.label(egui::RichText::new(n.to_string()).size(17.0 * s).strong().color(alpha(CYAN, breathe)));
            let c = Color32::from_white_alpha(((breathe * 0.7 + 0.3) * 255.0) as u8);
            ui.add(egui::Label::new(limited(shown_text(snap), 2, 12.5 * s, c, 340.0 * s)));
        }
        PipelineState::Error(msg) => {
            text(ui, "⚠", 12.5 * s, Color32::RED);
            ui.add(egui::Label::new(limited(msg, 2, 11.5 * s, alpha(Color32::from_rgb(255, 90, 80), 0.95), 360.0 * s)));
            if snap.can_retry {
                let b = egui::Button::new(egui::RichText::new(format!("⟳ {}", t("overlay.retry"))).size(10.5 * s))
                    .fill(alpha(theme::WARNING, 0.25));
                if ui.add(b).clicked() {
                    actions.push(OverlayAction::RefocusThen(PipelineCommand::RetryLastAction));
                }
            }
        }
        PipelineState::Previewing => {}
    }
}

pub fn describe_action(a: &PendingAction) -> String {
    match a {
        PendingAction::CalendarEvent { title, start, .. } => tf("overlay.calendarEvent", &[("title", title), ("start", start)]),
        PendingAction::Reminder { title, .. } => tf("overlay.reminder", &[("title", title)]),
    }
}

fn preview_content(ui: &mut Ui, snap: &PipelineSnapshot, s: f32, supports_actions: bool, actions: &mut Vec<OverlayAction>) {
    ui.vertical(|ui| {
        ui.spacing_mut().item_spacing.y = 8.0 * s;
        ui.horizontal(|ui| {
            text(ui, "👁", 12.5 * s, Color32::LIGHT_BLUE);
            let body = match &snap.pending_action {
                Some(a) => format!("{}\n{}", describe_action(a), shown_text(snap)),
                None => shown_text(snap).to_string(),
            };
            ui.add(egui::Label::new(limited(body.trim(), 3, 12.5 * s, Color32::WHITE, 300.0 * s)));
        });
        if snap.pending_action.is_some() && !supports_actions {
            text(ui, t("overlay.unsupportedAction"), 10.5 * s, Color32::from_white_alpha(150));
        }
        ui.separator();
        ui.horizontal(|ui| {
            let btn = |label: String, color: Color32| {
                egui::Button::new(egui::RichText::new(label).size(11.5 * s).color(Color32::WHITE)).fill(alpha(color, 0.35))
            };
            if snap.pending_action.is_some() {
                if supports_actions && ui.add(btn(format!("✔ {}", t("overlay.createAction")), theme::SUCCESS)).clicked() {
                    actions.push(OverlayAction::Pipeline(PipelineCommand::ConfirmAction));
                }
            } else {
                if ui.add(btn(format!("✔ {}", t("overlay.inject")), theme::SUCCESS)).clicked() {
                    actions.push(OverlayAction::RefocusThen(PipelineCommand::ConfirmInject));
                }
                if ui.add(btn(format!("⟳ {}", t("overlay.regenerate")), theme::WARNING)).clicked() {
                    actions.push(OverlayAction::Pipeline(PipelineCommand::Regenerate));
                }
            }
            if ui.add(btn(format!("✖ {}", t("common.cancel")), Color32::GRAY)).clicked() {
                actions.push(OverlayAction::Pipeline(PipelineCommand::CancelPreview));
            }
        });
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drag_threshold_is_four_points() {
        let mut g = DragGate::default();
        g.press(pos2(10.0, 10.0));
        assert!(!g.update(pos2(12.0, 12.0))); // 2.8 pt
        assert_eq!(g.release(), DragOutcome::Click);

        g.press(pos2(10.0, 10.0));
        assert!(g.update(pos2(14.0, 10.0))); // 剛好 4 pt
        assert!(g.update(pos2(11.0, 10.0))); // 回頭仍算拖曳
        assert_eq!(g.release(), DragOutcome::DragEnd);
        assert_eq!(g.release(), DragOutcome::None);
    }

    #[test]
    fn clamp_keeps_window_on_nearest_display() {
        let displays = [
            Rect::from_min_size(pos2(0.0, 0.0), vec2(1440.0, 900.0)),
            Rect::from_min_size(pos2(1440.0, -200.0), vec2(1920.0, 1080.0)),
        ];
        let size = vec2(200.0, 60.0);
        // 在第二螢幕內：不動
        assert_eq!(clamp_anchor(pos2(2000.0, 100.0), size, &displays), pos2(2000.0, 100.0));
        // 超出主螢幕左上：拉回
        assert_eq!(clamp_anchor(pos2(20.0, -30.0), size, &displays), pos2(100.0, 0.0));
        // 跨兩螢幕：留在相交較多的那個
        let a = clamp_anchor(pos2(1400.0, 400.0), size, &displays);
        assert_eq!(a, pos2(1340.0, 400.0));
        // 完全不在任何螢幕：移到最近的螢幕
        let b = clamp_anchor(pos2(9000.0, 300.0), size, &displays);
        assert_eq!(b, pos2(3360.0 - 100.0, 300.0));
        // 沒有螢幕資訊：原樣
        assert_eq!(clamp_anchor(pos2(5.0, 5.0), size, &[]), pos2(5.0, 5.0));
    }

    #[test]
    fn tap_actions_follow_native() {
        assert!(matches!(tap_action(&PipelineState::Idle, false), Some(OverlayAction::NotAllowed)));
        assert!(matches!(
            tap_action(&PipelineState::Idle, true),
            Some(OverlayAction::Pipeline(PipelineCommand::StartListening))
        ));
        assert!(matches!(
            tap_action(&PipelineState::Recording, false),
            Some(OverlayAction::RefocusThen(PipelineCommand::StopRecording))
        ));
        assert!(tap_action(&PipelineState::Processing, true).is_none());
    }
}

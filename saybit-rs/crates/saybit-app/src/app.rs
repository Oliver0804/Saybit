//! App 狀態與 eframe 進入點（批次 A1）。
//!
//! 執行緒模型：全部 GUI 狀態在主執行緒。其他執行緒（系統匣 / 快捷鍵事件、saybit:// 單一實例、
//! 注入要求的主執行緒閉包）都經 `post(AppMsg)` 丟進佇列並 `request_repaint`；
//! 主視窗隱藏時 eframe 仍會呼叫 `App::logic`，所以佇列一律在 `logic` 消化。
//! 膠囊是 deferred viewport，root 的 `ui` 在膠囊可見時仍會跑（eframe：子 viewport 可見即可）。

use crate::hotkeys::{HotkeyAction, HotkeyRecorder, HotkeyService, TriggerAction};
use crate::onboarding::{Onboarding, OnboardingOutcome};
use crate::overlay::{self, OverlayAction, OverlayShared};
use crate::tray::{Tray, TrayAction, TrayModel};
use crate::ui::l10n::{set_language, t};
use crate::ui::SettingsTab;
use crossbeam_channel::{Receiver, Sender};
use egui::{ViewportCommand, ViewportId};
use saybit_core::*;
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

// ───────────────────────────── 跨執行緒訊息 ─────────────────────────────

pub enum AppMsg {
    Url(String),
    Menu(String),
    Hotkey(global_hotkey::GlobalHotKeyEvent),
    /// inject 要求在主執行緒執行（macOS enigo）
    MainThread(Box<dyn FnOnce() + Send>),
}

fn bus() -> &'static (Sender<AppMsg>, Receiver<AppMsg>) {
    static BUS: OnceLock<(Sender<AppMsg>, Receiver<AppMsg>)> = OnceLock::new();
    BUS.get_or_init(crossbeam_channel::unbounded)
}

static CTX: OnceLock<egui::Context> = OnceLock::new();

/// 任何執行緒都可呼叫：丟訊息並叫醒 GUI（eframe 啟動前丟的會在第一幀處理）
pub fn post(msg: AppMsg) {
    let _ = bus().0.send(msg);
    if let Some(ctx) = CTX.get() {
        ctx.request_repaint();
    }
}

/// (初始大小, 最小大小)
pub fn root_size(onboarding: bool) -> (egui::Vec2, egui::Vec2) {
    if onboarding {
        (egui::vec2(600.0, 640.0), egui::vec2(560.0, 560.0))
    } else {
        (egui::vec2(1000.0, 720.0), egui::vec2(900.0, 600.0))
    }
}

// ───────────────────────────── saybit:// 路由（純邏輯）─────────────────────────────

#[derive(Debug, Clone, PartialEq)]
pub enum UrlRoute {
    OpenSettings(Option<SettingsTab>),
    Ignore(&'static str),
    Ask(UrlCommand),
    Run(UrlCommand),
}

pub fn route_url(cmd: UrlCommand, decision: UrlSchemeDecision, recording_allowed: bool) -> UrlRoute {
    if cmd.command == "settings" {
        return UrlRoute::OpenSettings(cmd.tab.as_deref().and_then(SettingsTab::from_slug));
    }
    if !recording_allowed {
        return UrlRoute::Ignore("引導尚未完成");
    }
    match decision {
        UrlSchemeDecision::Deny => UrlRoute::Ignore("使用者已拒絕外部控制"),
        UrlSchemeDecision::Ask => UrlRoute::Ask(cmd),
        UrlSchemeDecision::Allow => UrlRoute::Run(cmd),
    }
}

/// URL 指令 → pipeline 命令（start / stop 依目前是否在錄音）
pub fn url_to_command(cmd: &UrlCommand, mode: Option<VoiceMode>, recording: bool) -> Option<PipelineCommand> {
    match cmd.command.as_str() {
        "toggle" | "dictate" => Some(PipelineCommand::ToggleRecording { mode }),
        "start" if !recording => Some(PipelineCommand::ToggleRecording { mode }),
        "stop" if recording => Some(PipelineCommand::StopRecording),
        "cancel" => Some(PipelineCommand::CancelRecording),
        _ => None,
    }
}

pub fn find_mode(settings: &Settings, name_or_id: &str) -> Option<VoiceMode> {
    settings
        .voice_modes
        .iter()
        .find(|m| m.id == name_or_id || m.name.eq_ignore_ascii_case(name_or_id))
        .cloned()
}

// ───────────────────────────── 狀態 ─────────────────────────────

pub struct AppState {
    pub settings: Settings,
    pub pipeline: Option<PipelineHandle>,
    pub ui: crate::ui::UiState,
    /// 主視窗（設定）是否顯示
    pub show_settings: bool,
    /// A2 改了 `settings` 後設 true：A1 存檔、廣播 SettingsChanged、重新註冊快捷鍵、切語言
    pub settings_dirty: bool,
    /// A2 改了 API key 後設 true：A1 送 SecretsChanged、重新檢查系統匣的「缺 API Key」
    pub secrets_dirty: bool,
    /// 快捷鍵錄製器（錄製中 A1 會暫停全域快捷鍵）
    #[allow(dead_code)]
    pub hotkey_recorder: HotkeyRecorder,
    /// 要顯示在膠囊下方的訊息（A2 也可 push；A1 每幀取出）
    pub pending_toasts: Vec<String>,
}

impl AppState {
    pub fn toast(&mut self, text: impl Into<String>) {
        self.pending_toasts.push(text.into());
    }
}

struct UrlPrompt {
    cmd: UrlCommand,
    /// 詢問前主視窗是隱藏的 → 回答後再藏回去
    rehide: bool,
}

pub struct SaybitApp {
    pub state: AppState,
    smoke: bool,
    started: Instant,
    frame_no: u64,
    hotkeys: Option<HotkeyService>,
    tray: Option<Tray>,
    overlay: overlay::Shared,
    overlay_wanted: bool,
    overlay_drawn_last_ui: bool,
    onboarding: Option<Onboarding>,
    /// 最後一次套用（存檔／廣播）的設定
    applied: Settings,
    pending_change_since: Option<Instant>,
    root_visible: bool,
    allow_close: bool,
    url_prompt: Option<UrlPrompt>,
    api_key_missing: bool,
    accessibility_missing: bool,
    last_ax_check: Option<Instant>,
    last_level_push: Instant,
    last_generation: u64,
    smoke_state: Option<SmokeState>,
    /// 上一幀的 has_completed_onboarding（設定頁「重新查看教學」把它改成 false 時重新顯示引導）
    prev_onboarding_done: bool,
}

impl SaybitApp {
    pub fn new(cc: &eframe::CreationContext<'_>, settings: Settings, smoke: bool) -> Self {
        let ctx = cc.egui_ctx.clone();
        let _ = CTX.set(ctx.clone());
        crate::theme::apply(&ctx);
        crate::fonts::install(&ctx);
        set_language(settings.app_language);

        let displays = overlay::displays();
        let anchor = settings
            .overlay_position
            .map(|(x, y)| overlay::clamp_anchor(egui::pos2(x, y), egui::vec2(160.0, 60.0), &displays))
            .unwrap_or_else(|| overlay::default_anchor(&displays));
        let overlay = OverlayShared::new(anchor, displays);

        let show_onboarding = !settings.has_completed_onboarding;
        let mut app = Self {
            state: AppState {
                settings: settings.clone(),
                pipeline: None,
                ui: crate::ui::UiState::default(),
                show_settings: show_onboarding,
                settings_dirty: false,
                secrets_dirty: false,
                hotkey_recorder: HotkeyRecorder::default(),
                pending_toasts: Vec::new(),
            },
            smoke,
            started: Instant::now(),
            frame_no: 0,
            hotkeys: None,
            tray: None,
            overlay,
            overlay_wanted: true,
            overlay_drawn_last_ui: false,
            onboarding: show_onboarding.then(|| Onboarding::new(&settings, smoke)),
            applied: settings.clone(),
            pending_change_since: None,
            root_visible: true,
            allow_close: false,
            url_prompt: None,
            api_key_missing: false,
            accessibility_missing: false,
            last_ax_check: None,
            last_level_push: Instant::now(),
            last_generation: u64::MAX,
            smoke_state: smoke.then(SmokeState::new),
            prev_onboarding_done: settings.has_completed_onboarding,
        };
        app.sync_overlay_settings();

        if smoke {
            crate::applog::info("App", "smoke 模式：不建系統匣／快捷鍵／pipeline，30 秒後結束".into());
            return app;
        }

        // 主執行緒閉包佇列（macOS 的 enigo 必須在主執行緒）
        saybit_core::inject::set_main_thread_runner(Box::new(|f| post(AppMsg::MainThread(f))));
        platform::start_tracking_external_app();

        let repaint_ctx = ctx.clone();
        let repaint: RepaintFn = Arc::new(move || repaint_ctx.request_repaint());
        match pipeline::spawn(pipeline::PipelineDeps { settings: settings.clone(), repaint }) {
            Ok(h) => app.state.pipeline = Some(h),
            Err(e) => {
                crate::applog::error("App", format!("pipeline 啟動失敗：{e}"));
                app.state.toast(format!("pipeline: {e}"));
            }
        }

        tray_icon::menu::MenuEvent::set_event_handler(Some(|e: tray_icon::menu::MenuEvent| post(AppMsg::Menu(e.id.0))));
        global_hotkey::GlobalHotKeyEvent::set_event_handler(Some(|e| post(AppMsg::Hotkey(e))));

        let mut hk = HotkeyService::new();
        for m in hk.register(&app.state.settings) {
            app.state.toast(m);
        }
        app.hotkeys = Some(hk);

        app.refresh_api_key_status();
        app.refresh_accessibility(true);
        app.tray = Tray::new(&app.tray_model());
        app
    }

    fn recording_allowed(&self) -> bool {
        self.onboarding.is_none()
    }

    fn snapshot(&self) -> PipelineSnapshot {
        self.state.pipeline.as_ref().map(|p| p.snapshot()).unwrap_or_default()
    }

    fn is_recording(&self) -> bool {
        matches!(self.snapshot().state, PipelineState::Recording)
    }

    fn send(&self, cmd: PipelineCommand) {
        if let Some(p) = &self.state.pipeline {
            p.send(cmd);
        }
    }

    /// 會注入文字的命令：Saybit 在前景時先把焦點還給外部 App（等 250 ms），在背景執行緒做免得卡 UI
    fn send_after_refocus(&self, cmd: PipelineCommand) {
        let Some(p) = self.state.pipeline.clone() else { return };
        if cfg!(target_os = "macos") {
            std::thread::spawn(move || {
                platform::refocus_last_external_if_self_front();
                p.send(cmd);
            });
        } else {
            p.send(cmd);
        }
    }

    /// 開始類命令要擋引導未完成；停止類永遠放行
    fn start_or_stop(&mut self, cmd: PipelineCommand) {
        let starting = matches!(cmd, PipelineCommand::ToggleRecording { .. } | PipelineCommand::StartRecording { .. })
            && !self.is_recording();
        if starting && !self.recording_allowed() {
            crate::applog::info("App", "引導尚未完成，忽略開始錄音".into());
            self.show_toast(t("onboarding.notDone"));
            return;
        }
        self.send(cmd);
    }

    fn show_toast(&mut self, text: String) {
        self.overlay.lock().toast = Some((text, Instant::now()));
        if let Some(ctx) = CTX.get() {
            ctx.request_repaint_of(overlay::overlay_id());
            ctx.request_repaint_after(overlay::TOAST_DURATION + Duration::from_millis(50));
        }
    }

    // ── 主視窗 ──

    fn open_settings(&mut self, ctx: &egui::Context, tab: Option<SettingsTab>) {
        if let Some(tab) = tab {
            self.state.ui.selected_tab = tab;
        }
        self.state.show_settings = true;
        self.apply_root_visibility(ctx, true);
    }

    fn apply_root_visibility(&mut self, ctx: &egui::Context, focus: bool) {
        let want = self.state.show_settings;
        if want != self.root_visible {
            self.root_visible = want;
            ctx.send_viewport_cmd_to(ViewportId::ROOT, ViewportCommand::Visible(want));
            if !want {
                self.state.ui.on_settings_closed();
            }
        }
        if want && focus {
            ctx.send_viewport_cmd_to(ViewportId::ROOT, ViewportCommand::Focus);
        }
    }

    fn quit(&mut self, ctx: &egui::Context) {
        crate::applog::info("App", "結束 Saybit".into());
        self.send(PipelineCommand::Shutdown);
        if let Some(h) = &mut self.hotkeys {
            h.unregister_all();
        }
        self.allow_close = true;
        ctx.send_viewport_cmd_to(ViewportId::ROOT, ViewportCommand::Close);
    }

    // ── 設定變更 ──

    fn apply_settings_if_changed(&mut self, now: Instant) {
        let changed = self.state.settings != self.applied;
        let explicit = std::mem::take(&mut self.state.settings_dirty);
        if !changed {
            self.pending_change_since = None;
            return;
        }
        // 打字中的欄位每個鍵都會改設定：沒標 dirty 的變更等 400 ms 穩定再套用
        if !explicit {
            let since = *self.pending_change_since.get_or_insert(now);
            if now.duration_since(since) < Duration::from_millis(400) {
                if let Some(ctx) = CTX.get() {
                    ctx.request_repaint_after(Duration::from_millis(420));
                }
                return;
            }
        }
        self.pending_change_since = None;
        let old = std::mem::replace(&mut self.applied, self.state.settings.clone());
        let new = self.applied.clone();
        let new = &new;
        if !self.smoke {
            if let Err(e) = settings::save(new) {
                crate::applog::error("Settings", format!("設定存檔失敗：{e}"));
            }
        }
        self.send(PipelineCommand::SettingsChanged(Arc::new(new.clone())));
        if old.app_language != new.app_language {
            set_language(new.app_language);
        }
        let hotkeys_changed = old.hotkey != new.hotkey
            || old.hotkey_trigger_mode != new.hotkey_trigger_mode
            || old.voice_modes.iter().map(|m| (&m.id, &m.hotkey)).ne(new.voice_modes.iter().map(|m| (&m.id, &m.hotkey)));
        if hotkeys_changed && !crate::hotkeys::recorder_active() {
            let settings = new.clone();
            if let Some(h) = &mut self.hotkeys {
                for m in h.register(&settings) {
                    self.show_toast(m);
                }
            }
        }
        if old.selected_provider_id != new.selected_provider_id || old.custom_providers != new.custom_providers {
            self.refresh_api_key_status();
        }
        if old.launch_at_login != new.launch_at_login && !self.smoke {
            if let Err(e) = platform::set_launch_at_login(new.launch_at_login) {
                crate::applog::error("Settings", format!("開機啟動設定失敗：{e}"));
            }
        }
        self.sync_overlay_settings();
    }

    fn sync_overlay_settings(&mut self) {
        let mut o = self.overlay.lock();
        o.scale = self.applied.capsule_scale;
        o.smart_send = self.applied.enable_smart_send;
        o.recording_allowed = self.onboarding.is_none();
        o.supports_actions = !self.smoke && platform::supports_actions();
    }

    fn refresh_api_key_status(&mut self) {
        if self.smoke {
            return;
        }
        let s = &self.state.settings;
        self.api_key_missing = match llm::providers::find(s, &s.selected_provider_id) {
            Some(p) if p.requires_api_key => {
                secure_store::get(&secure_store::llm_account(&p.id)).is_none_or(|k| k.trim().is_empty())
            }
            _ => false,
        };
    }

    fn refresh_accessibility(&mut self, force: bool) {
        if self.smoke || (!force && self.last_ax_check.is_some_and(|t| t.elapsed() < Duration::from_secs(5))) {
            return;
        }
        self.last_ax_check = Some(Instant::now());
        self.accessibility_missing = platform::accessibility_trusted() == Some(false);
    }

    fn tray_model(&self) -> TrayModel {
        let s = &self.applied;
        TrayModel {
            recording: self.is_recording(),
            recording_allowed: self.recording_allowed(),
            hotkey_label: crate::hotkeys::display_label(&s.hotkey),
            modes: s
                .voice_modes
                .iter()
                .map(|m| {
                    let label = match m.hotkey.as_deref().filter(|h| !h.is_empty()) {
                        Some(h) => format!("{}（{}）", m.name, crate::hotkeys::display_label(h)),
                        None => m.name.clone(),
                    };
                    (m.id.clone(), label)
                })
                .collect(),
            prompt_style: s.prompt_style,
            tone: s.tone_style,
            smart_send: s.enable_smart_send,
            whisper_mode: s.enable_whisper_mode,
            api_key_missing: self.api_key_missing,
            accessibility_missing: self.accessibility_missing,
            update_tag: (!s.available_update_tag.is_empty() && !s.available_update_url.is_empty())
                .then(|| s.available_update_tag.clone()),
            language: s.app_language,
        }
    }

    // ── 事件處理 ──

    fn drain_bus(&mut self, ctx: &egui::Context) {
        while let Ok(msg) = bus().1.try_recv() {
            match msg {
                AppMsg::MainThread(f) => f(),
                AppMsg::Url(url) => self.handle_url(ctx, url),
                AppMsg::Menu(id) => match crate::tray::parse_menu_id(&id) {
                    Some(a) => self.handle_tray(ctx, a),
                    None => crate::applog::warn("Tray", format!("未知的選單項目：{id}")),
                },
                AppMsg::Hotkey(e) => {
                    if crate::hotkeys::recorder_active() {
                        continue;
                    }
                    let action = self.hotkeys.as_mut().and_then(|h| h.handle(e, Instant::now()));
                    if let Some(a) = action {
                        self.handle_hotkey(a);
                    }
                }
            }
        }
    }

    fn handle_hotkey(&mut self, action: HotkeyAction) {
        match action {
            HotkeyAction::Main(TriggerAction::Toggle) => self.start_or_stop(PipelineCommand::ToggleRecording { mode: None }),
            HotkeyAction::Main(TriggerAction::Start) => {
                self.start_or_stop(PipelineCommand::StartRecording { mode: None, expected_target: None })
            }
            HotkeyAction::Main(TriggerAction::Stop) => self.send(PipelineCommand::StopRecording),
            HotkeyAction::Mode(id) => {
                let mode = find_mode(&self.applied, &id);
                if mode.is_none() {
                    crate::applog::warn("HotKey", format!("找不到語音模式：{id}"));
                }
                self.start_or_stop(PipelineCommand::ToggleRecording { mode });
            }
        }
    }

    fn handle_tray(&mut self, ctx: &egui::Context, action: TrayAction) {
        match action {
            TrayAction::ToggleRecording => {
                if self.is_recording() {
                    self.send_after_refocus(PipelineCommand::StopRecording);
                } else {
                    self.start_or_stop(PipelineCommand::ToggleRecording { mode: None });
                }
            }
            TrayAction::RecordWithMode(id) => {
                let mode = find_mode(&self.applied, &id);
                self.start_or_stop(PipelineCommand::ToggleRecording { mode });
            }
            TrayAction::SetPromptStyle(s) => {
                self.state.settings.prompt_style = s;
                self.state.settings_dirty = true;
            }
            TrayAction::SetTone(s) => {
                self.state.settings.tone_style = s;
                self.state.settings_dirty = true;
            }
            TrayAction::ToggleSmartSend => {
                self.state.settings.enable_smart_send = !self.state.settings.enable_smart_send;
                self.state.settings_dirty = true;
            }
            TrayAction::ToggleWhisperMode => {
                self.state.settings.enable_whisper_mode = !self.state.settings.enable_whisper_mode;
                self.state.settings_dirty = true;
            }
            TrayAction::OpenApiSettings => self.open_settings(ctx, Some(SettingsTab::Ai)),
            TrayAction::RequestAccessibility => {
                platform::request_accessibility();
                platform::open_privacy_settings("Privacy_Accessibility");
            }
            TrayAction::OpenUpdate => platform::open_url(&self.applied.available_update_url),
            TrayAction::OpenTab(tab) => self.open_settings(ctx, Some(tab)),
            TrayAction::ReregisterHotkey => {
                let settings = self.applied.clone();
                let mut msgs = Vec::new();
                if let Some(h) = &mut self.hotkeys {
                    msgs = h.register(&settings);
                }
                if msgs.is_empty() {
                    msgs.push(t("hotkey.reregistered"));
                }
                for m in msgs {
                    self.show_toast(m);
                }
            }
            TrayAction::ResetOverlay => self.reset_overlay_position(),
            TrayAction::Quit => self.quit(ctx),
        }
    }

    fn reset_overlay_position(&mut self) {
        let displays = overlay::displays();
        {
            let mut o = self.overlay.lock();
            o.anchor = overlay::default_anchor(&displays);
            o.displays = displays;
        }
        self.state.settings.overlay_position = None;
        self.state.settings_dirty = true;
        self.overlay_wanted = true;
        if let Some(ctx) = CTX.get() {
            ctx.request_repaint_of(overlay::overlay_id());
        }
    }

    fn handle_url(&mut self, ctx: &egui::Context, raw: String) {
        if !deeplink::accept_url(&raw) {
            crate::applog::info("URL", format!("1 秒內重複，丟棄：{raw}"));
            return;
        }
        let Some(cmd) = deeplink::parse(&raw) else {
            crate::applog::warn("URL", format!("無法解析：{raw}"));
            return;
        };
        crate::applog::info("URL", format!("saybit://{}{}", cmd.command, cmd.mode.as_deref().map(|m| format!(" mode={m}")).unwrap_or_default()));
        match route_url(cmd, self.applied.url_scheme_decision, self.recording_allowed()) {
            UrlRoute::OpenSettings(tab) => self.open_settings(ctx, tab),
            UrlRoute::Ignore(why) => crate::applog::info("URL", format!("忽略：{why}")),
            UrlRoute::Ask(cmd) => {
                if self.url_prompt.is_some() {
                    crate::applog::info("URL", "正在詢問中，丟棄新的指令".into());
                    return;
                }
                let rehide = !self.state.show_settings;
                self.url_prompt = Some(UrlPrompt { cmd, rehide });
                self.state.show_settings = true;
                self.apply_root_visibility(ctx, true);
            }
            UrlRoute::Run(cmd) => self.run_url(cmd),
        }
    }

    fn run_url(&mut self, cmd: UrlCommand) {
        let mode = cmd.mode.as_deref().and_then(|m| {
            let found = find_mode(&self.applied, m);
            if found.is_none() {
                crate::applog::error("URL", format!("找不到語音模式：{m}"));
            }
            found
        });
        let Some(command) = url_to_command(&cmd, mode, self.is_recording()) else { return };
        // 開 URL（或詢問視窗）會把 Saybit 帶到前景：先把焦點還給原本的 App 再送
        self.send_after_refocus(command);
    }

    fn handle_pipeline_events(&mut self) {
        let Some(p) = self.state.pipeline.clone() else { return };
        let mut snapshot_changed = false;
        while let Ok(ev) = p.events.try_recv() {
            match ev {
                PipelineEvent::SnapshotChanged => snapshot_changed = true,
                PipelineEvent::Toast { text } => self.show_toast(text),
                PipelineEvent::OverlayVisibility(v) => self.overlay_wanted = v,
                PipelineEvent::RecordingStarted | PipelineEvent::RecordingStopped | PipelineEvent::Injected => {
                    snapshot_changed = true
                }
                PipelineEvent::Progress { .. } => {}
            }
        }
        if snapshot_changed {
            self.update_overlay_snapshot(p.snapshot());
        }
    }

    fn update_overlay_snapshot(&mut self, snap: PipelineSnapshot) {
        let now = Instant::now();
        let mut o = self.overlay.lock();
        let live = matches!(snap.state, PipelineState::Recording | PipelineState::Listening);
        if live && now.duration_since(self.last_level_push) >= Duration::from_millis(50) {
            o.push_level(snap.audio_level);
            self.last_level_push = now;
        }
        if snap.generation != self.last_generation && !live {
            o.levels.iter_mut().for_each(|l| *l = 0.0);
        }
        self.last_generation = snap.generation;
        o.snapshot = snap;
        drop(o);
        if let Some(ctx) = CTX.get() {
            ctx.request_repaint_of(overlay::overlay_id());
        }
    }

    fn handle_overlay_actions(&mut self, ctx: &egui::Context) {
        let actions = std::mem::take(&mut self.overlay.lock().outbox);
        for a in actions {
            match a {
                OverlayAction::Pipeline(cmd) => self.start_or_stop(cmd),
                OverlayAction::RefocusThen(cmd) => self.send_after_refocus(cmd),
                OverlayAction::ToggleSmartSend => {
                    self.state.settings.enable_smart_send = !self.state.settings.enable_smart_send;
                    self.state.settings_dirty = true;
                }
                OverlayAction::ResetPosition => self.reset_overlay_position(),
                OverlayAction::OpenSettings => self.open_settings(ctx, None),
                OverlayAction::Quit => self.quit(ctx),
                OverlayAction::SavePosition(p) => {
                    self.state.settings.overlay_position = Some((p.x, p.y));
                    self.state.settings_dirty = true;
                }
                OverlayAction::NotAllowed => self.show_toast(t("onboarding.notDone")),
            }
        }
    }

    fn handle_onboarding_outcomes(&mut self, ctx: &egui::Context, outcomes: Vec<OnboardingOutcome>) {
        for o in outcomes {
            match o {
                OnboardingOutcome::SettingsChanged => self.state.settings_dirty = true,
                OnboardingOutcome::SecretsChanged => self.state.secrets_dirty = true,
                OnboardingOutcome::Finished => {
                    self.onboarding = None;
                    self.sync_overlay_settings();
                    let (size, min) = root_size(false);
                    ctx.send_viewport_cmd_to(ViewportId::ROOT, ViewportCommand::MinInnerSize(min));
                    ctx.send_viewport_cmd_to(ViewportId::ROOT, ViewportCommand::InnerSize(size));
                    ctx.send_viewport_cmd_to(ViewportId::ROOT, ViewportCommand::Title(t("menu.settingsWindowTitle")));
                    self.state.show_settings = false;
                    self.apply_root_visibility(ctx, false);
                }
            }
        }
    }

    fn url_prompt_ui(&mut self, ctx: &egui::Context) {
        let Some(prompt) = &self.url_prompt else { return };
        let label = match &prompt.cmd.mode {
            Some(m) => format!("{} · {m}", prompt.cmd.command),
            None => prompt.cmd.command.clone(),
        };
        let mut choice: Option<(bool, Option<UrlSchemeDecision>)> = None;
        egui::Modal::new(egui::Id::unique("saybit-url-prompt")).show(ctx, |ui| {
            ui.set_max_width(420.0);
            ui.heading(t("url.askTitle"));
            ui.add_space(6.0);
            ui.label(crate::ui::l10n::tf("url.askBody", &[("command", &label)]));
            ui.add_space(10.0);
            ui.horizontal(|ui| {
                if ui.button(t("url.allowRemember")).clicked() {
                    choice = Some((true, Some(UrlSchemeDecision::Allow)));
                }
                if ui.button(t("url.allowOnce")).clicked() {
                    choice = Some((true, None));
                }
                // 預設（最顯眼）的是拒絕
                if ui.add(crate::theme::primary_button(t("url.denyRemember"))).clicked() {
                    choice = Some((false, Some(UrlSchemeDecision::Deny)));
                }
            });
        });
        let Some((allow, remember)) = choice else { return };
        let Some(prompt) = self.url_prompt.take() else { return };
        if let Some(d) = remember {
            self.state.settings.url_scheme_decision = d;
            self.state.settings_dirty = true;
        }
        crate::applog::info("URL", format!("使用者{}外部控制（記住：{}）", if allow { "允許" } else { "拒絕" }, remember.is_some()));
        if prompt.rehide && self.onboarding.is_none() {
            self.state.show_settings = false;
            self.apply_root_visibility(ctx, false);
        }
        if allow {
            self.run_url(prompt.cmd);
        }
    }

    /// 設定頁把 has_completed_onboarding 由 true 改成 false：立即顯示引導
    fn reopen_onboarding_if_reset(&mut self, ctx: &egui::Context) {
        let done = self.state.settings.has_completed_onboarding;
        if self.prev_onboarding_done && !done && self.onboarding.is_none() {
            crate::applog::info("App", "重新顯示設定引導".into());
            self.onboarding = Some(Onboarding::new(&self.state.settings, self.smoke));
            self.sync_overlay_settings();
            let (size, min) = root_size(true);
            ctx.send_viewport_cmd_to(ViewportId::ROOT, ViewportCommand::MinInnerSize(min));
            ctx.send_viewport_cmd_to(ViewportId::ROOT, ViewportCommand::InnerSize(size));
            ctx.send_viewport_cmd_to(ViewportId::ROOT, ViewportCommand::Title(t("onb.windowTitle")));
            self.state.settings_dirty = true;
            self.state.show_settings = true;
            self.apply_root_visibility(ctx, true);
        }
        self.prev_onboarding_done = done;
    }

    fn want_overlay(&self) -> bool {
        self.overlay_wanted || self.overlay.lock().toast_active()
    }
}

impl eframe::App for SaybitApp {
    fn logic(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        let now = Instant::now();
        self.drain_bus(ctx);

        // 主視窗關閉＝隱藏（結束走系統匣）
        if ctx.input(|i| i.viewport().close_requested()) && !self.allow_close {
            ctx.send_viewport_cmd(ViewportCommand::CancelClose);
            if self.onboarding.is_none() {
                self.state.show_settings = false;
                self.apply_root_visibility(ctx, false);
            } else {
                // 引導視窗關掉：這次先不引導（允許錄音），下次啟動再顯示
                self.onboarding = None;
                self.sync_overlay_settings();
                self.state.show_settings = false;
                self.apply_root_visibility(ctx, false);
            }
        }

        if let Some(h) = &mut self.hotkeys {
            for m in h.sync_pause(&self.applied) {
                self.state.pending_toasts.push(m);
            }
            let tick = h.tick(now);
            if h.needs_tick() {
                ctx.request_repaint_after(Duration::from_millis(20));
            }
            if let Some(a) = tick {
                self.handle_hotkey(a);
            }
        }

        self.handle_pipeline_events();
        if self.state.pipeline.is_some() {
            // 錄音中持續取音量（pipeline 也會叫醒，這裡保底）
            let snap = self.snapshot();
            if matches!(snap.state, PipelineState::Recording | PipelineState::Listening) {
                self.update_overlay_snapshot(snap);
                ctx.request_repaint_after(Duration::from_millis(50));
            }
        }
        self.handle_overlay_actions(ctx);

        if std::mem::take(&mut self.state.secrets_dirty) {
            self.send(PipelineCommand::SecretsChanged);
            self.refresh_api_key_status();
        }
        self.reopen_onboarding_if_reset(ctx);
        self.apply_settings_if_changed(now);
        for text in std::mem::take(&mut self.state.pending_toasts) {
            self.show_toast(text);
        }

        if self.tray.is_some() {
            self.refresh_accessibility(false);
            let model = self.tray_model();
            if let Some(tray) = &mut self.tray {
                tray.update(&model);
            }
            // 輔助使用權限每 5 秒重新檢查
            ctx.request_repaint_after(Duration::from_secs(5));
        }

        if let Some(s) = &mut self.smoke_state {
            s.tick(ctx, &self.overlay, self.onboarding.as_mut(), self.started);
            if self.started.elapsed() >= SMOKE_DURATION {
                self.allow_close = true;
                ctx.send_viewport_cmd_to(ViewportId::ROOT, ViewportCommand::Close);
            }
        }

        // 主視窗隱藏、膠囊又還沒畫出來：要求 eframe 跑一次 ui，膠囊才會被建立
        if self.want_overlay() && !self.overlay_drawn_last_ui && !self.root_visible {
            ctx.send_viewport_cmd_to(ViewportId::ROOT, ViewportCommand::RequestPaintWhileHidden);
        }
    }

    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        self.frame_no += 1;
        // eframe 第一幀畫完會強制顯示 root；不該顯示時立刻藏起來
        if self.frame_no <= 3 && !self.state.show_settings {
            ctx.send_viewport_cmd_to(ViewportId::ROOT, ViewportCommand::Visible(false));
            self.root_visible = false;
        }

        if self.root_visible {
            ui.painter().rect_filled(ui.max_rect(), 0.0, crate::theme::PANEL);
            if let Some(onb) = &mut self.onboarding {
                let outcomes = onb.ui(ui, &mut self.state.settings);
                if !outcomes.is_empty() {
                    self.handle_onboarding_outcomes(&ctx, outcomes);
                }
            } else {
                crate::ui::settings_panel(ui, &mut self.state);
            }
            self.url_prompt_ui(&ctx);
        }

        let want = self.want_overlay();
        if want {
            overlay::show(&ctx, &self.overlay);
        }
        self.overlay_drawn_last_ui = want;
    }

    fn clear_color(&self, _visuals: &egui::Visuals) -> [f32; 4] {
        // 膠囊視窗要透明；root 自己畫底色
        [0.0, 0.0, 0.0, 0.0]
    }

    fn on_exit(&mut self) {
        self.send(PipelineCommand::Shutdown);
    }
}

// ───────────────────────────── smoke 模式 ─────────────────────────────

const SMOKE_DURATION: Duration = Duration::from_secs(30);

/// 輪流展示膠囊各狀態與引導各步，並（若有 SAYBIT_SMOKE_SHOTS）截圖
struct SmokeState {
    shots_dir: Option<std::path::PathBuf>,
    last_slot: Option<usize>,
    shot_taken: bool,
}

impl SmokeState {
    fn new() -> Self {
        let shots_dir = std::env::var_os("SAYBIT_SMOKE_SHOTS").map(std::path::PathBuf::from);
        if let Some(d) = &shots_dir {
            let _ = std::fs::create_dir_all(d);
        }
        Self { shots_dir, last_slot: None, shot_taken: false }
    }

    fn fake(slot: usize, t: f32) -> (PipelineSnapshot, Option<&'static str>) {
        let mut s = PipelineSnapshot { generation: slot as u64, ..Default::default() };
        let text = "明天下午三點跟設計團隊開會，討論新版首頁的配色與字型，記得帶上週的使用者訪談紀錄。";
        let mut toast = None;
        match slot % 11 {
            0 => s.state = PipelineState::Idle,
            1 => s.state = PipelineState::Listening,
            2 => {
                s.state = PipelineState::Recording;
                s.recording_started_at = Some(Instant::now() - Duration::from_secs(5));
                s.raw_transcript = "明天下午三點跟設計團隊開會".into();
            }
            3 => {
                s.state = PipelineState::Recording;
                s.mode_name = Some("Email".into());
                s.recording_started_at = Some(Instant::now() - Duration::from_secs(72));
            }
            4 => {
                s.state = PipelineState::Processing;
                s.mode_name = Some("翻譯成英文".into());
            }
            5 => {
                s.state = PipelineState::Done;
                s.processed_text = text.into();
                s.usage = TokenUsage { prompt_tokens: 812, completion_tokens: 64, total_tokens: 876 };
                s.cost_usd = Some(0.00021);
            }
            6 => {
                s.state = PipelineState::Confirming { remaining_secs: 3.0 - (t % 3.0) };
                s.processed_text = "好的，我晚點回覆你".into();
            }
            7 => {
                s.state = PipelineState::Previewing;
                s.processed_text = text.into();
            }
            8 => {
                s.state = PipelineState::Previewing;
                s.pending_action = Some(PendingAction::CalendarEvent {
                    title: "設計團隊會議".into(),
                    start: "明天 15:00".into(),
                    end: None,
                    notes: None,
                });
            }
            9 => {
                s.state = PipelineState::Error("HTTP 401：服務商拒絕這把 API Key，請到設定確認".into());
                s.can_retry = true;
            }
            _ => {
                s.state = PipelineState::Idle;
                toast = Some("快捷鍵 ⌃ ⌥ Space 註冊失敗（可能已被其他 App 使用）");
            }
        }
        (s, toast)
    }

    fn tick(&mut self, ctx: &egui::Context, overlay: &overlay::Shared, onboarding: Option<&mut Onboarding>, started: Instant) {
        let t = started.elapsed().as_secs_f32();
        let slot = (t / 2.5) as usize;
        let (snap, toast) = Self::fake(slot, t);
        {
            let mut o = overlay.lock();
            if matches!(snap.state, PipelineState::Recording | PipelineState::Listening) {
                o.push_level((0.5 + 0.45 * (t * 9.0).sin() * (t * 2.3).cos()).abs());
            }
            o.snapshot = snap;
            if self.last_slot != Some(slot) {
                if let Some(text) = toast {
                    o.toast = Some((text.to_string(), Instant::now()));
                }
            }
        }
        if self.last_slot != Some(slot) {
            self.last_slot = Some(slot);
            self.shot_taken = false;
            if let Some(o) = onboarding {
                o.set_step_index(slot / 2 % 5);
            }
        }
        // 每個狀態顯示 1.2 秒後截圖（等視窗尺寸穩定）
        if !self.shot_taken && t - slot as f32 * 2.5 > 1.2 {
            self.shot_taken = true;
            if let Some(dir) = &self.shots_dir {
                for (vp, name) in [(overlay::overlay_id(), "overlay"), (ViewportId::ROOT, "root")] {
                    if name == "root" && slot % 2 == 1 {
                        continue;
                    }
                    let path = dir.join(format!("{slot:02}-{name}.png"));
                    ctx.send_viewport_cmd_to(
                        vp,
                        ViewportCommand::Screenshot(egui::ScreenshotCallback::new(move |img| save_png(&img, &path))),
                    );
                }
            }
        }
        ctx.request_repaint_of(overlay::overlay_id());
        ctx.request_repaint_after(Duration::from_millis(100));
    }
}

fn save_png(img: &egui::ColorImage, path: &std::path::Path) {
    let [w, h] = img.size;
    let mut buf = Vec::with_capacity(w * h * 4);
    for c in &img.pixels {
        buf.extend_from_slice(&c.to_srgba_unmultiplied());
    }
    match image::RgbaImage::from_raw(w as u32, h as u32, buf).map(|i| i.save(path)) {
        Some(Ok(())) => eprintln!("[smoke] 截圖 {}", path.display()),
        other => eprintln!("[smoke] 截圖失敗 {}: {other:?}", path.display()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cmd(c: &str) -> UrlCommand {
        UrlCommand { command: c.into(), mode: None, tab: None }
    }

    #[test]
    fn settings_url_always_opens_settings() {
        let mut c = cmd("settings");
        c.tab = Some("logs".into());
        assert_eq!(route_url(c, UrlSchemeDecision::Deny, false), UrlRoute::OpenSettings(Some(SettingsTab::Logs)));
        assert_eq!(route_url(cmd("settings"), UrlSchemeDecision::Ask, true), UrlRoute::OpenSettings(None));
    }

    #[test]
    fn control_urls_follow_decision() {
        assert!(matches!(route_url(cmd("toggle"), UrlSchemeDecision::Deny, true), UrlRoute::Ignore(_)));
        assert!(matches!(route_url(cmd("toggle"), UrlSchemeDecision::Ask, true), UrlRoute::Ask(_)));
        assert!(matches!(route_url(cmd("toggle"), UrlSchemeDecision::Allow, true), UrlRoute::Run(_)));
        // 引導未完成：一律忽略
        assert!(matches!(route_url(cmd("start"), UrlSchemeDecision::Allow, false), UrlRoute::Ignore(_)));
    }

    #[test]
    fn url_commands_map_to_pipeline() {
        assert!(matches!(url_to_command(&cmd("toggle"), None, false), Some(PipelineCommand::ToggleRecording { .. })));
        assert!(matches!(url_to_command(&cmd("start"), None, false), Some(PipelineCommand::ToggleRecording { .. })));
        assert!(url_to_command(&cmd("start"), None, true).is_none());
        assert!(matches!(url_to_command(&cmd("stop"), None, true), Some(PipelineCommand::StopRecording)));
        assert!(url_to_command(&cmd("stop"), None, false).is_none());
        assert!(matches!(url_to_command(&cmd("cancel"), None, false), Some(PipelineCommand::CancelRecording)));
    }

    #[test]
    fn modes_found_by_name_or_id() {
        let s = Settings::default();
        assert_eq!(find_mode(&s, "email").map(|m| m.id), Some("email".into()));
        assert_eq!(find_mode(&s, "EMAIL").map(|m| m.id), Some("email".into()));
        assert_eq!(find_mode(&s, "翻譯成英文").map(|m| m.id), Some("translate-en".into()));
        assert!(find_mode(&s, "nope").is_none());
    }
}

//! Pipeline 狀態機本體（移植 VoicePipeline.swift）。
//! 與平台 / 音訊 / STT / 注入的互動全部經過 `Local`（只在 pipeline 執行緒用）與 `Shared`（背景工作執行緒也會用）
//! 兩個 trait，正式版接真的模組，測試接 mock。所有會阻塞的工作（STT 收尾、LLM、注入、建立行事曆）
//! 都丟到背景執行緒，完成後以 `Internal` 訊息回到 pipeline 執行緒；訊息帶 (generation, job)，
//! 不是目前這一份就丟棄。

use crate::inject::InjectError;
use crate::llm::refiner::{RefineRequest, RefineResult, RefinerError};
use crate::logging::{log, log_sensitive};
use crate::types::*;
use crossbeam_channel::Sender;
use parking_lot::{Mutex, RwLock};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// 聆聽觸發 / Smart Send 期間「有人說話」的門檻（AudioLevelMonitor.speechThreshold）
pub(crate) const SPEECH_THRESHOLD: f32 = 0.15;
/// 靜音偵測門檻（SilenceDetector.silenceThreshold）
pub(crate) const SILENCE_THRESHOLD: f32 = 0.08;
/// 音量 / 倒數更新節流（~15 Hz）
pub(crate) const LEVEL_INTERVAL: Duration = Duration::from_millis(66);
const DUCK_DELAY: Duration = Duration::from_millis(200);
const DUCK_RATIO: f32 = 0.2;
const LISTEN_GRACE: Duration = Duration::from_millis(500);
const MAX_EMPTY_STREAK: u32 = 3;
pub(crate) const SINK_ID: &str = "pipeline-stt";

/// 只在 pipeline 執行緒呼叫的依賴（音訊、STT 引擎、前景 App、選取文字、降音量）
pub(crate) trait Local {
    fn audio_running(&self) -> bool;
    fn audio_start(&mut self, settings: &Settings) -> anyhow::Result<()>;
    fn audio_stop(&mut self);
    fn audio_level(&self) -> f32;
    fn add_sink(&self, id: &str, sink: AudioChunkSink, replay_prebuffer: bool);
    fn remove_sink(&self, id: &str);
    fn stt(&self) -> Arc<dyn SttEngine>;
    fn rebuild_stt(&mut self, settings: &Settings);
    fn sense_voice_installed(&self) -> bool;
    fn foreground_app(&self) -> AppContext;
    fn selected_text(&self, ctx: &AppContext) -> Option<String>;
    /// Saybit 自己在前景時把焦點還給上一個外部 App
    fn refocus_last_external(&self);
    fn duck(&self, ratio: f32);
    fn restore_duck(&self);
    /// 回一個「餵音量、回是否已靜音逾時」的偵測器
    fn silence_detector(&self, timeout_secs: f32) -> Box<dyn FnMut(f32) -> bool>;
}

/// 背景工作執行緒也會用到的依賴（必須 Send + Sync）
pub(crate) trait Shared: Send + Sync + 'static {
    fn api_key(&self, provider_id: &str) -> Option<String>;
    fn refine(
        &self,
        settings: &Settings,
        api_key: Option<&str>,
        req: &RefineRequest,
        cancel: &CancelToken,
        on_partial: &mut dyn FnMut(&str),
    ) -> anyhow::Result<RefineResult>;
    fn inject(
        &self,
        text: &str,
        mode: InjectionMode,
        expected_bundle_id: Option<&str>,
        newline_with_shift: bool,
        cancel: &CancelToken,
    ) -> Result<(), InjectError>;
    fn simulate_enter(&self, expected_bundle_id: Option<&str>) -> Result<(), InjectError>;
    fn estimated_duration_secs(&self, text: &str, mode: InjectionMode) -> f32;
    fn cancel_typing(&self);
    fn execute_action(&self, action: &PendingAction) -> anyhow::Result<String>;
    fn dictionary(&self) -> Vec<DictionaryEntry>;
    fn skills(&self) -> Vec<Skill>;
    fn add_history(&self, rec: &HistoryRecord);
}

/// 背景工作回到 pipeline 執行緒的訊息
pub(crate) enum Internal {
    SttPartial { gen: u64, job: u64, text: String },
    SttFinished { gen: u64, job: u64, result: Result<String, String> },
    LlmPartial { gen: u64, job: u64, text: String },
    RefineDone { gen: u64, job: u64, result: anyhow::Result<RefineResult> },
    InjectDone { gen: u64, job: u64, result: Result<(), InjectError> },
    EnterDone { gen: u64, job: u64, result: Result<(), InjectError> },
    ActionDone { gen: u64, job: u64, result: Result<String, String> },
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum PreviewTimeout {
    Confirm,
    Cancel,
}

struct SmartSend {
    end_at: Instant,
    grace_until: Instant,
}

#[derive(Clone)]
struct ErrorContext {
    transcript: String,
    app_context: AppContext,
}

pub(crate) struct Core {
    settings: Arc<Settings>,
    local: Box<dyn Local>,
    shared: Arc<dyn Shared>,
    internal_tx: Sender<Internal>,
    events_tx: Sender<PipelineEvent>,
    shared_snapshot: Arc<RwLock<PipelineSnapshot>>,
    repaint: RepaintFn,

    snap: PipelineSnapshot,
    dirty: bool,
    last_publish: Instant,

    gen: u64,
    job: u64,
    session: Arc<Mutex<Option<Box<dyn SttSession>>>>,
    active_mode: Option<VoiceMode>,
    /// 錄音開始時的前景 App；注入與 Smart Send 前比對
    target: AppContext,
    recording_ended_at: Option<Instant>,
    silence: Option<Box<dyn FnMut(f32) -> bool>>,
    duck_at: Option<Instant>,
    ducked: bool,
    max_rec_at: Option<Instant>,
    processing_cancel: Option<CancelToken>,
    inject_cancel: Option<CancelToken>,
    inject_started_at: Option<Instant>,
    preview_deadline: Option<(Instant, PreviewTimeout)>,
    auto_reset_at: Option<Instant>,
    smart_send_pending_at: Option<Instant>,
    smart_send: Option<SmartSend>,
    /// 前景換過才進預覽的那一次：不自動確認、不 Smart Send
    preview_after_fg_change: bool,
    /// ConfirmAction 成功後注入要不要比對前景
    action_verify: bool,
    last_error: Option<ErrorContext>,
    listening_enabled: bool,
    listen_grace_until: Option<Instant>,
    empty_streak: u32,
    audio_restart_pending: bool,
}

fn stt_key(s: &Settings) -> impl PartialEq {
    (
        s.stt_engine,
        s.language_preference.clone(),
        // SenseVoice 轉繁體 / 裝置相關設定在 make_engine 時決定
        s.input_device_id.clone(),
        s.auto_language_detection,
        s.whisper_cloud_provider.clone(),
        s.whisper_cloud_base_url.clone(),
        s.whisper_cloud_model.clone(),
        s.streaming_provider,
        s.apple_on_device_only,
    )
}

fn audio_key(s: &Settings) -> impl PartialEq {
    (s.input_device_id.clone(), s.enable_voice_bandpass, s.mic_sensitivity.to_bits())
}

/// 設定的語言偏好 → STT 語言代碼
pub(crate) fn stt_language(s: &Settings) -> String {
    if s.auto_language_detection {
        return "auto".into();
    }
    let p = s.language_preference.to_ascii_lowercase();
    if p.starts_with("zh") {
        "zh".into()
    } else if p.starts_with("en") {
        "en".into()
    } else if p.starts_with("ja") {
        "ja".into()
    } else if p.starts_with("ko") {
        "ko".into()
    } else if p.starts_with("yue") {
        "yue".into()
    } else {
        "auto".into()
    }
}

/// 日誌只記長度與前 20 字（含內容的一律走 log_sensitive）
fn log_preview(text: &str) -> String {
    if text.is_empty() {
        return "(空)".into();
    }
    let n = text.chars().count();
    let head: String = text.chars().take(20).collect();
    format!("({n} 字): {head}{}", if n > 20 { "…" } else { "" })
}

impl Core {
    pub(crate) fn new(
        settings: Arc<Settings>,
        local: Box<dyn Local>,
        shared: Arc<dyn Shared>,
        internal_tx: Sender<Internal>,
        events_tx: Sender<PipelineEvent>,
        shared_snapshot: Arc<RwLock<PipelineSnapshot>>,
        repaint: RepaintFn,
    ) -> Self {
        let snap = shared_snapshot.read().clone();
        Core {
            settings,
            local,
            shared,
            internal_tx,
            events_tx,
            shared_snapshot,
            repaint,
            snap,
            dirty: true,
            last_publish: Instant::now(),
            gen: 0,
            job: 0,
            session: Arc::new(Mutex::new(None)),
            active_mode: None,
            target: AppContext::default(),
            recording_ended_at: None,
            silence: None,
            duck_at: None,
            ducked: false,
            max_rec_at: None,
            processing_cancel: None,
            inject_cancel: None,
            inject_started_at: None,
            preview_deadline: None,
            auto_reset_at: None,
            smart_send_pending_at: None,
            smart_send: None,
            preview_after_fg_change: false,
            action_verify: false,
            last_error: None,
            listening_enabled: false,
            listen_grace_until: None,
            empty_streak: 0,
            audio_restart_pending: false,
        }
    }

    // ───────────────────────── 對外入口 ─────────────────────────

    /// 回 false 表示要結束執行緒
    pub(crate) fn handle_command(&mut self, cmd: PipelineCommand, now: Instant) -> bool {
        match cmd {
            PipelineCommand::StartRecording { mode, expected_target } => self.start_recording(mode, expected_target, false, now),
            PipelineCommand::StopRecording => self.stop_and_process(now),
            PipelineCommand::ToggleRecording { mode } => {
                if self.snap.state == PipelineState::Recording {
                    self.stop_and_process(now);
                } else {
                    self.start_recording(mode, None, true, now);
                }
            }
            PipelineCommand::CancelRecording => self.cancel_recording(now),
            PipelineCommand::StartListening => self.start_listening(now),
            PipelineCommand::CancelListening => self.cancel_listening(),
            PipelineCommand::ConfirmInject => self.confirm_inject(true, now),
            PipelineCommand::ConfirmAction => {
                if self.snap.pending_action.is_some() {
                    self.confirm_inject(true, now);
                }
            }
            PipelineCommand::Regenerate => self.regenerate(),
            PipelineCommand::CancelPreview => self.cancel_preview(now),
            PipelineCommand::RetryLastAction => self.retry_last_action(),
            PipelineCommand::SettingsChanged(s) => self.settings_changed(s, now),
            PipelineCommand::SecretsChanged => {
                self.local.rebuild_stt(&self.settings);
                log(LogLevel::Info, "Pipeline", "API Key 變更，已重建辨識引擎");
            }
            PipelineCommand::Shutdown => {
                self.shutdown();
                return false;
            }
        }
        true
    }

    pub(crate) fn handle_internal(&mut self, msg: Internal, now: Instant) {
        match msg {
            Internal::SttPartial { gen, job, text } => {
                if self.is_current(gen, job) && self.snap.state == PipelineState::Recording && self.snap.raw_transcript != text {
                    self.snap.raw_transcript = text;
                    self.dirty = true;
                }
            }
            Internal::SttFinished { gen, job, result } => {
                if self.is_current(gen, job) {
                    self.on_stt_finished(result, now);
                }
            }
            Internal::LlmPartial { gen, job, text } => {
                if self.is_current(gen, job) && self.snap.state == PipelineState::Processing {
                    self.snap.processed_text = text;
                    self.dirty = true;
                }
            }
            Internal::RefineDone { gen, job, result } => {
                if self.is_current(gen, job) {
                    self.processing_cancel = None;
                    self.on_refine_done(result, now);
                }
            }
            Internal::InjectDone { gen, job, result } => {
                if self.is_current(gen, job) {
                    self.inject_cancel = None;
                    self.on_inject_done(result, now);
                }
            }
            Internal::EnterDone { gen, job, result } => {
                if self.is_current(gen, job) {
                    match result {
                        Ok(()) => log(LogLevel::Info, "SmartSend", "已送出 Enter"),
                        Err(InjectError::ForegroundChanged) => {
                            log(LogLevel::Info, "SmartSend", "Smart Send 取消：前景 App 已切換");
                            self.toast("前景 App 已切換，已取消自動送出");
                        }
                        Err(e) => log(LogLevel::Error, "SmartSend", format!("Smart Send 失敗：{e}")),
                    }
                    self.auto_reset(Duration::from_secs(1), now);
                }
            }
            Internal::ActionDone { gen, job, result } => {
                if self.is_current(gen, job) {
                    self.on_action_done(result, now);
                }
            }
        }
    }

    /// 計時器與音量：每次迴圈都呼叫（多呼叫無害）
    pub(crate) fn on_tick(&mut self, now: Instant) {
        let state = self.snap.state.clone();
        let needs_level = matches!(state, PipelineState::Listening | PipelineState::Recording | PipelineState::Confirming { .. });
        let level = if needs_level { self.local.audio_level().clamp(0.0, 1.0) } else { 0.0 };
        if needs_level && (self.snap.audio_level - level).abs() > 0.005 && now.duration_since(self.last_publish) >= LEVEL_INTERVAL {
            self.snap.audio_level = level;
            self.dirty = true;
        }

        if self.audio_restart_pending && !matches!(state, PipelineState::Recording | PipelineState::Listening) {
            self.audio_restart_pending = false;
            self.restart_audio();
        }

        match state {
            PipelineState::Listening => {
                let in_grace = self.listen_grace_until.is_some_and(|g| now < g);
                if !in_grace && level >= SPEECH_THRESHOLD {
                    log(LogLevel::Info, "Pipeline", "聆聽模式偵測到語音，自動開始錄音");
                    self.start_recording(None, None, true, now);
                }
            }
            PipelineState::Recording => {
                if self.duck_at.is_some_and(|t| now >= t) {
                    self.duck_at = None;
                    self.local.duck(DUCK_RATIO);
                    self.ducked = true;
                }
                if self.max_rec_at.is_some_and(|t| now >= t) {
                    log(
                        LogLevel::Info,
                        "Pipeline",
                        format!("錄音達上限 {} 秒，自動停止", self.settings.max_recording_secs),
                    );
                    self.toast("已達錄音長度上限，自動停止");
                    self.stop_and_process(now);
                    return;
                }
                if let Some(detector) = self.silence.as_mut() {
                    if detector(level) {
                        log(
                            LogLevel::Info,
                            "Pipeline",
                            format!("靜音偵測觸發自動停止 ({}s)", self.settings.silence_timeout_secs),
                        );
                        self.stop_and_process(now);
                        return;
                    }
                }
            }
            PipelineState::Previewing => {
                if let Some((at, what)) = self.preview_deadline {
                    if now >= at {
                        self.preview_deadline = None;
                        match what {
                            PreviewTimeout::Confirm => {
                                log(LogLevel::Info, "Pipeline", "預覽逾時無操作，自動確認");
                                self.confirm_inject(false, now);
                            }
                            PreviewTimeout::Cancel => {
                                log(LogLevel::Info, "Pipeline", "預覽逾時無操作，自動取消");
                                self.cancel_preview(now);
                            }
                        }
                        return;
                    }
                }
            }
            PipelineState::Done if self.smart_send_pending_at.is_some_and(|t| now >= t) => {
                self.smart_send_pending_at = None;
                self.start_smart_send(now);
                return;
            }
            PipelineState::Confirming { remaining_secs } => {
                if let Some(ss) = &self.smart_send {
                    let (end_at, grace_until) = (ss.end_at, ss.grace_until);
                    if now >= grace_until && level >= SPEECH_THRESHOLD {
                        self.cancel_smart_send("Smart Send 已取消（偵測到說話）", now);
                        return;
                    }
                    if now >= end_at {
                        self.fire_enter(now);
                        return;
                    }
                    let remaining = end_at.duration_since(now).as_secs_f32();
                    if (remaining_secs - remaining).abs() >= 0.05 && now.duration_since(self.last_publish) >= LEVEL_INTERVAL {
                        self.snap.state = PipelineState::Confirming { remaining_secs: remaining };
                        self.dirty = true;
                    }
                }
            }
            _ => {}
        }

        if self.auto_reset_at.is_some_and(|t| now >= t) {
            self.auto_reset_at = None;
            // 重試 / 重新生成途中不能被舊的 autoReset 打回 idle
            if !matches!(self.snap.state, PipelineState::Recording | PipelineState::Processing | PipelineState::Listening) {
                self.return_to_idle(now);
            }
        }
    }

    /// 下次需要醒來的時間
    pub(crate) fn next_timeout(&self, now: Instant) -> Duration {
        if matches!(
            self.snap.state,
            PipelineState::Listening | PipelineState::Recording | PipelineState::Confirming { .. }
        ) {
            return LEVEL_INTERVAL;
        }
        [
            self.preview_deadline.map(|(t, _)| t),
            self.auto_reset_at,
            self.smart_send_pending_at,
        ]
        .into_iter()
        .flatten()
        .map(|t| t.saturating_duration_since(now).max(Duration::from_millis(5)))
        .min()
        .unwrap_or(Duration::from_secs(1))
        .min(Duration::from_secs(1))
    }

    /// 有變化就寫回共享快照並通知 GUI
    pub(crate) fn flush(&mut self, now: Instant) {
        if !self.dirty {
            return;
        }
        self.dirty = false;
        self.last_publish = now;
        self.snap.generation = self.gen;
        self.snap.can_retry = self.last_error.is_some();
        *self.shared_snapshot.write() = self.snap.clone();
        // GUI 沒在消化時別讓佇列無限長；快照本身是狀態式的，丟掉多餘通知無妨
        if self.events_tx.len() < 64 {
            let _ = self.events_tx.send(PipelineEvent::SnapshotChanged);
        }
        (self.repaint)();
    }

    #[cfg(test)]
    pub(crate) fn snapshot(&self) -> &PipelineSnapshot {
        &self.snap
    }

    // ───────────────────────── 小工具 ─────────────────────────

    fn is_current(&self, gen: u64, job: u64) -> bool {
        gen == self.gen && job == self.job
    }

    fn next_job(&mut self) -> (u64, u64) {
        self.job += 1;
        (self.gen, self.job)
    }

    fn set_state(&mut self, s: PipelineState) {
        if self.snap.state != s {
            log(LogLevel::Debug, "Pipeline", format!("狀態 {:?} → {:?}", self.snap.state, s));
            self.snap.state = s;
        }
        self.dirty = true;
    }

    fn emit(&self, ev: PipelineEvent) {
        let _ = self.events_tx.send(ev);
        (self.repaint)();
    }

    fn toast(&self, text: &str) {
        self.emit(PipelineEvent::Toast { text: text.into() });
    }

    fn error(&mut self, msg: String, after: Duration, now: Instant) {
        log(LogLevel::Error, "Pipeline", msg.clone());
        self.set_state(PipelineState::Error(msg));
        self.auto_reset(after, now);
    }

    fn auto_reset(&mut self, after: Duration, now: Instant) {
        self.auto_reset_at = Some(now + after);
    }

    fn is_terminal_target(&self) -> bool {
        crate::app_context::is_terminal(&self.snap.app_context) || crate::app_context::is_terminal(&self.target)
    }

    /// 終端機：去掉尾端換行，避免貼上即執行
    fn sanitize_for_target(&self, text: &str) -> String {
        if self.is_terminal_target() {
            text.trim_end_matches(['\n', '\r']).to_string()
        } else {
            text.to_string()
        }
    }

    fn spawn_worker(name: &str, f: impl FnOnce() + Send + 'static) {
        if let Err(e) = std::thread::Builder::new().name(format!("saybit-{name}")).spawn(f) {
            log(LogLevel::Error, "Pipeline", format!("無法建立背景執行緒 {name}：{e}"));
        }
    }

    fn cancel_jobs(&mut self) {
        if let Some(t) = self.processing_cancel.take() {
            t.cancel();
        }
        if let Some(t) = self.inject_cancel.take() {
            t.cancel();
        }
    }

    fn clear_timers(&mut self) {
        self.preview_deadline = None;
        self.auto_reset_at = None;
        self.smart_send_pending_at = None;
        self.smart_send = None;
    }

    fn restart_audio(&mut self) {
        self.local.audio_stop();
        if let Err(e) = self.local.audio_start(&self.settings) {
            log(LogLevel::Error, "Audio", format!("麥克風重新啟動失敗：{e}"));
        }
    }

    // ───────────────────────── 聆聽 ─────────────────────────

    fn start_listening(&mut self, now: Instant) {
        if self.snap.state != PipelineState::Idle {
            return;
        }
        if !self.listening_enabled {
            self.empty_streak = 0;
        }
        if !self.local.audio_running() {
            if let Err(e) = self.local.audio_start(&self.settings) {
                log(LogLevel::Error, "Audio", format!("麥克風啟動失敗：{e}"));
            }
        }
        self.listening_enabled = true;
        self.listen_grace_until = Some(now + LISTEN_GRACE);
        log(LogLevel::Info, "Pipeline", "進入聆聽模式（持續），等待語音觸發");
        self.snap.audio_level = 0.0;
        self.set_state(PipelineState::Listening);
        self.emit(PipelineEvent::OverlayVisibility(true));
    }

    fn cancel_listening(&mut self) {
        self.listening_enabled = false;
        if self.snap.state == PipelineState::Listening {
            log(LogLevel::Info, "Pipeline", "取消聆聽模式");
            self.snap.audio_level = 0.0;
            self.set_state(PipelineState::Idle);
        }
    }

    // ───────────────────────── 錄音 ─────────────────────────

    fn start_recording(&mut self, mode: Option<VoiceMode>, expected_target: Option<AppContext>, auto_stop: bool, now: Instant) {
        // 錄音中 / 處理中不能開新 session：舊結果會覆寫並注入到新 session，舊 STT 也會變孤兒
        if matches!(self.snap.state, PipelineState::Recording | PipelineState::Processing) {
            log(LogLevel::Info, "Pipeline", format!("忽略開始錄音：目前狀態為 {:?}", self.snap.state));
            return;
        }

        // 新 session：讓所有舊的收尾工作 / 回呼失效
        self.gen += 1;
        self.job += 1;
        self.cancel_jobs();
        self.shared.cancel_typing();
        self.clear_timers();
        self.preview_after_fg_change = false;
        self.active_mode = mode;
        self.snap.mode_name = self.active_mode.as_ref().map(|m| m.name.clone());
        self.snap.pending_action = None;
        if let Some(m) = &self.active_mode {
            log(LogLevel::Info, "Pipeline", format!("語音模式: {}", m.name));
        }

        // 前置檢查（失敗時從 .error 回 idle 會停止聆聽模式，避免無限循環）
        let provider = crate::llm::providers::selected(&self.settings);
        if provider.requires_api_key && self.shared.api_key(&provider.id).is_none_or(|k| k.trim().is_empty()) {
            self.error(format!("未設定 {} API Key，請在設定中輸入", provider.name), Duration::from_secs(3), now);
            return;
        }
        let stt = self.local.stt();
        if let Some(reason) = stt.unavailable_reason() {
            self.error(reason, Duration::from_secs(4), now);
            return;
        }
        if !self.local.audio_running() {
            log(LogLevel::Error, "Audio", "麥克風引擎未運行，嘗試重新啟動");
            if let Err(e) = self.local.audio_start(&self.settings) {
                log(LogLevel::Error, "Audio", format!("麥克風啟動失敗：{e}"));
            }
        }
        if !self.local.audio_running() {
            self.error("無法啟動麥克風，請檢查輸入裝置與麥克風權限".into(), Duration::from_secs(4), now);
            return;
        }

        // 前景 App（注入 / Smart Send 前比對）與選取文字
        let target = expected_target.unwrap_or_else(|| self.local.foreground_app());
        let mut ctx = target.clone();
        ctx.selected_text = if self.settings.enable_context_awareness {
            self.local.selected_text(&target).filter(|s| !s.is_empty())
        } else {
            None
        };
        if let Some(sel) = &ctx.selected_text {
            log_sensitive(LogLevel::Info, "Context", format!("選取文字 {}", log_preview(sel)));
        }
        log(LogLevel::Info, "Context", format!("App 上下文: {} ({})", ctx.app_name, ctx.bundle_id));
        self.target = target;

        // 重置這次 session 的顯示內容
        self.snap.raw_transcript.clear();
        self.snap.processed_text.clear();
        self.snap.usage = TokenUsage::default();
        self.snap.cost_usd = None;
        self.snap.app_context = ctx;
        self.snap.model_name = self.settings.selected_model.clone();
        self.snap.recording_started_at = Some(now);
        self.snap.audio_level = 0.0;
        self.recording_ended_at = None;
        self.last_error = None;

        // STT session
        let (gen, job) = (self.gen, self.job);
        let tx = self.internal_tx.clone();
        let opts = SttStartOptions {
            language: stt_language(&self.settings),
            hint_terms: crate::dictionary::hint_terms(&self.shared.dictionary()),
            on_partial: Some(Box::new(move |text: String| {
                let _ = tx.send(Internal::SttPartial { gen, job, text });
            })),
        };
        let session = match stt.start(opts) {
            Ok(s) => s,
            Err(e) => {
                self.error(format!("語音辨識啟動失敗：{e}"), Duration::from_secs(3), now);
                return;
            }
        };
        *self.session.lock() = Some(session);
        let slot = self.session.clone();
        self.local.add_sink(
            SINK_ID,
            Box::new(move |samples: &[f32]| {
                if let Some(s) = slot.lock().as_mut() {
                    s.push(samples);
                }
            }),
            true,
        );

        log(LogLevel::Info, "STT", format!("開始錄音 (engine={:?})", self.settings.stt_engine));
        self.set_state(PipelineState::Recording);
        self.duck_at = self.settings.enable_ducking.then_some(now + DUCK_DELAY);
        self.max_rec_at = Some(now + Duration::from_secs(self.settings.max_recording_secs.max(5) as u64));
        self.silence = if auto_stop && self.settings.enable_auto_stop {
            Some(self.local.silence_detector(self.settings.silence_timeout_secs))
        } else {
            None
        };
        self.emit(PipelineEvent::OverlayVisibility(true));
        self.emit(PipelineEvent::RecordingStarted);
    }

    /// 真正離開 recording 的轉換點：拆 sink、還原系統音量、停計時器
    fn end_recording_phase(&mut self) {
        self.local.remove_sink(SINK_ID);
        self.duck_at = None;
        if self.ducked {
            self.ducked = false;
            self.local.restore_duck();
        }
        self.max_rec_at = None;
        self.silence = None;
        self.snap.audio_level = 0.0;
    }

    fn stop_and_process(&mut self, now: Instant) {
        if self.snap.state != PipelineState::Recording {
            return;
        }
        self.end_recording_phase();
        self.recording_ended_at = Some(now);
        let session = self.session.lock().take();
        self.set_state(PipelineState::Processing);
        self.emit(PipelineEvent::RecordingStopped);
        let duration = self.snap.recording_started_at.map(|t| now.duration_since(t).as_secs_f32()).unwrap_or(0.0);
        log(LogLevel::Info, "STT", format!("錄音結束 (時長={duration:.1}s)"));

        let (gen, job) = self.next_job();
        let tx = self.internal_tx.clone();
        Self::spawn_worker("stt-finish", move || {
            let result = match session {
                Some(s) => s.finish().map_err(|e| e.to_string()),
                None => Ok(String::new()),
            };
            let _ = tx.send(Internal::SttFinished { gen, job, result });
        });
    }

    /// 取消錄音 / 處理中的請求，不送 AI、不輸入文字
    fn cancel_recording(&mut self, now: Instant) {
        match self.snap.state {
            PipelineState::Recording => {
                self.end_recording_phase();
                if let Some(s) = self.session.lock().take() {
                    Self::spawn_worker("stt-cancel", move || s.cancel());
                }
                self.emit(PipelineEvent::RecordingStopped);
                log(LogLevel::Info, "Pipeline", "錄音已取消");
            }
            PipelineState::Processing => {
                // STT 收尾或 LLM 進行中：取消工作，並以 generation 讓之後回來的結果全部作廢
                log(LogLevel::Info, "Pipeline", "處理中取消");
            }
            PipelineState::Listening => {
                self.cancel_listening();
                return;
            }
            PipelineState::Confirming { .. } => {
                self.cancel_smart_send("Smart Send 已取消（使用者取消）", now);
                return;
            }
            _ => return,
        }
        self.gen += 1;
        self.job += 1;
        self.cancel_jobs();
        self.shared.cancel_typing();
        self.snap.audio_level = 0.0;
        self.return_to_idle(now);
    }

    fn on_stt_finished(&mut self, result: Result<String, String>, now: Instant) {
        let transcript = match result {
            Ok(t) => t.trim().to_string(),
            Err(msg) => {
                self.error(format!("語音辨識失敗：{msg}"), Duration::from_secs(3), now);
                return;
            }
        };
        self.snap.raw_transcript = transcript.clone();
        self.dirty = true;
        log_sensitive(LogLevel::Info, "STT", format!("原始轉錄 {}", log_preview(&transcript)));
        if transcript.is_empty() {
            log(LogLevel::Info, "Pipeline", "轉錄為空，跳過 LLM");
            self.handle_empty_transcript(now);
            return;
        }
        self.empty_streak = 0;
        self.start_refine();
    }

    /// 空轉錄：一般情況回 idle；聆聽模式下連續多次（噪音觸發）就停止聆聽並提示
    fn handle_empty_transcript(&mut self, now: Instant) {
        if !self.listening_enabled {
            self.return_to_idle(now);
            return;
        }
        self.empty_streak += 1;
        if self.empty_streak < MAX_EMPTY_STREAK {
            self.return_to_idle(now);
            return;
        }
        log(LogLevel::Info, "Pipeline", format!("聆聽模式連續 {} 次空轉錄，停止聆聽", self.empty_streak));
        self.listening_enabled = false;
        self.empty_streak = 0;
        self.error("連續多次未辨識到語音，已停止聆聽模式".into(), Duration::from_secs(3), now);
    }

    // ───────────────────────── LLM ─────────────────────────

    fn start_refine(&mut self) {
        self.set_state(PipelineState::Processing);
        let (gen, job) = self.next_job();
        let token = CancelToken::new();
        self.processing_cancel = Some(token.clone());
        self.snap.model_name = self.settings.selected_model.clone();
        let req = RefineRequest {
            transcript: self.snap.raw_transcript.clone(),
            selected_text: self.snap.app_context.selected_text.clone(),
            app_context: self.snap.app_context.clone(),
            mode_instructions: self.active_mode.as_ref().map(|m| m.instructions.clone()),
            dictionary: self.shared.dictionary(),
            skills: self.shared.skills(),
        };
        let settings = self.settings.clone();
        let shared = self.shared.clone();
        let tx = self.internal_tx.clone();
        Self::spawn_worker("refine", move || {
            let provider = crate::llm::providers::selected(&settings);
            let key = shared.api_key(&provider.id);
            let ptx = tx.clone();
            let result = shared.refine(&settings, key.as_deref(), &req, &token, &mut |text: &str| {
                let _ = ptx.send(Internal::LlmPartial { gen, job, text: text.to_string() });
            });
            let _ = tx.send(Internal::RefineDone { gen, job, result });
        });
    }

    fn on_refine_done(&mut self, result: anyhow::Result<RefineResult>, now: Instant) {
        match result {
            Ok(r) => {
                self.snap.usage = r.usage.clone();
                self.snap.model_name = r.model.clone();
                self.snap.cost_usd =
                    crate::llm::pricing::cost_usd(&r.model, r.usage.prompt_tokens, r.usage.completion_tokens);
                match r.outcome {
                    RefineOutcome::Text(text) => {
                        self.snap.processed_text = self.sanitize_for_target(&text);
                        self.dirty = true;
                        if self.is_terminal_target() {
                            // 終端機一律預覽、不自動確認（貼上即執行，必須使用者確認）
                            log(LogLevel::Info, "Pipeline", "目標為終端機，強制預覽");
                            self.preview_deadline = None;
                            self.set_state(PipelineState::Previewing);
                        } else if self.settings.enable_preview_before_inject {
                            log(LogLevel::Info, "Pipeline", "進入預覽模式，等待使用者確認");
                            self.set_state(PipelineState::Previewing);
                            self.preview_deadline = Some((self.preview_at(now), PreviewTimeout::Confirm));
                        } else {
                            self.perform_inject(true, now);
                        }
                    }
                    RefineOutcome::Action { action, confirmation } => {
                        self.snap.processed_text = confirmation;
                        self.snap.pending_action = Some(action);
                        self.set_state(PipelineState::Previewing);
                        // 行事曆 / 提醒逾時是「自動取消」
                        self.preview_deadline = Some((self.preview_at(now), PreviewTimeout::Cancel));
                    }
                    RefineOutcome::NeedsSelection(hint) => {
                        self.snap.processed_text = hint.clone();
                        self.error(hint, Duration::from_secs(3), now);
                    }
                }
            }
            Err(e) => {
                // 取消不是錯誤（cancelRecording 已推進 generation，正常不會走到這裡）
                if crate::llm::client::is_cancelled(&e) {
                    return;
                }
                if let Some(re) = e.downcast_ref::<RefinerError>() {
                    let msg = re.to_string();
                    self.error(msg, Duration::from_secs(3), now);
                    return;
                }
                let msg = crate::llm::refiner::friendly_error(&e);
                log(LogLevel::Error, "LLM", format!("LLM 錯誤: {msg} ({e})"));
                self.last_error = Some(ErrorContext {
                    transcript: self.snap.raw_transcript.clone(),
                    app_context: self.snap.app_context.clone(),
                });
                self.error(msg, Duration::from_secs(5), now);
            }
        }
    }

    fn preview_at(&self, now: Instant) -> Instant {
        now + Duration::from_secs_f32(self.settings.preview_timeout_secs.max(1.0))
    }

    fn retry_last_action(&mut self) {
        let Some(ctx) = self.last_error.clone() else { return };
        if matches!(self.snap.state, PipelineState::Recording | PipelineState::Processing | PipelineState::Listening) {
            return;
        }
        log(LogLevel::Info, "Pipeline", "Quick Retry: 重新處理上次失敗的請求");
        // 錯誤狀態排了 autoReset，不取消的話重試途中會被打回 idle
        self.auto_reset_at = None;
        self.snap.raw_transcript = ctx.transcript;
        self.snap.app_context = ctx.app_context;
        self.snap.processed_text.clear();
        self.last_error = None;
        self.start_refine();
    }

    // ───────────────────────── 預覽 ─────────────────────────

    fn confirm_inject(&mut self, by_user: bool, now: Instant) {
        if self.snap.state != PipelineState::Previewing {
            return;
        }
        self.preview_deadline = None;
        log(LogLevel::Info, "Pipeline", if by_user { "使用者確認注入" } else { "預覽逾時自動確認" });
        if by_user {
            // 使用者看過預覽後親手確認：目標改為目前的前景 App（Smart Send 也以它為準）
            self.local.refocus_last_external();
            self.target = self.local.foreground_app();
        }
        if let Some(action) = self.snap.pending_action.clone() {
            // 執行中切到 processing，避免重複確認造成重複建立
            self.set_state(PipelineState::Processing);
            self.action_verify = !by_user;
            let (gen, job) = self.next_job();
            let shared = self.shared.clone();
            let tx = self.internal_tx.clone();
            Self::spawn_worker("action", move || {
                let result = shared.execute_action(&action).map_err(|e| e.to_string());
                let _ = tx.send(Internal::ActionDone { gen, job, result });
            });
        } else {
            self.perform_inject(!by_user, now);
        }
    }

    fn on_action_done(&mut self, result: Result<String, String>, now: Instant) {
        self.snap.pending_action = None;
        match result {
            Ok(text) => {
                if !text.trim().is_empty() {
                    self.snap.processed_text = text;
                }
                log_sensitive(LogLevel::Info, "Action", format!("動作已建立 {}", log_preview(&self.snap.processed_text)));
                let verify = self.action_verify;
                self.perform_inject(verify, now);
            }
            Err(msg) => self.error(format!("動作執行失敗：{msg}"), Duration::from_secs(3), now),
        }
    }

    fn cancel_preview(&mut self, now: Instant) {
        if self.snap.state != PipelineState::Previewing {
            return;
        }
        self.preview_deadline = None;
        self.snap.pending_action = None;
        log(LogLevel::Info, "Pipeline", "使用者取消預覽");
        self.return_to_idle(now);
    }

    fn regenerate(&mut self) {
        if self.snap.state != PipelineState::Previewing {
            return;
        }
        log(LogLevel::Info, "Pipeline", "使用者要求重新生成");
        self.preview_deadline = None;
        self.auto_reset_at = None;
        self.snap.processed_text.clear();
        self.snap.pending_action = None;
        self.start_refine();
    }

    // ───────────────────────── 注入 / Smart Send ─────────────────────────

    /// verify_target：注入時比對錄音開始時的前景 App；不一致改預覽（使用者親手確認時為 false）
    fn perform_inject(&mut self, verify_target: bool, now: Instant) {
        let text = self.sanitize_for_target(&self.snap.processed_text);
        self.snap.processed_text = text.clone();
        if text.trim().is_empty() {
            self.return_to_idle(now);
            return;
        }
        let expected = if verify_target && !self.target.bundle_id.is_empty() { Some(self.target.bundle_id.clone()) } else { None };
        let mode = self.settings.injection_mode;
        let newline_with_shift = crate::app_context::category(&self.target) == ContextCategory::ChatMessaging;
        self.set_state(PipelineState::Done);
        self.inject_started_at = Some(now);
        let (gen, job) = self.next_job();
        let token = CancelToken::new();
        self.inject_cancel = Some(token.clone());
        let shared = self.shared.clone();
        let tx = self.internal_tx.clone();
        log(
            LogLevel::Info,
            "Inject",
            format!("注入開始 (mode={mode:?}, len={}, expected={})", text.chars().count(), expected.as_deref().unwrap_or("-")),
        );
        Self::spawn_worker("inject", move || {
            let result = shared.inject(&text, mode, expected.as_deref(), newline_with_shift, &token);
            let _ = tx.send(Internal::InjectDone { gen, job, result });
        });
    }

    fn on_inject_done(&mut self, result: Result<(), InjectError>, now: Instant) {
        match result {
            Ok(()) => {
                log(LogLevel::Info, "Inject", format!("文字已注入 (mode={:?})", self.settings.injection_mode));
                self.save_history(now);
                self.emit(PipelineEvent::Injected);
                let terminal = self.is_terminal_target();
                if self.settings.enable_smart_send && (terminal || self.preview_after_fg_change) {
                    log(
                        LogLevel::Info,
                        "SmartSend",
                        if terminal { "目標為終端機，停用 Smart Send" } else { "前景曾切換，停用 Smart Send" },
                    );
                    self.auto_reset(Duration::from_secs(2), now);
                } else if self.settings.enable_smart_send {
                    // 逐字輸入還在打就等打完再倒數（inject 已阻塞到完成，這裡以開始時間 + 預估時長為準）
                    let typing = self.shared.estimated_duration_secs(&self.snap.processed_text, self.settings.injection_mode);
                    let begin = self.inject_started_at.unwrap_or(now) + Duration::from_secs_f32(typing.max(0.0));
                    self.smart_send_pending_at = Some(begin.max(now));
                } else {
                    self.auto_reset(Duration::from_secs(2), now);
                }
            }
            Err(InjectError::ForegroundChanged) => {
                log(LogLevel::Info, "Inject", "前景 App 已變更，不自動注入，改為預覽");
                self.preview_after_fg_change = true;
                // 不排自動確認：自動確認會再次比對失敗，只能由使用者確認或取消
                self.preview_deadline = None;
                self.set_state(PipelineState::Previewing);
                self.toast("前景 App 已切換，請確認後再輸入");
            }
            Err(InjectError::Cancelled) => {
                log(LogLevel::Info, "Inject", "注入已取消");
                self.return_to_idle(now);
            }
            Err(InjectError::Other(m)) => self.error(format!("注入失敗：{m}"), Duration::from_secs(3), now),
        }
    }

    fn save_history(&self, now: Instant) {
        let duration = match (self.snap.recording_started_at, self.recording_ended_at) {
            (Some(a), Some(b)) => b.duration_since(a).as_secs_f32(),
            (Some(a), None) => now.duration_since(a).as_secs_f32(),
            _ => 0.0,
        };
        let mode = match &self.active_mode {
            Some(m) => m.name.clone(),
            None if self.snap.app_context.selected_text.is_some() => "command".into(),
            None => "dictation".into(),
        };
        self.shared.add_history(&HistoryRecord {
            id: 0,
            timestamp: chrono::Utc::now(),
            raw_transcript: self.snap.raw_transcript.clone(),
            processed_text: self.snap.processed_text.clone(),
            app_name: self.snap.app_context.app_name.clone(),
            mode,
            model_name: self.snap.model_name.clone(),
            duration_secs: duration,
            prompt_tokens: self.snap.usage.prompt_tokens,
            completion_tokens: self.snap.usage.completion_tokens,
            total_tokens: self.snap.usage.total_tokens,
            cost_usd: self.snap.cost_usd,
        });
    }

    fn start_smart_send(&mut self, now: Instant) {
        if self.snap.state != PipelineState::Done {
            return;
        }
        let delay = self.settings.smart_send_delay_secs.max(0.0);
        log(LogLevel::Info, "SmartSend", format!("Smart Send 倒數開始 ({delay:.1}s)"));
        // 有完成音效時給 0.8 秒緩衝，避免音效本身觸發取消
        let grace = if self.settings.enable_sound_feedback { Duration::from_millis(800) } else { Duration::ZERO };
        self.smart_send = Some(SmartSend { end_at: now + Duration::from_secs_f32(delay), grace_until: now + grace });
        self.set_state(PipelineState::Confirming { remaining_secs: delay });
    }

    fn cancel_smart_send(&mut self, why: &str, now: Instant) {
        if !matches!(self.snap.state, PipelineState::Confirming { .. }) {
            return;
        }
        log(LogLevel::Info, "SmartSend", why);
        self.smart_send = None;
        self.set_state(PipelineState::Done);
        self.toast("已取消自動送出");
        self.auto_reset(Duration::from_millis(1500), now);
    }

    fn fire_enter(&mut self, now: Instant) {
        self.smart_send = None;
        let expected = (!self.target.bundle_id.is_empty()).then(|| self.target.bundle_id.clone());
        // 送 Enter 前再比對一次前景，不一致就取消（避免把別的對話送出）
        if let Some(exp) = &expected {
            let current = self.local.foreground_app();
            if &current.bundle_id != exp {
                log(
                    LogLevel::Info,
                    "SmartSend",
                    format!("Smart Send 取消：前景 App 已變更（目前: {}）", current.app_name),
                );
                self.set_state(PipelineState::Done);
                self.toast("前景 App 已切換，已取消自動送出");
                self.auto_reset(Duration::from_millis(1500), now);
                return;
            }
        }
        log(LogLevel::Info, "SmartSend", "Smart Send 倒數結束，送出 Enter");
        self.set_state(PipelineState::Done);
        let (gen, job) = self.next_job();
        let shared = self.shared.clone();
        let tx = self.internal_tx.clone();
        Self::spawn_worker("enter", move || {
            let result = shared.simulate_enter(expected.as_deref());
            let _ = tx.send(Internal::EnterDone { gen, job, result });
        });
    }

    // ───────────────────────── 收尾 ─────────────────────────

    /// 回到 idle 或自動重新進入聆聽模式
    fn return_to_idle(&mut self, now: Instant) {
        let from_error = matches!(self.snap.state, PipelineState::Error(_));
        self.clear_timers();
        self.snap.pending_action = None;
        self.snap.audio_level = 0.0;
        self.set_state(PipelineState::Idle);
        if !self.listening_enabled {
            return;
        }
        if from_error {
            // 從錯誤回來（缺 key / 模型未下載 / LLM 失敗…）不要自動重新聆聽，否則會無限 錯誤→聆聽→錯誤
            log(LogLevel::Info, "Pipeline", "發生錯誤，停止聆聽模式");
            self.listening_enabled = false;
            self.empty_streak = 0;
            return;
        }
        self.start_listening(now);
    }

    fn settings_changed(&mut self, new: Arc<Settings>, now: Instant) {
        let old = std::mem::replace(&mut self.settings, new);
        if stt_key(&old) != stt_key(&self.settings) {
            if self.snap.state == PipelineState::Recording {
                log(LogLevel::Info, "Pipeline", "錄音中變更辨識設定，取消本次錄音");
                self.cancel_recording(now);
            }
            self.local.rebuild_stt(&self.settings);
            log(LogLevel::Info, "Pipeline", format!("辨識引擎: {:?}", self.settings.stt_engine));
            self.preload_stt();
        }
        if audio_key(&old) != audio_key(&self.settings) {
            if matches!(self.snap.state, PipelineState::Recording | PipelineState::Listening) {
                self.audio_restart_pending = true;
            } else {
                self.restart_audio();
            }
        }
    }

    /// SenseVoice 模型常駐記憶體（start + cancel 一次），按快捷鍵時不用等載入
    pub(crate) fn preload_stt(&mut self) {
        if self.settings.stt_engine != SttEngineKind::SenseVoice || !self.local.sense_voice_installed() {
            return;
        }
        let stt = self.local.stt();
        let language = stt_language(&self.settings);
        Self::spawn_worker("stt-preload", move || {
            if stt.unavailable_reason().is_none() {
                if let Ok(s) = stt.start(SttStartOptions { language, hint_terms: Vec::new(), on_partial: None }) {
                    s.cancel();
                }
            }
        });
    }

    fn shutdown(&mut self) {
        log(LogLevel::Info, "Pipeline", "Pipeline 結束");
        self.gen += 1;
        self.job += 1;
        self.cancel_jobs();
        self.shared.cancel_typing();
        if self.snap.state == PipelineState::Recording {
            self.end_recording_phase();
            if let Some(s) = self.session.lock().take() {
                s.cancel();
            }
        }
        if self.ducked {
            self.ducked = false;
            self.local.restore_duck();
        }
        self.local.audio_stop();
    }
}

#[cfg(test)]
#[path = "core_tests.rs"]
mod tests;

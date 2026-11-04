//! Pipeline 狀態機測試：audio / STT / 注入 / LLM 全部是 mock，不會錄音、不會注入、不會連網。

use super::*;
use crate::llm::client::LlmError;
use crossbeam_channel::Receiver;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

// ───────────────────────── mocks ─────────────────────────

#[derive(Default)]
struct Probe {
    level: Mutex<f32>,
    fg: Mutex<AppContext>,
    selected: Mutex<Option<String>>,
    transcript: Mutex<String>,
    stt_unavailable: Mutex<Option<String>>,
    audio_ok: AtomicBool,
    sinks: Mutex<Vec<String>>,
    pushes: AtomicUsize,
    rebuilds: AtomicUsize,
    ducks: AtomicUsize,
    restores: AtomicUsize,
    silence_fire: AtomicBool,
    // shared
    api_key: Mutex<Option<String>>,
    refine_results: Mutex<VecDeque<anyhow::Result<RefineResult>>>,
    /// refine 要阻塞到 cancel 才返回
    refine_block: AtomicBool,
    refine_calls: AtomicUsize,
    inject_results: Mutex<VecDeque<Result<(), InjectError>>>,
    injected: Mutex<Vec<(String, Option<String>, bool)>>,
    enters: Mutex<Vec<Option<String>>>,
    actions: AtomicUsize,
    history: Mutex<Vec<HistoryRecord>>,
    typing_secs: Mutex<f32>,
}

struct MockStt(Arc<Probe>);
struct MockSession(Arc<Probe>);

impl SttSession for MockSession {
    fn push(&mut self, _samples: &[f32]) {
        self.0.pushes.fetch_add(1, Ordering::SeqCst);
    }
    fn finish(self: Box<Self>) -> anyhow::Result<String> {
        Ok(self.0.transcript.lock().clone())
    }
    fn cancel(self: Box<Self>) {}
}

impl SttEngine for MockStt {
    fn kind(&self) -> SttEngineKind {
        SttEngineKind::SenseVoice
    }
    fn unavailable_reason(&self) -> Option<String> {
        self.0.stt_unavailable.lock().clone()
    }
    fn start(&self, opts: SttStartOptions) -> anyhow::Result<Box<dyn SttSession>> {
        if let Some(cb) = opts.on_partial {
            cb("部分".into());
        }
        Ok(Box::new(MockSession(self.0.clone())))
    }
}

struct MockLocal(Arc<Probe>);

impl Local for MockLocal {
    fn audio_running(&self) -> bool {
        self.0.audio_ok.load(Ordering::SeqCst)
    }
    fn audio_start(&mut self, _s: &Settings) -> anyhow::Result<()> {
        Ok(())
    }
    fn audio_stop(&mut self) {}
    fn audio_level(&self) -> f32 {
        *self.0.level.lock()
    }
    fn add_sink(&self, id: &str, mut sink: AudioChunkSink, _replay: bool) {
        sink(&[0.0; 160]);
        self.0.sinks.lock().push(id.to_string());
    }
    fn remove_sink(&self, id: &str) {
        self.0.sinks.lock().retain(|s| s != id);
    }
    fn stt(&self) -> Arc<dyn SttEngine> {
        Arc::new(MockStt(self.0.clone()))
    }
    fn rebuild_stt(&mut self, _s: &Settings) {
        self.0.rebuilds.fetch_add(1, Ordering::SeqCst);
    }
    fn sense_voice_installed(&self) -> bool {
        false
    }
    fn foreground_app(&self) -> AppContext {
        self.0.fg.lock().clone()
    }
    fn selected_text(&self, _ctx: &AppContext) -> Option<String> {
        self.0.selected.lock().clone()
    }
    fn refocus_last_external(&self) {}
    fn duck(&self, _ratio: f32) {
        self.0.ducks.fetch_add(1, Ordering::SeqCst);
    }
    fn restore_duck(&self) {
        self.0.restores.fetch_add(1, Ordering::SeqCst);
    }
    fn silence_detector(&self, _timeout: f32) -> Box<dyn FnMut(f32) -> bool> {
        let p = self.0.clone();
        Box::new(move |_| p.silence_fire.load(Ordering::SeqCst))
    }
}

struct MockShared(Arc<Probe>);

impl Shared for MockShared {
    fn api_key(&self, _id: &str) -> Option<String> {
        self.0.api_key.lock().clone()
    }
    fn refine(
        &self,
        _s: &Settings,
        _k: Option<&str>,
        _req: &RefineRequest,
        cancel: &CancelToken,
        on_partial: &mut dyn FnMut(&str),
    ) -> anyhow::Result<RefineResult> {
        self.0.refine_calls.fetch_add(1, Ordering::SeqCst);
        on_partial("串流中");
        if self.0.refine_block.load(Ordering::SeqCst) {
            while !cancel.is_cancelled() {
                std::thread::sleep(Duration::from_millis(5));
            }
            return Err(LlmError::Cancelled.into());
        }
        self.0.refine_results.lock().pop_front().unwrap_or_else(|| Ok(text_result("你好。")))
    }
    fn inject(&self, text: &str, _m: InjectionMode, expected: Option<&str>, shift: bool, _c: &CancelToken) -> Result<(), InjectError> {
        self.0.injected.lock().push((text.to_string(), expected.map(String::from), shift));
        self.0.inject_results.lock().pop_front().unwrap_or(Ok(()))
    }
    fn simulate_enter(&self, expected: Option<&str>) -> Result<(), InjectError> {
        self.0.enters.lock().push(expected.map(String::from));
        Ok(())
    }
    fn estimated_duration_secs(&self, _t: &str, _m: InjectionMode) -> f32 {
        *self.0.typing_secs.lock()
    }
    fn cancel_typing(&self) {}
    fn execute_action(&self, _a: &PendingAction) -> anyhow::Result<String> {
        self.0.actions.fetch_add(1, Ordering::SeqCst);
        Ok("已建立行程".into())
    }
    fn dictionary(&self) -> Vec<DictionaryEntry> {
        Vec::new()
    }
    fn skills(&self) -> Vec<Skill> {
        Vec::new()
    }
    fn add_history(&self, rec: &HistoryRecord) {
        self.0.history.lock().push(rec.clone());
    }
}

fn text_result(t: &str) -> RefineResult {
    RefineResult {
        outcome: RefineOutcome::Text(t.into()),
        usage: TokenUsage { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 },
        model: "gpt-4o".into(),
    }
}

fn slack() -> AppContext {
    AppContext { app_name: "Slack".into(), bundle_id: "com.tinyspeck.slackmacgap".into(), pid: Some(1), ..Default::default() }
}

// ───────────────────────── harness ─────────────────────────

struct H {
    core: Core,
    p: Arc<Probe>,
    rx: Receiver<Internal>,
    events: Receiver<PipelineEvent>,
    now: Instant,
}

impl H {
    fn new(f: impl FnOnce(&mut Settings)) -> H {
        let mut s = Settings { enable_sound_feedback: false, ..Default::default() };
        f(&mut s);
        let p = Arc::new(Probe::default());
        p.audio_ok.store(true, Ordering::SeqCst);
        *p.api_key.lock() = Some("sk-test".into());
        *p.fg.lock() = slack();
        *p.transcript.lock() = "你好".into();
        let (itx, rx) = crossbeam_channel::unbounded();
        let (etx, events) = crossbeam_channel::unbounded();
        let snapshot = Arc::new(RwLock::new(PipelineSnapshot::default()));
        let core = Core::new(
            Arc::new(s),
            Box::new(MockLocal(p.clone())),
            Arc::new(MockShared(p.clone())),
            itx,
            etx,
            snapshot,
            Arc::new(|| {}),
        );
        H { core, p, rx, events, now: Instant::now() }
    }

    fn cmd(&mut self, c: PipelineCommand) {
        self.core.handle_command(c, self.now);
        self.core.on_tick(self.now);
        self.core.flush(self.now);
    }

    fn state(&self) -> PipelineState {
        self.core.snapshot().state.clone()
    }

    fn advance(&mut self, d: Duration) {
        self.now += d;
        self.core.on_tick(self.now);
        self.core.flush(self.now);
    }

    /// 消化背景工作訊息直到條件成立（最多 3 秒）
    fn pump_until(&mut self, pred: impl Fn(&Core) -> bool) {
        let deadline = Instant::now() + Duration::from_secs(3);
        while !pred(&self.core) {
            let left = deadline.saturating_duration_since(Instant::now());
            assert!(!left.is_zero(), "pump timeout, state = {:?}", self.core.snapshot().state);
            if let Ok(m) = self.rx.recv_timeout(left) {
                self.core.handle_internal(m, self.now);
                self.core.on_tick(self.now);
                self.core.flush(self.now);
            }
        }
    }

    fn pump_state(&mut self, s: PipelineState) {
        self.pump_until(move |c| c.snapshot().state == s);
    }

    /// 等所有背景工作送完（給「晚到的訊息要被丟棄」的測試）
    fn drain(&mut self) {
        while let Ok(m) = self.rx.recv_timeout(Duration::from_millis(200)) {
            self.core.handle_internal(m, self.now);
            self.core.on_tick(self.now);
            self.core.flush(self.now);
        }
    }

    fn events(&self) -> Vec<PipelineEvent> {
        self.events.try_iter().collect()
    }
}

fn toggle() -> PipelineCommand {
    PipelineCommand::ToggleRecording { mode: None }
}

// ───────────────────────── tests ─────────────────────────

#[test]
fn pipeline_happy_path_injects_and_saves_history() {
    let mut h = H::new(|_| {});
    h.cmd(toggle());
    assert_eq!(h.state(), PipelineState::Recording);
    assert_eq!(h.core.snapshot().generation, 1);
    assert_eq!(h.p.sinks.lock().as_slice(), [SINK_ID]);
    assert!(h.p.pushes.load(Ordering::SeqCst) > 0, "sink 要把音訊餵給 STT session");
    let ev = h.events();
    assert!(ev.iter().any(|e| matches!(e, PipelineEvent::RecordingStarted)));
    // 200 ms 後降音量
    h.advance(Duration::from_millis(250));
    assert_eq!(h.p.ducks.load(Ordering::SeqCst), 1);
    h.pump_until(|c| c.snapshot().raw_transcript == "部分");

    h.cmd(toggle());
    assert_eq!(h.state(), PipelineState::Processing);
    assert!(h.p.sinks.lock().is_empty());
    assert_eq!(h.p.restores.load(Ordering::SeqCst), 1);
    h.pump_until(|c| c.snapshot().state == PipelineState::Done && c.inject_cancel.is_none());

    let inj = h.p.injected.lock().clone();
    assert_eq!(inj, vec![("你好。".to_string(), Some(slack().bundle_id), true)]);
    let hist = h.p.history.lock().clone();
    assert_eq!(hist.len(), 1);
    assert_eq!(hist[0].raw_transcript, "你好");
    assert_eq!(hist[0].mode, "dictation");
    assert_eq!(h.core.snapshot().usage.total_tokens, 15);
    assert!(h.core.snapshot().cost_usd.is_some());
    assert!(h.events().iter().any(|e| matches!(e, PipelineEvent::Injected)));

    h.advance(Duration::from_millis(2100));
    assert_eq!(h.state(), PipelineState::Idle);
}

#[test]
fn pipeline_start_ignored_while_recording_or_processing() {
    let mut h = H::new(|_| {});
    h.p.refine_block.store(true, Ordering::SeqCst);
    h.cmd(PipelineCommand::StartRecording { mode: None, expected_target: None });
    let g = h.core.snapshot().generation;
    h.cmd(PipelineCommand::StartRecording { mode: None, expected_target: None });
    assert_eq!(h.core.snapshot().generation, g);
    assert_eq!(h.state(), PipelineState::Recording);

    h.cmd(PipelineCommand::StopRecording);
    h.pump_until(|c| c.processing_cancel.is_some());
    h.cmd(PipelineCommand::StartRecording { mode: None, expected_target: None });
    h.cmd(toggle());
    assert_eq!(h.state(), PipelineState::Processing);
    assert_eq!(h.core.snapshot().generation, g);
}

#[test]
fn pipeline_cancel_during_processing_returns_idle_without_error() {
    let mut h = H::new(|_| {});
    h.p.refine_block.store(true, Ordering::SeqCst);
    h.cmd(toggle());
    h.cmd(toggle());
    h.pump_until(|c| c.processing_cancel.is_some());
    let g = h.core.snapshot().generation;
    h.cmd(PipelineCommand::CancelRecording);
    assert_eq!(h.state(), PipelineState::Idle);
    assert_eq!(h.core.snapshot().generation, g + 1);
    // refine 收到取消後回 Cancelled，晚到的結果要被丟掉
    h.drain();
    assert_eq!(h.state(), PipelineState::Idle);
    assert!(h.p.injected.lock().is_empty());
    assert!(!h.core.snapshot().can_retry);
}

#[test]
fn pipeline_late_callbacks_from_old_generation_are_dropped() {
    let mut h = H::new(|_| {});
    h.cmd(toggle());
    let (old_gen, old_job) = (h.core.gen, h.core.job);
    h.cmd(PipelineCommand::CancelRecording);
    h.drain();
    h.cmd(toggle());
    h.core.handle_internal(Internal::SttPartial { gen: old_gen, job: old_job, text: "舊的".into() }, h.now);
    h.core.handle_internal(
        Internal::RefineDone { gen: old_gen, job: old_job + 2, result: Ok(text_result("舊結果")) },
        h.now,
    );
    assert_eq!(h.state(), PipelineState::Recording);
    assert_ne!(h.core.snapshot().raw_transcript, "舊的");
    assert!(h.p.injected.lock().is_empty());
}

#[test]
fn pipeline_terminal_forces_preview_without_auto_confirm() {
    let mut h = H::new(|s| s.enable_smart_send = true);
    *h.p.fg.lock() = AppContext { app_name: "Terminal".into(), bundle_id: "com.apple.Terminal".into(), ..Default::default() };
    h.p.refine_results.lock().push_back(Ok(text_result("ls -la\n")));
    h.cmd(toggle());
    h.cmd(toggle());
    h.pump_state(PipelineState::Previewing);
    assert_eq!(h.core.snapshot().processed_text, "ls -la");
    h.advance(Duration::from_secs(600));
    assert_eq!(h.state(), PipelineState::Previewing);
    assert!(h.p.injected.lock().is_empty());

    // 使用者確認 → 注入（不比對前景）→ 不 Smart Send
    h.cmd(PipelineCommand::ConfirmInject);
    h.pump_until(|c| c.inject_cancel.is_none() && c.snapshot().state == PipelineState::Done);
    assert_eq!(h.p.injected.lock()[0].1, None);
    h.advance(Duration::from_secs(5));
    assert_eq!(h.state(), PipelineState::Idle);
    assert!(h.p.enters.lock().is_empty());
}

#[test]
fn pipeline_preview_auto_confirm_after_timeout() {
    let mut h = H::new(|s| {
        s.enable_preview_before_inject = true;
        s.preview_timeout_secs = 5.0;
    });
    h.cmd(toggle());
    h.cmd(toggle());
    h.pump_state(PipelineState::Previewing);
    h.advance(Duration::from_secs(4));
    assert_eq!(h.state(), PipelineState::Previewing);
    h.advance(Duration::from_millis(1100));
    h.pump_until(|c| c.inject_cancel.is_none() && c.snapshot().state == PipelineState::Done);
    // 自動確認要比對前景
    assert_eq!(h.p.injected.lock()[0].1.as_deref(), Some("com.tinyspeck.slackmacgap"));
}

#[test]
fn pipeline_foreground_changed_falls_back_to_preview() {
    let mut h = H::new(|s| s.enable_smart_send = true);
    h.p.inject_results.lock().push_back(Err(InjectError::ForegroundChanged));
    h.cmd(toggle());
    h.cmd(toggle());
    h.pump_state(PipelineState::Previewing);
    assert!(h.events().iter().any(|e| matches!(e, PipelineEvent::Toast { .. })));
    h.advance(Duration::from_secs(600));
    assert_eq!(h.state(), PipelineState::Previewing, "前景換過不能自動確認");

    h.cmd(PipelineCommand::ConfirmInject);
    h.pump_until(|c| c.inject_cancel.is_none() && c.snapshot().state == PipelineState::Done);
    assert_eq!(h.p.injected.lock().len(), 2);
    assert_eq!(h.p.injected.lock()[1].1, None);
    // 前景換過的那次不 Smart Send
    h.advance(Duration::from_secs(10));
    assert!(h.p.enters.lock().is_empty());
    assert_eq!(h.state(), PipelineState::Idle);
}

#[test]
fn pipeline_smart_send_countdown_sends_enter() {
    let mut h = H::new(|s| {
        s.enable_smart_send = true;
        s.smart_send_delay_secs = 1.5;
    });
    *h.p.typing_secs.lock() = 0.15;
    h.cmd(toggle());
    h.cmd(toggle());
    h.pump_until(|c| c.smart_send_pending_at.is_some());
    h.advance(Duration::from_millis(200));
    assert!(matches!(h.state(), PipelineState::Confirming { remaining_secs } if (remaining_secs - 1.5).abs() < 0.01));
    h.advance(Duration::from_millis(700));
    assert!(matches!(h.state(), PipelineState::Confirming { remaining_secs } if remaining_secs < 1.0));
    h.advance(Duration::from_millis(900));
    assert_eq!(h.state(), PipelineState::Done);
    h.pump_until(|c| c.auto_reset_at.is_some());
    assert_eq!(h.p.enters.lock().as_slice(), [Some("com.tinyspeck.slackmacgap".to_string())]);
    h.advance(Duration::from_millis(1100));
    assert_eq!(h.state(), PipelineState::Idle);
}

#[test]
fn pipeline_smart_send_cancelled_by_voice_or_foreground_change() {
    // 說話取消
    let mut h = H::new(|s| {
        s.enable_smart_send = true;
        s.smart_send_delay_secs = 3.0;
    });
    h.cmd(toggle());
    h.cmd(toggle());
    h.pump_until(|c| c.smart_send_pending_at.is_some() || matches!(c.snapshot().state, PipelineState::Confirming { .. }));
    h.advance(Duration::from_millis(10));
    assert!(matches!(h.state(), PipelineState::Confirming { .. }));
    *h.p.level.lock() = 0.5;
    h.advance(Duration::from_millis(100));
    assert_eq!(h.state(), PipelineState::Done);
    h.advance(Duration::from_secs(5));
    assert!(h.p.enters.lock().is_empty());
    assert_eq!(h.state(), PipelineState::Idle);

    // 送 Enter 前前景已換
    let mut h = H::new(|s| {
        s.enable_smart_send = true;
        s.smart_send_delay_secs = 1.0;
    });
    h.cmd(toggle());
    h.cmd(toggle());
    h.pump_until(|c| c.smart_send_pending_at.is_some() || matches!(c.snapshot().state, PipelineState::Confirming { .. }));
    h.advance(Duration::from_millis(10));
    *h.p.fg.lock() = AppContext { app_name: "Discord".into(), bundle_id: "com.hnc.Discord".into(), ..Default::default() };
    h.advance(Duration::from_millis(1100));
    assert_eq!(h.state(), PipelineState::Done);
    h.drain();
    assert!(h.p.enters.lock().is_empty());
}

#[test]
fn pipeline_action_preview_auto_cancels_and_confirm_executes() {
    let action = PendingAction::Reminder { title: "買牛奶".into(), due: None, notes: None };
    let mk = |a: &PendingAction| RefineResult {
        outcome: RefineOutcome::Action { action: a.clone(), confirmation: "已建立提醒：買牛奶".into() },
        usage: TokenUsage::default(),
        model: "m".into(),
    };
    let mut h = H::new(|s| s.preview_timeout_secs = 5.0);
    h.p.refine_results.lock().push_back(Ok(mk(&action)));
    h.cmd(toggle());
    h.cmd(toggle());
    h.pump_state(PipelineState::Previewing);
    assert_eq!(h.core.snapshot().pending_action, Some(action.clone()));
    h.advance(Duration::from_secs(6));
    assert_eq!(h.state(), PipelineState::Idle, "動作預覽逾時是自動取消");
    assert_eq!(h.p.actions.load(Ordering::SeqCst), 0);
    assert!(h.p.injected.lock().is_empty());

    h.p.refine_results.lock().push_back(Ok(mk(&action)));
    h.cmd(toggle());
    h.cmd(toggle());
    h.pump_state(PipelineState::Previewing);
    h.cmd(PipelineCommand::ConfirmAction);
    assert_eq!(h.state(), PipelineState::Processing);
    h.pump_until(|c| c.inject_cancel.is_none() && c.snapshot().state == PipelineState::Done);
    assert_eq!(h.p.actions.load(Ordering::SeqCst), 1);
    assert_eq!(h.p.injected.lock()[0].0, "已建立行程");
    assert_eq!(h.core.snapshot().pending_action, None);
}

#[test]
fn pipeline_max_recording_and_silence_auto_stop() {
    let mut h = H::new(|s| s.max_recording_secs = 10);
    h.cmd(PipelineCommand::StartRecording { mode: None, expected_target: None });
    h.advance(Duration::from_secs(9));
    assert_eq!(h.state(), PipelineState::Recording);
    h.advance(Duration::from_millis(1100));
    assert_eq!(h.state(), PipelineState::Processing);
    h.pump_state(PipelineState::Done);

    // StartRecording（按住模式）不做靜音自動停止；Toggle 才做
    let mut h = H::new(|_| {});
    h.p.silence_fire.store(true, Ordering::SeqCst);
    h.cmd(PipelineCommand::StartRecording { mode: None, expected_target: None });
    h.advance(Duration::from_millis(100));
    assert_eq!(h.state(), PipelineState::Recording);
    h.cmd(PipelineCommand::CancelRecording);
    h.cmd(toggle());
    h.advance(Duration::from_millis(100));
    assert_eq!(h.state(), PipelineState::Processing);
}

#[test]
fn pipeline_llm_error_then_retry() {
    let mut h = H::new(|_| {});
    h.p.refine_results.lock().push_back(Err(LlmError::Http { status: 500, detail: String::new() }.into()));
    h.cmd(toggle());
    h.cmd(toggle());
    h.pump_until(|c| matches!(c.snapshot().state, PipelineState::Error(_)));
    assert_eq!(h.state(), PipelineState::Error("伺服器暫時不可用".into()));
    assert!(h.core.snapshot().can_retry);
    h.cmd(PipelineCommand::RetryLastAction);
    assert_eq!(h.state(), PipelineState::Processing);
    h.pump_until(|c| c.inject_cancel.is_none() && c.snapshot().state == PipelineState::Done);
    assert_eq!(h.p.refine_calls.load(Ordering::SeqCst), 2);
    // 舊的 autoReset 不能把重試結果打回 idle 以外的地方；Done 之後 2 秒回 idle
    h.advance(Duration::from_millis(2100));
    assert_eq!(h.state(), PipelineState::Idle);
}

#[test]
fn pipeline_prerequisite_failures() {
    let mut h = H::new(|_| {});
    *h.p.api_key.lock() = None;
    h.cmd(toggle());
    assert!(matches!(h.state(), PipelineState::Error(m) if m.contains("API Key")));
    h.advance(Duration::from_millis(3100));
    assert_eq!(h.state(), PipelineState::Idle);

    // 本地服務不需要 key
    let mut h = H::new(|s| s.selected_provider_id = "ollama".into());
    *h.p.api_key.lock() = None;
    h.cmd(toggle());
    assert_eq!(h.state(), PipelineState::Recording);

    let mut h = H::new(|_| {});
    *h.p.stt_unavailable.lock() = Some("SenseVoice 模型未下載".into());
    h.cmd(toggle());
    assert_eq!(h.state(), PipelineState::Error("SenseVoice 模型未下載".into()));

    let mut h = H::new(|_| {});
    h.p.audio_ok.store(false, Ordering::SeqCst);
    h.cmd(toggle());
    assert!(matches!(h.state(), PipelineState::Error(m) if m.contains("麥克風")));
}

#[test]
fn pipeline_listening_triggers_and_stops_on_error() {
    let mut h = H::new(|_| {});
    h.cmd(PipelineCommand::StartListening);
    assert_eq!(h.state(), PipelineState::Listening);
    *h.p.level.lock() = 0.5;
    h.advance(Duration::from_millis(100));
    assert_eq!(h.state(), PipelineState::Listening, "剛進聆聽有緩衝期");
    h.advance(Duration::from_millis(500));
    assert_eq!(h.state(), PipelineState::Recording);
    *h.p.level.lock() = 0.0;
    h.p.silence_fire.store(true, Ordering::SeqCst);
    h.advance(Duration::from_millis(100));
    assert_eq!(h.state(), PipelineState::Processing);
    h.pump_until(|c| c.inject_cancel.is_none() && c.snapshot().state == PipelineState::Done);
    h.advance(Duration::from_millis(2100));
    assert_eq!(h.state(), PipelineState::Listening, "完成後回到聆聽");

    // 空轉錄連續 3 次就停止聆聽
    *h.p.transcript.lock() = String::new();
    for i in 0..3 {
        *h.p.level.lock() = 0.5;
        h.advance(Duration::from_millis(600));
        assert_eq!(h.state(), PipelineState::Recording, "round {i}");
        h.advance(Duration::from_millis(100));
        h.pump_until(|c| !matches!(c.snapshot().state, PipelineState::Processing));
    }
    assert!(matches!(h.state(), PipelineState::Error(_)));
    h.advance(Duration::from_millis(3100));
    assert_eq!(h.state(), PipelineState::Idle);
    assert!(!h.core.listening_enabled);
}

#[test]
fn pipeline_settings_change_cancels_recording_and_rebuilds_engine() {
    let mut h = H::new(|_| {});
    h.cmd(toggle());
    let mut s = (*h.core.settings).clone();
    s.stt_engine = SttEngineKind::CloudWhisper;
    h.cmd(PipelineCommand::SettingsChanged(Arc::new(s.clone())));
    assert_eq!(h.state(), PipelineState::Idle);
    assert_eq!(h.p.rebuilds.load(Ordering::SeqCst), 1);
    assert!(h.p.sinks.lock().is_empty());
    // 與辨識無關的設定不重建
    s.enable_smart_send = true;
    h.cmd(PipelineCommand::SettingsChanged(Arc::new(s)));
    assert_eq!(h.p.rebuilds.load(Ordering::SeqCst), 1);
}

#[test]
fn pipeline_expected_target_and_mode_used() {
    let mut h = H::new(|_| {});
    let target = AppContext { app_name: "Mail".into(), bundle_id: "com.apple.mail".into(), ..Default::default() };
    let mode = default_voice_modes().remove(0);
    h.cmd(PipelineCommand::StartRecording { mode: Some(mode.clone()), expected_target: Some(target.clone()) });
    assert_eq!(h.core.snapshot().mode_name.as_deref(), Some(mode.name.as_str()));
    h.cmd(PipelineCommand::StopRecording);
    h.pump_until(|c| c.inject_cancel.is_none() && c.snapshot().state == PipelineState::Done);
    let inj = h.p.injected.lock()[0].clone();
    assert_eq!(inj.1.as_deref(), Some("com.apple.mail"));
    assert!(!inj.2, "Email 不是聊天，換行不用 Shift");
    assert_eq!(h.p.history.lock()[0].mode, mode.name);
}

#[test]
fn pipeline_needs_selection_and_empty_transcript() {
    let mut h = H::new(|_| {});
    h.p.refine_results.lock().push_back(Ok(RefineResult {
        outcome: RefineOutcome::NeedsSelection("請先選取要改寫的文字".into()),
        usage: TokenUsage::default(),
        model: "m".into(),
    }));
    h.cmd(toggle());
    h.cmd(toggle());
    h.pump_until(|c| matches!(c.snapshot().state, PipelineState::Error(_)));
    assert_eq!(h.core.snapshot().processed_text, "請先選取要改寫的文字");

    let mut h = H::new(|_| {});
    *h.p.transcript.lock() = "   ".into();
    h.cmd(toggle());
    h.cmd(toggle());
    h.pump_state(PipelineState::Idle);
    assert_eq!(h.p.refine_calls.load(Ordering::SeqCst), 0);
}

#[test]
fn pipeline_language_mapping() {
    let mut s = Settings::default();
    assert_eq!(stt_language(&s), "zh");
    s.language_preference = "ja-JP".into();
    assert_eq!(stt_language(&s), "ja");
    s.auto_language_detection = true;
    assert_eq!(stt_language(&s), "auto");
}

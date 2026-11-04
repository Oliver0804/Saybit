//! 狀態機與流程（批次 C2；移植 VoicePipeline.swift）。
//! 自己的執行緒：收 PipelineCommand → 操作 audio / stt / llm / inject / storage / ducking → 更新 snapshot、送 PipelineEvent。
//! 不變量（見 docs/CODE-REVIEW-2026-11-03.md）：generation 作廢舊回呼；Recording/Processing 時忽略 Start；
//! Processing 也能 Cancel；注入前與 Smart Send 前比對前景 App；終端機強制預覽不自動送出；錄音上限自動停止。
mod core;

use self::core::{Core, Internal, Local, Shared, SILENCE_THRESHOLD};
use crate::inject::InjectError;
use crate::llm::client::LlmClient;
use crate::llm::refiner::{RefineRequest, RefineResult};
use crate::logging::log;
use crate::storage::Storage;
use crate::types::*;
use parking_lot::RwLock;
use std::sync::Arc;
use std::time::Instant;

pub struct PipelineDeps {
    pub settings: Settings,
    pub repaint: RepaintFn,
}

/// 建立 pipeline 執行緒並回把手。GUI 之後只透過把手互動。
/// 執行緒內建立 AudioEngine / STT 引擎 / LLM client / Storage / ModelManager；
/// 用 `select!` 同時處理 GUI 命令、背景工作結果與計時器（音量 ~15 Hz、預覽逾時、Smart Send、autoReset、錄音上限）。
pub fn spawn(deps: PipelineDeps) -> anyhow::Result<PipelineHandle> {
    let (cmd_tx, cmd_rx) = crossbeam_channel::unbounded::<PipelineCommand>();
    let (ev_tx, ev_rx) = crossbeam_channel::unbounded::<PipelineEvent>();
    let snapshot = Arc::new(RwLock::new(PipelineSnapshot::default()));
    let handle = PipelineHandle { commands: cmd_tx, events: ev_rx, snapshot: snapshot.clone() };

    std::thread::Builder::new().name("saybit-pipeline".into()).spawn(move || {
        let settings = Arc::new(deps.settings);
        crate::ducking::restore_pending_if_needed();

        let storage = Storage::open().unwrap_or_else(|e| {
            log(LogLevel::Error, "Storage", format!("資料庫無法開啟（{e}），本次改用記憶體資料庫"));
            Storage::open_in_memory().expect("in-memory sqlite")
        });
        if settings.enable_history_auto_cleanup {
            match storage.delete_history_older_than(settings.history_retention_days) {
                Ok(n) if n > 0 => log(LogLevel::Info, "History", format!("已清理 {n} 筆過期歷史")),
                Err(e) => log(LogLevel::Error, "History", format!("清理歷史失敗：{e}")),
                _ => {}
            }
        }
        let shared: Arc<dyn Shared> = Arc::new(RealShared { llm: LlmClient::new(), storage });
        let mut local = RealLocal::new(&settings);
        if let Err(e) = local.audio_start(&settings) {
            log(LogLevel::Error, "Audio", format!("麥克風啟動失敗：{e}"));
        }
        log(
            LogLevel::Info,
            "Pipeline",
            format!(
                "Pipeline 初始化（模型 {}、風格 {:?}、辨識 {:?}）",
                settings.selected_model, settings.prompt_style, settings.stt_engine
            ),
        );

        let (int_tx, int_rx) = crossbeam_channel::unbounded::<Internal>();
        let mut core = Core::new(settings.clone(), Box::new(local), shared, int_tx, ev_tx, snapshot, deps.repaint);
        core.preload_stt();
        core.flush(Instant::now());

        loop {
            let timeout = core.next_timeout(Instant::now());
            crossbeam_channel::select! {
                recv(cmd_rx) -> msg => match msg {
                    Ok(cmd) => {
                        if !core.handle_command(cmd, Instant::now()) {
                            core.flush(Instant::now());
                            break;
                        }
                    }
                    // GUI 把手全丟了：收尾結束
                    Err(_) => {
                        core.handle_command(PipelineCommand::Shutdown, Instant::now());
                        break;
                    }
                },
                recv(int_rx) -> msg => {
                    if let Ok(m) = msg {
                        core.handle_internal(m, Instant::now());
                    }
                },
                default(timeout) => {},
            }
            let now = Instant::now();
            core.on_tick(now);
            core.flush(now);
        }
    })?;
    Ok(handle)
}

struct RealLocal {
    audio: crate::audio::AudioEngine,
    stt: Arc<dyn SttEngine>,
    models: crate::models::ModelManager,
}

fn make_stt(settings: &Settings) -> Arc<dyn SttEngine> {
    Arc::from(crate::stt::make_engine(settings.stt_engine, settings, &crate::secure_store::get))
}

impl RealLocal {
    fn new(settings: &Settings) -> Self {
        RealLocal { audio: crate::audio::AudioEngine::new(), stt: make_stt(settings), models: crate::models::ModelManager::new() }
    }
}

impl Local for RealLocal {
    fn audio_running(&self) -> bool {
        self.audio.is_running()
    }
    fn audio_start(&mut self, s: &Settings) -> anyhow::Result<()> {
        self.audio.start(s.input_device_id.as_deref(), s.enable_voice_bandpass, s.mic_sensitivity)
    }
    fn audio_stop(&mut self) {
        self.audio.stop();
    }
    fn audio_level(&self) -> f32 {
        self.audio.level()
    }
    fn add_sink(&self, id: &str, sink: AudioChunkSink, replay_prebuffer: bool) {
        self.audio.add_sink(id, sink, replay_prebuffer);
    }
    fn remove_sink(&self, id: &str) {
        self.audio.remove_sink(id);
    }
    fn stt(&self) -> Arc<dyn SttEngine> {
        self.stt.clone()
    }
    fn rebuild_stt(&mut self, s: &Settings) {
        self.stt = make_stt(s);
    }
    fn sense_voice_installed(&self) -> bool {
        self.models.state(ModelKind::SenseVoice) == ModelState::Installed
    }
    fn foreground_app(&self) -> AppContext {
        crate::platform::foreground_app()
    }
    fn selected_text(&self, ctx: &AppContext) -> Option<String> {
        crate::platform::selected_text(ctx)
    }
    fn refocus_last_external(&self) {
        crate::platform::refocus_last_external_if_self_front();
    }
    fn duck(&self, ratio: f32) {
        if let Err(e) = crate::ducking::duck(ratio) {
            log(LogLevel::Warn, "Audio", format!("降低系統音量失敗：{e}"));
        }
    }
    fn restore_duck(&self) {
        if let Err(e) = crate::ducking::restore() {
            log(LogLevel::Warn, "Audio", format!("還原系統音量失敗：{e}"));
        }
    }
    fn silence_detector(&self, timeout_secs: f32) -> Box<dyn FnMut(f32) -> bool> {
        let mut d = crate::audio::silence::SilenceDetector::new(timeout_secs, SILENCE_THRESHOLD);
        d.start();
        Box::new(move |level| d.update(level))
    }
}

struct RealShared {
    llm: LlmClient,
    storage: Storage,
}

impl Shared for RealShared {
    fn api_key(&self, provider_id: &str) -> Option<String> {
        crate::secure_store::get(&crate::secure_store::llm_account(provider_id))
    }
    fn refine(
        &self,
        settings: &Settings,
        api_key: Option<&str>,
        req: &RefineRequest,
        cancel: &CancelToken,
        on_partial: &mut dyn FnMut(&str),
    ) -> anyhow::Result<RefineResult> {
        crate::llm::refiner::refine(&self.llm, settings, api_key, req, cancel, on_partial)
    }
    fn inject(
        &self,
        text: &str,
        mode: InjectionMode,
        expected_bundle_id: Option<&str>,
        newline_with_shift: bool,
        cancel: &CancelToken,
    ) -> Result<(), InjectError> {
        crate::inject::inject_text(text, mode, expected_bundle_id, newline_with_shift, cancel)
    }
    fn simulate_enter(&self, expected_bundle_id: Option<&str>) -> Result<(), InjectError> {
        crate::inject::simulate_enter(expected_bundle_id)
    }
    fn estimated_duration_secs(&self, text: &str, mode: InjectionMode) -> f32 {
        crate::inject::estimated_duration_secs(text, mode)
    }
    fn cancel_typing(&self) {
        crate::inject::cancel_typing();
    }
    fn execute_action(&self, action: &PendingAction) -> anyhow::Result<String> {
        crate::platform::execute_action(action)
    }
    fn dictionary(&self) -> Vec<DictionaryEntry> {
        self.storage.dictionary().unwrap_or_else(|e| {
            log(LogLevel::Error, "Storage", format!("讀取字典失敗：{e}"));
            Vec::new()
        })
    }
    fn skills(&self) -> Vec<Skill> {
        self.storage.skills().unwrap_or_else(|e| {
            log(LogLevel::Error, "Storage", format!("讀取技能失敗：{e}"));
            Vec::new()
        })
    }
    fn add_history(&self, rec: &HistoryRecord) {
        if let Err(e) = self.storage.add_history(rec) {
            log(LogLevel::Error, "History", format!("歷史記錄儲存失敗：{e}"));
        }
    }
}

//! 跨模組共用型別（契約）。各批次只能「新增」欄位／變體，不能改既有名稱；要改先在報告提出。
//! 行為定義以原生 macOS 版為準：`../../../speakertpyer/`（Swift）與 `../../../saybit-desktop/src/`（TS 移植版）。

use serde::{Deserialize, Serialize};
use std::sync::Arc;

// ───────────────────────────── 設定 ─────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "kebab-case")]
pub enum AppLanguage {
    #[default]
    ZhTw,
    ZhCn,
    En,
    Ja,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum SttEngineKind {
    /// sherpa-onnx SenseVoice（離線，三平台）
    #[default]
    SenseVoice,
    /// whisper.cpp（離線，三平台）
    WhisperLocal,
    /// OpenAI / Groq Whisper API
    CloudWhisper,
    /// 阿里雲百鍊 / 訊飛 RTASR WebSocket 串流
    Streaming,
    /// SFSpeechRecognizer（只有 macOS）
    Apple,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum HotkeyTriggerMode {
    #[default]
    Toggle,
    Hold,
    DoubleTap,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum InjectionMode {
    #[default]
    Paste,
    Keypress,
    ReplaceSelection,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum PromptStyle {
    #[default]
    Typeless,
    WisprFlow,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ToneStyle {
    #[default]
    Auto,
    Formal,
    Casual,
    VeryCasual,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum UrlSchemeDecision {
    #[default]
    Ask,
    Allow,
    Deny,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum StreamingProvider {
    #[default]
    Alibaba,
    Xunfei,
}

/// 語音模式：自己的指令與（可選）全域快捷鍵
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VoiceMode {
    pub id: String,
    pub name: String,
    pub instructions: String,
    /// global-hotkey 可解析的字串，例如 "Ctrl+Alt+E"；None = 沒有快捷鍵
    pub hotkey: Option<String>,
}

/// 依 App 覆寫語氣／加額外指令（移植 Models/ContextRule.swift）
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ContextRule {
    pub id: String,
    /// `AppContext::context_identifier` 的值（slack / mail / terminal / vscode…）或 bundle id
    pub app_identifier: String,
    pub tone_override: Option<ToneStyle>,
    pub extra_prompt: String,
    pub enabled: bool,
}

/// LLM 服務商（移植 Core/LLM/LLMProvider.swift）
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LlmProvider {
    pub id: String,
    pub name: String,
    /// chat/completions 完整 URL
    pub base_url: String,
    pub extra_headers: Vec<(String, String)>,
    pub key_placeholder: String,
    pub model_hint: String,
    pub is_built_in: bool,
    pub requires_api_key: bool,
}

/// 全部設定。存成 JSON（`paths::settings_file()`）。API key 不在這裡，走 `secure_store`。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub app_language: AppLanguage,
    /// 辨識／輸出語言偏好："zh-TW" | "zh-CN" | "en-US" | "ja-JP"
    pub language_preference: String,
    pub auto_language_detection: bool,

    // 快捷鍵
    pub hotkey: String,
    pub hotkey_trigger_mode: HotkeyTriggerMode,
    pub voice_modes: Vec<VoiceMode>,

    // 語音辨識
    pub stt_engine: SttEngineKind,
    pub input_device_id: Option<String>,
    pub mic_sensitivity: f32,
    pub enable_voice_bandpass: bool,
    pub enable_auto_stop: bool,
    pub silence_timeout_secs: f32,
    pub max_recording_secs: u32,
    pub enable_ducking: bool,
    pub enable_sound_feedback: bool,
    pub whisper_cloud_provider: String, // "openai" | "groq" | "custom"
    pub whisper_cloud_base_url: String,
    pub whisper_cloud_model: String,
    pub streaming_provider: StreamingProvider,
    pub apple_on_device_only: bool,

    // AI
    pub selected_provider_id: String,
    pub selected_model: String,
    pub custom_providers: Vec<LlmProvider>,
    pub lm_studio_base_url: String,
    pub prompt_style: PromptStyle,
    pub tone_style: ToneStyle,
    pub enable_context_awareness: bool,
    pub context_rules: Vec<ContextRule>,
    pub enable_whisper_mode: bool, // 嘈雜環境模式
    pub use_custom_llm_params: bool,
    pub llm_temperature: f32,
    pub llm_max_tokens: u32,
    pub llm_top_p: f32,

    // 輸出
    pub injection_mode: InjectionMode,
    pub enable_preview_before_inject: bool,
    pub preview_timeout_secs: f32,
    pub enable_smart_send: bool,
    pub smart_send_delay_secs: f32,

    // 介面 / 系統
    pub capsule_scale: f32,
    pub overlay_position: Option<(f32, f32)>,
    pub launch_at_login: bool,
    pub enable_auto_update_check: bool,
    pub last_update_check_at: Option<chrono::DateTime<chrono::Utc>>,
    pub available_update_tag: String,
    pub available_update_url: String,
    pub enable_history_auto_cleanup: bool,
    pub history_retention_days: u32,
    pub has_completed_onboarding: bool,
    pub url_scheme_decision: UrlSchemeDecision,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            app_language: AppLanguage::ZhTw,
            language_preference: "zh-TW".into(),
            auto_language_detection: false,
            hotkey: "Ctrl+Alt+Space".into(),
            hotkey_trigger_mode: HotkeyTriggerMode::Toggle,
            voice_modes: default_voice_modes(),
            stt_engine: SttEngineKind::SenseVoice,
            input_device_id: None,
            mic_sensitivity: 1.0,
            enable_voice_bandpass: true,
            enable_auto_stop: true,
            silence_timeout_secs: 2.0,
            max_recording_secs: 300,
            enable_ducking: true,
            enable_sound_feedback: true,
            whisper_cloud_provider: "openai".into(),
            whisper_cloud_base_url: "https://api.openai.com/v1".into(),
            whisper_cloud_model: "whisper-1".into(),
            streaming_provider: StreamingProvider::Alibaba,
            apple_on_device_only: false,
            selected_provider_id: "openrouter".into(),
            selected_model: "deepseek/deepseek-v4-flash".into(),
            custom_providers: Vec::new(),
            lm_studio_base_url: "http://localhost:1234/v1/chat/completions".into(),
            prompt_style: PromptStyle::Typeless,
            tone_style: ToneStyle::Auto,
            enable_context_awareness: true,
            context_rules: Vec::new(),
            enable_whisper_mode: false,
            use_custom_llm_params: false,
            llm_temperature: 0.3,
            llm_max_tokens: 2048,
            llm_top_p: 1.0,
            injection_mode: InjectionMode::Paste,
            enable_preview_before_inject: false,
            preview_timeout_secs: 5.0,
            enable_smart_send: false,
            smart_send_delay_secs: 3.0,
            capsule_scale: 1.0,
            overlay_position: None,
            launch_at_login: false,
            enable_auto_update_check: true,
            last_update_check_at: None,
            available_update_tag: String::new(),
            available_update_url: String::new(),
            enable_history_auto_cleanup: false,
            history_retention_days: 30,
            has_completed_onboarding: false,
            url_scheme_decision: UrlSchemeDecision::Ask,
        }
    }
}

/// 預設三個語音模式（內容照 speakertpyer/Models/VoiceMode.swift）
pub fn default_voice_modes() -> Vec<VoiceMode> {
    vec![
        VoiceMode {
            id: "email".into(),
            name: "Email".into(),
            instructions: "把內容整理成一封完整、有禮貌的 email：加上適當的開頭稱呼與結尾問候，段落分明，語氣專業但不生硬。".into(),
            hotkey: None,
        },
        VoiceMode {
            id: "translate-en".into(),
            name: "翻譯成英文".into(),
            instructions: "把內容翻譯成自然流暢的英文，只輸出英文譯文，不要解釋。".into(),
            hotkey: None,
        },
        VoiceMode {
            id: "bullets".into(),
            name: "條列筆記".into(),
            instructions: "把內容整理成條列式筆記：每點一行、以「- 」開頭，去掉贅字，保留所有重點與數字。".into(),
            hotkey: None,
        },
    ]
}

// ───────────────────────────── App 上下文 ─────────────────────────────

/// 錄音當下的前景 App（移植 Models/AppContext.swift）
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct AppContext {
    pub app_name: String,
    /// macOS bundle id；Windows exe 檔名；Linux WM_CLASS / comm；拿不到為空字串
    pub bundle_id: String,
    pub pid: Option<u32>,
    pub window_title: String,
    pub selected_text: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContextCategory {
    ChatMessaging,
    Email,
    CodeEditor,
    Terminal,
    Browser,
    Notes,
    Office,
    Other,
}

// ───────────────────────────── Pipeline ─────────────────────────────

#[derive(Debug, Clone, PartialEq)]
pub enum PipelineState {
    Idle,
    /// 聆聽模式：等語音觸發
    Listening,
    Recording,
    Processing,
    /// 等使用者確認（含 pending action）
    Previewing,
    Done,
    /// Smart Send 倒數
    Confirming { remaining_secs: f32 },
    Error(String),
}

/// 行事曆 / 提醒等「需要使用者確認」的動作（只有 macOS 會真的執行；其他平台顯示文字）
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum PendingAction {
    CalendarEvent { title: String, start: String, end: Option<String>, notes: Option<String> },
    Reminder { title: String, due: Option<String>, notes: Option<String> },
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct TokenUsage {
    pub prompt_tokens: u32,
    pub completion_tokens: u32,
    pub total_tokens: u32,
}

/// GUI 每一幀讀的快照（pipeline 執行緒寫、GUI 讀）
#[derive(Debug, Clone, PartialEq)]
pub struct PipelineSnapshot {
    pub state: PipelineState,
    pub generation: u64,
    pub raw_transcript: String,
    pub processed_text: String,
    /// 0..1，已套 mic_sensitivity
    pub audio_level: f32,
    pub recording_started_at: Option<std::time::Instant>,
    pub mode_name: Option<String>,
    pub app_context: AppContext,
    pub model_name: String,
    pub usage: TokenUsage,
    pub cost_usd: Option<f64>,
    pub pending_action: Option<PendingAction>,
    /// 最後一次錯誤可重試（有 transcript）
    pub can_retry: bool,
}

impl Default for PipelineSnapshot {
    fn default() -> Self {
        Self {
            state: PipelineState::Idle,
            generation: 0,
            raw_transcript: String::new(),
            processed_text: String::new(),
            audio_level: 0.0,
            recording_started_at: None,
            mode_name: None,
            app_context: AppContext::default(),
            model_name: String::new(),
            usage: TokenUsage::default(),
            cost_usd: None,
            pending_action: None,
            can_retry: false,
        }
    }
}

#[derive(Debug, Clone)]
pub enum PipelineCommand {
    StartRecording { mode: Option<VoiceMode>, expected_target: Option<AppContext> },
    StopRecording,
    ToggleRecording { mode: Option<VoiceMode> },
    CancelRecording,
    StartListening,
    CancelListening,
    /// 預覽中：使用者按「輸入」
    ConfirmInject,
    Regenerate,
    CancelPreview,
    /// 預覽中的 pending action：使用者按「建立」
    ConfirmAction,
    RetryLastAction,
    /// 設定已變更（整份新設定）
    SettingsChanged(Arc<Settings>),
    /// API key 變更（重新從 secure_store 讀）
    SecretsChanged,
    Shutdown,
}

#[derive(Debug, Clone)]
pub enum PipelineEvent {
    /// 狀態／文字／音量有變化（GUI 收到後讀 snapshot 並 repaint）
    SnapshotChanged,
    /// 給使用者的一句話（膠囊旁顯示 3 秒）
    Toast { text: String },
    /// 要求 GUI 顯示／隱藏膠囊
    OverlayVisibility(bool),
    /// 錄音開始（GUI 可播音效）
    RecordingStarted,
    RecordingStopped,
    /// 已注入文字（GUI 可播音效）
    Injected,
    /// 模型下載等長任務進度：0..1
    Progress { task: String, progress: f32 },
}

/// GUI 持有的 pipeline 控制把手
#[derive(Clone)]
pub struct PipelineHandle {
    pub commands: crossbeam_channel::Sender<PipelineCommand>,
    pub events: crossbeam_channel::Receiver<PipelineEvent>,
    pub snapshot: Arc<parking_lot::RwLock<PipelineSnapshot>>,
}

impl PipelineHandle {
    pub fn send(&self, cmd: PipelineCommand) {
        let _ = self.commands.send(cmd);
    }
    pub fn snapshot(&self) -> PipelineSnapshot {
        self.snapshot.read().clone()
    }
}

/// GUI 給 pipeline 的「叫醒我重畫」回呼
pub type RepaintFn = Arc<dyn Fn() + Send + Sync>;

// ───────────────────────────── STT ─────────────────────────────

pub type PartialCallback = Box<dyn Fn(String) + Send + Sync>;

/// 一次錄音的辨識 session。所有方法都在 pipeline 執行緒呼叫。
pub trait SttSession: Send {
    /// 16 kHz 單聲道 f32，每 ~100 ms 一包
    fn push(&mut self, samples: &[f32]);
    /// 等收尾並回最終文字（可阻塞數秒）
    fn finish(self: Box<Self>) -> anyhow::Result<String>;
    fn cancel(self: Box<Self>);
}

pub struct SttStartOptions {
    /// "auto" | "zh" | "en" | "ja" | "ko" | "yue"（各引擎自行對應）
    pub language: String,
    /// 字典偏好寫法，給有 initial prompt 的引擎
    pub hint_terms: Vec<String>,
    pub on_partial: Option<PartialCallback>,
}

pub trait SttEngine: Send + Sync {
    fn kind(&self) -> SttEngineKind;
    /// None = 可用；Some(原因) = 不可用（未裝模型、平台不支援、沒 key…）
    fn unavailable_reason(&self) -> Option<String>;
    fn start(&self, opts: SttStartOptions) -> anyhow::Result<Box<dyn SttSession>>;
}

// ───────────────────────────── 音訊 ─────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AudioDevice {
    pub id: String,
    pub name: String,
    pub is_default: bool,
}

/// 由 `audio::AudioEngine` 在擷取執行緒呼叫：16 kHz 單聲道、已套帶通與增益
pub type AudioChunkSink = Box<dyn FnMut(&[f32]) + Send>;

// ───────────────────────────── LLM ─────────────────────────────

#[derive(Debug, Clone, PartialEq)]
pub enum LlmStreamEvent {
    Delta(String),
    Usage(TokenUsage),
}

#[derive(Debug, Clone, Default)]
pub struct LlmRequestOptions {
    pub temperature: Option<f32>,
    pub max_tokens: Option<u32>,
    pub top_p: Option<f32>,
    /// 要求 JSON 物件（Stage 1 意圖分類）
    pub json_mode: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub enum RefineOutcome {
    Text(String),
    Action { action: PendingAction, confirmation: String },
    /// 指令需要選取文字但沒有
    NeedsSelection(String),
}

// ───────────────────────────── 儲存 ─────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HistoryRecord {
    pub id: i64,
    pub timestamp: chrono::DateTime<chrono::Utc>,
    pub raw_transcript: String,
    pub processed_text: String,
    pub app_name: String,
    pub mode: String, // "dictation" | "command" | mode name
    pub model_name: String,
    pub duration_secs: f32,
    pub prompt_tokens: u32,
    pub completion_tokens: u32,
    pub total_tokens: u32,
    pub cost_usd: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DictionaryEntry {
    pub id: i64,
    pub term: String,
    pub preferred: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Skill {
    pub id: i64,
    pub trigger: String,
    pub content: String,
}

// ───────────────────────────── 日誌 ─────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "UPPERCASE")]
pub enum LogLevel {
    Debug,
    Info,
    Warn,
    Error,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LogEntry {
    pub timestamp: chrono::DateTime<chrono::Utc>,
    pub level: LogLevel,
    pub category: String,
    pub message: String,
    /// 含轉錄 / 結果內容：落盤與匯出寫 `[內容已遮罩, N 字]`，記憶體保留原文給日誌頁
    pub sensitive: bool,
}

// ───────────────────────────── 檔案轉錄 ─────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TranscriptSegment {
    pub start: f64,
    pub end: f64,
    pub text: String,
}

// ───────────────────────────── 模型管理 ─────────────────────────────

#[derive(Debug, Clone, PartialEq)]
pub enum ModelState {
    NotInstalled,
    Downloading { progress: f32 },
    Installed,
    Failed(String),
    /// 這個平台 / 這個 build 沒有這個引擎
    Unsupported(String),
}

// ───────────────────────────── 取消 ─────────────────────────────

/// 跨執行緒取消旗標（LLM 串流、注入、下載、檔案轉錄共用）
#[derive(Debug, Clone, Default)]
pub struct CancelToken(Arc<std::sync::atomic::AtomicBool>);

impl CancelToken {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn cancel(&self) {
        self.0.store(true, std::sync::atomic::Ordering::SeqCst);
    }
    pub fn is_cancelled(&self) -> bool {
        self.0.load(std::sync::atomic::Ordering::SeqCst)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ModelKind {
    SenseVoice,
    WhisperLocal,
}

/// saybit://toggle|start|stop|cancel|settings[?mode=Name][&tab=…]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UrlCommand {
    pub command: String,
    pub mode: Option<String>,
    pub tab: Option<String>,
}

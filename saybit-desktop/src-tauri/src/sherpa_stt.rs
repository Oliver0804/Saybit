#![allow(dead_code)]
// 由 lib.rs 以 `mod sherpa_stt;` 引入。
// 命令：sensevoice_status / download_sensevoice_model / cancel_sensevoice_download /
//       delete_sensevoice_model / sensevoice_start / sensevoice_push / sensevoice_finish / sensevoice_cancel
// 事件：stt-partial { text }、sensevoice-model-progress { progress }
//
// 離線 STT：sherpa-onnx SenseVoice int8 + Silero VAD，移植自原生版
// ../speakertpyer/Core/SpeechRecognition/Sherpa/SherpaSTTEngine.swift。
// SenseVoice 不是串流模型：VAD 切句、每句講完就定稿；講話中每 0.8 秒把尚未定稿的尾段
// 重新辨識一次當即時字幕。sherpa 物件不是 thread-safe，全部只活在 worker 執行緒上；
// 命令只把訊息丟進 channel，不會卡住 IPC。
//
// macOS / Windows 靜態連結 sherpa-onnx；Linux 動態連結 .so（打包見 tauri.linux.conf.json、rpath 見 build.rs）。
// 其他平台命令回 Err(MSG_UNSUPPORTED)。

use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc, Mutex, OnceLock};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager};
use tokio::sync::oneshot;

pub const SAMPLE_RATE: usize = 16_000;
pub const MODEL_ID: &str = "sense-voice-zh-en-ja-ko-yue-int8-2025-09-09";

pub const MSG_MODEL_MISSING: &str = "尚未下載離線辨識模型（SenseVoice），請到設定下載";
pub const MSG_LOAD_FAILED: &str = "離線辨識模型載入失敗，請到設定刪除後重新下載";
pub const MSG_UNSUPPORTED: &str = "此平台尚未支援 SenseVoice 離線辨識";
/// 取消下載 / 取消檔案轉錄時回的錯誤字串（前端據此判斷不是真的失敗）
pub const ERR_CANCELLED: &str = "cancelled";

pub struct ModelFile {
    pub name: &'static str,
    pub url: &'static str,
    pub size: u64,
}

/// 下載來源與大小與原生版 SherpaModelManager.swift 相同；大小完全相符才算安裝完成
pub const MODEL_FILES: [ModelFile; 3] = [
    ModelFile {
        name: "model.int8.onnx",
        url: "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09/resolve/main/model.int8.onnx",
        size: 237_115_547,
    },
    ModelFile {
        name: "tokens.txt",
        url: "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09/resolve/main/tokens.txt",
        size: 315_894,
    },
    ModelFile {
        name: "silero_vad.onnx",
        url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx",
        size: 643_854,
    },
];

pub fn total_bytes() -> u64 {
    MODEL_FILES.iter().map(|f| f.size).sum()
}

#[derive(Clone, Debug, PartialEq)]
pub struct ModelPaths {
    pub model: PathBuf,
    pub tokens: PathBuf,
    pub vad: PathBuf,
}

impl ModelPaths {
    fn in_dir(dir: &Path) -> Self {
        Self {
            model: dir.join(MODEL_FILES[0].name),
            tokens: dir.join(MODEL_FILES[1].name),
            vad: dir.join(MODEL_FILES[2].name),
        }
    }
}

pub fn model_dir(app: &AppHandle) -> Result<PathBuf, String> {
    Ok(app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?
        .join("SherpaModels")
        .join(MODEL_ID))
}

fn file_size(path: &Path) -> Option<u64> {
    std::fs::metadata(path).ok().map(|m| m.len())
}

pub fn is_installed(dir: &Path) -> bool {
    MODEL_FILES
        .iter()
        .all(|f| file_size(&dir.join(f.name)) == Some(f.size))
}

/// 模型已完整安裝才回傳路徑；SenseVoice / VAD 建構時不檢查檔案，所以這裡一定要先擋
pub fn model_paths(app: &AppHandle) -> Result<ModelPaths, String> {
    let dir = model_dir(app)?;
    if !is_installed(&dir) {
        return Err(MSG_MODEL_MISSING.into());
    }
    Ok(ModelPaths::in_dir(&dir))
}

/// SenseVoice 語言提示：auto / zh / en / ja / ko / yue，其餘一律 auto
pub fn normalize_language(language: &str) -> String {
    let lang = language.trim().to_ascii_lowercase();
    match lang.as_str() {
        "zh" | "en" | "ja" | "ko" | "yue" => lang,
        _ => "auto".into(),
    }
}

// MARK: - 辨識後端（sherpa-rs）

pub struct VadSegment {
    /// 在 VAD 收到的整段音訊中的起點（16 kHz 取樣數）
    pub start: usize,
    pub samples: Vec<f32>,
}

pub trait SpeechDecoder {
    fn decode(&mut self, samples: &[f32]) -> String;
}

pub trait SpeechVad {
    fn accept(&mut self, samples: &[f32]);
    fn flush(&mut self);
    fn is_speech(&mut self) -> bool;
    fn pop_segments(&mut self) -> Vec<VadSegment>;
}

#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
mod backend {
    use super::{ModelPaths, SpeechDecoder, SpeechVad, VadSegment, MSG_LOAD_FAILED, SAMPLE_RATE};
    use sherpa_rs::sense_voice::{SenseVoiceConfig, SenseVoiceRecognizer};
    use sherpa_rs::silero_vad::{SileroVad, SileroVadConfig};

    pub const SUPPORTED: bool = true;
    pub const VAD_WINDOW: usize = 512;

    struct Recognizer(SenseVoiceRecognizer);

    impl SpeechDecoder for Recognizer {
        fn decode(&mut self, samples: &[f32]) -> String {
            if samples.is_empty() {
                return String::new();
            }
            self.0
                .transcribe(SAMPLE_RATE as u32, samples)
                .text
                .trim()
                .to_string()
        }
    }

    struct Vad(SileroVad);

    impl SpeechVad for Vad {
        fn accept(&mut self, samples: &[f32]) {
            if !samples.is_empty() {
                self.0.accept_waveform(samples.to_vec());
            }
        }
        fn flush(&mut self) {
            self.0.flush();
        }
        fn is_speech(&mut self) -> bool {
            self.0.is_speech()
        }
        fn pop_segments(&mut self) -> Vec<VadSegment> {
            let mut out = Vec::new();
            while !self.0.is_empty() {
                let seg = self.0.front();
                self.0.pop();
                out.push(VadSegment {
                    start: seg.start.max(0) as usize,
                    samples: seg.samples,
                });
            }
            out
        }
    }

    pub fn new_recognizer(
        paths: &ModelPaths,
        language: &str,
        num_threads: i32,
    ) -> Result<Box<dyn SpeechDecoder>, String> {
        let config = SenseVoiceConfig {
            model: paths.model.to_string_lossy().into_owned(),
            tokens: paths.tokens.to_string_lossy().into_owned(),
            language: language.to_string(),
            use_itn: true, // 加標點、數字正規化
            provider: Some("cpu".into()),
            num_threads: Some(num_threads),
            debug: false,
        };
        SenseVoiceRecognizer::new(config)
            .map(|r| Box::new(Recognizer(r)) as Box<dyn SpeechDecoder>)
            .map_err(|e| format!("{MSG_LOAD_FAILED}（{e}）"))
    }

    /// 參數同原生 SherpaVAD：threshold 0.5、min_speech 0.25、window 512、buffer 120 秒
    pub fn new_vad(
        paths: &ModelPaths,
        min_silence: f32,
        max_speech: f32,
    ) -> Result<Box<dyn SpeechVad>, String> {
        let config = SileroVadConfig {
            model: paths.vad.to_string_lossy().into_owned(),
            min_silence_duration: min_silence,
            min_speech_duration: 0.25,
            max_speech_duration: max_speech,
            threshold: 0.5,
            sample_rate: SAMPLE_RATE as u32,
            window_size: VAD_WINDOW as i32,
            provider: Some("cpu".into()),
            num_threads: Some(1),
            debug: false,
        };
        SileroVad::new(config, 120.0)
            .map(|v| Box::new(Vad(v)) as Box<dyn SpeechVad>)
            .map_err(|e| format!("{MSG_LOAD_FAILED}（{e}）"))
    }
}

#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
mod backend {
    use super::{ModelPaths, SpeechDecoder, SpeechVad, MSG_UNSUPPORTED};

    pub const SUPPORTED: bool = false;
    pub const VAD_WINDOW: usize = 512;

    pub fn new_recognizer(
        _paths: &ModelPaths,
        _language: &str,
        _num_threads: i32,
    ) -> Result<Box<dyn SpeechDecoder>, String> {
        Err(MSG_UNSUPPORTED.into())
    }

    pub fn new_vad(
        _paths: &ModelPaths,
        _min_silence: f32,
        _max_speech: f32,
    ) -> Result<Box<dyn SpeechVad>, String> {
        Err(MSG_UNSUPPORTED.into())
    }
}

pub use backend::{new_recognizer, new_vad, SUPPORTED, VAD_WINDOW};

// MARK: - 即時辨識邏輯（純邏輯，不碰 sherpa 型別，可單元測試）

/// 每 0.8 秒新音訊更新一次字幕
const PARTIAL_INTERVAL: usize = SAMPLE_RATE * 8 / 10;
/// 字幕最多重算最後 8 秒（長句不會越算越慢）
const MAX_PARTIAL_WINDOW: usize = SAMPLE_RATE * 8;
const PARTIAL_MIN_WALL: Duration = Duration::from_millis(800);
/// 一次處理超過 1 秒的音訊代表 worker 落後 → 這輪跳過字幕重算，先追上
const BEHIND_THRESHOLD: usize = SAMPLE_RATE;
/// VAD 一句都沒切到時，尾段 RMS 低於此值不辨識（否則 SenseVoice 對著底噪吐「嗯」）
pub const TAIL_RMS_MIN: f32 = 0.004;
const TAIL_MIN_SAMPLES: usize = SAMPLE_RATE * 3 / 10;
const TAIL_MAX_SAMPLES: usize = SAMPLE_RATE * 30;

#[derive(Default)]
pub struct LiveSession {
    samples: Vec<f32>,
    vad_fed: usize,
    committed: Vec<String>,
    committed_end: usize,
    last_partial_at: usize,
    last_partial_wall: Option<Instant>,
    partial: String,
}

impl LiveSession {
    pub fn push(&mut self, samples: &[f32]) {
        self.samples.extend_from_slice(samples);
    }

    /// 回傳 Some(累積文字) 表示字幕有變，需要送 stt-partial
    pub fn process(
        &mut self,
        decoder: &mut dyn SpeechDecoder,
        vad: &mut dyn SpeechVad,
        is_final: bool,
        allow_partial: bool,
        now: Instant,
    ) -> Option<String> {
        let len = self.samples.len();
        let whole = (len - self.vad_fed) / VAD_WINDOW * VAD_WINDOW;
        if whole > 0 {
            vad.accept(&self.samples[self.vad_fed..self.vad_fed + whole]);
            self.vad_fed += whole;
        }
        if is_final {
            if self.vad_fed < len {
                vad.accept(&self.samples[self.vad_fed..]);
                self.vad_fed = len;
            }
            vad.flush();
        }

        let mut changed = false;
        for seg in vad.pop_segments() {
            let text = decoder.decode(&seg.samples);
            if !text.is_empty() {
                self.committed.push(text);
            }
            self.committed_end = self.committed_end.max(seg.start + seg.samples.len());
            self.partial.clear();
            self.last_partial_at = len;
            changed = true;
        }

        if !is_final
            && allow_partial
            && vad.is_speech()
            && len - self.last_partial_at >= PARTIAL_INTERVAL
            && self
                .last_partial_wall
                .is_none_or(|t| now.saturating_duration_since(t) >= PARTIAL_MIN_WALL)
        {
            self.last_partial_at = len;
            self.last_partial_wall = Some(now);
            let from = self
                .committed_end
                .max(len.saturating_sub(MAX_PARTIAL_WINDOW));
            if from < len {
                self.partial = decoder.decode(&self.samples[from..]);
                changed = true;
            }
        }

        if changed && !is_final {
            let mut parts = self.committed.clone();
            if !self.partial.is_empty() {
                parts.push(self.partial.clone());
            }
            Some(render(&parts))
        } else {
            None
        }
    }

    /// flush VAD、辨識剩下的句子，回傳定稿全文
    pub fn finish(&mut self, decoder: &mut dyn SpeechDecoder, vad: &mut dyn SpeechVad) -> String {
        self.process(decoder, vad, true, false, Instant::now());
        // VAD 什麼都沒切到（例如很小聲）→ 尾段直接辨識一次，但幾乎沒聲音時不辨識
        if self.committed.is_empty() {
            let tail = &self.samples[self.samples.len().saturating_sub(TAIL_MAX_SAMPLES)..];
            if tail.len() > TAIL_MIN_SAMPLES && rms(tail) > TAIL_RMS_MIN {
                let text = decoder.decode(tail);
                if !text.is_empty() {
                    self.committed.push(text);
                }
            }
        }
        render(&self.committed)
    }
}

pub fn rms(x: &[f32]) -> f32 {
    if x.is_empty() {
        return 0.0;
    }
    let sum: f32 = x.iter().map(|v| v * v).sum();
    (sum / x.len() as f32).sqrt()
}

/// 近似 Swift `Character.isPunctuation`（Unicode P 類）：ASCII 標點 + 常見 CJK / 全形 / 一般標點區段
fn is_punctuation(c: char) -> bool {
    if c.is_ascii() {
        return matches!(
            c,
            '!' | '"'
                | '#'
                | '%'
                | '&'
                | '\''
                | '('
                | ')'
                | '*'
                | ','
                | '-'
                | '.'
                | '/'
                | ':'
                | ';'
                | '?'
                | '@'
                | '['
                | '\\'
                | ']'
                | '_'
                | '{'
                | '}'
        );
    }
    matches!(c as u32,
        0x2010..=0x2027 | 0x2030..=0x205E | 0x3001..=0x3003 | 0x3008..=0x3011 | 0x3014..=0x301F
        | 0xFE10..=0xFE19 | 0xFE30..=0xFE4F | 0xFE50..=0xFE6B
        | 0xFF01..=0xFF03 | 0xFF05..=0xFF0A | 0xFF0C..=0xFF0F | 0xFF1A | 0xFF1B | 0xFF1F | 0xFF20
        | 0xFF3B..=0xFF3D | 0xFF3F | 0xFF5B | 0xFF5D | 0xFF5F..=0xFF65)
}

/// 這版 SenseVoice 不一定輸出標點：句與句之間補分隔（ASCII 兩側用空白，其餘用「，」），讓 LLM 看得出斷句
pub fn render(parts: &[String]) -> String {
    let mut out = String::new();
    for part in parts {
        if let (Some(last), Some(first)) = (out.chars().last(), part.chars().next()) {
            if !is_punctuation(last) {
                out.push_str(if last.is_ascii() && first.is_ascii() {
                    " "
                } else {
                    "，"
                });
            }
        }
        out.push_str(part);
    }
    out
}

// MARK: - Worker 執行緒（持有所有 sherpa 物件）

struct StartRequest {
    gen: u64,
    app: AppHandle,
    paths: ModelPaths,
    language: String,
    reply: oneshot::Sender<Result<(), String>>,
}

enum Cmd {
    Start(Box<StartRequest>),
    Push {
        gen: u64,
        samples: Vec<f32>,
    },
    Finish {
        gen: u64,
        reply: oneshot::Sender<Result<String, String>>,
    },
    Cancel,
    /// 刪除模型時釋放記憶體（約 250 MB）
    Unload,
}

/// 每次 start / cancel 遞增；舊 session 排隊中的音訊比對不符就丟棄
static SESSION_GEN: AtomicU64 = AtomicU64::new(0);
static WORKER: OnceLock<Mutex<mpsc::Sender<Cmd>>> = OnceLock::new();

fn send(cmd: Cmd) -> Result<(), String> {
    let tx = WORKER.get_or_init(|| {
        let (tx, rx) = mpsc::channel();
        std::thread::Builder::new()
            .name("sensevoice-worker".into())
            .spawn(move || worker_loop(rx))
            .expect("spawn sensevoice worker");
        Mutex::new(tx)
    });
    tx.lock()
        .map_err(|e| e.to_string())?
        .send(cmd)
        .map_err(|_| "SenseVoice 背景執行緒已停止".to_string())
}

struct Loaded {
    paths: ModelPaths,
    language: String,
    recognizer: Box<dyn SpeechDecoder>,
}

struct Active {
    gen: u64,
    app: AppHandle,
    vad: Box<dyn SpeechVad>,
    session: LiveSession,
}

fn worker_loop(rx: mpsc::Receiver<Cmd>) {
    let mut loaded: Option<Loaded> = None;
    let mut active: Option<Active> = None;
    let mut pending: Option<Cmd> = None;

    loop {
        let cmd = match pending.take() {
            Some(c) => c,
            None => match rx.recv() {
                Ok(c) => c,
                Err(_) => return,
            },
        };
        match cmd {
            Cmd::Start(req) => {
                let StartRequest {
                    gen,
                    app,
                    paths,
                    language,
                    reply,
                } = *req;
                active = None;
                let need_load = loaded
                    .as_ref()
                    .is_none_or(|l| l.paths != paths || l.language != language);
                if need_load {
                    loaded = None; // 先釋放舊的，避免兩份模型同時在記憶體
                    match new_recognizer(&paths, &language, 2) {
                        Ok(recognizer) => {
                            loaded = Some(Loaded {
                                paths: paths.clone(),
                                language,
                                recognizer,
                            })
                        }
                        Err(e) => {
                            let _ = reply.send(Err(e));
                            continue;
                        }
                    }
                }
                // sherpa-rs 沒有包 VAD reset，每次錄音重建一個（silero 只有 640 KB，很快）
                match new_vad(&paths, 0.5, 20.0) {
                    Ok(vad) => {
                        active = Some(Active {
                            gen,
                            app,
                            vad,
                            session: LiveSession::default(),
                        });
                        let _ = reply.send(Ok(()));
                    }
                    Err(e) => {
                        let _ = reply.send(Err(e));
                    }
                }
            }
            Cmd::Push { gen, samples } => {
                let current = active.as_ref().map(|a| a.gen);
                let mut batch = if current == Some(gen) {
                    samples
                } else {
                    Vec::new()
                };
                // 合併已排隊的音訊：落後時一次追上，而不是每包都重算字幕
                loop {
                    match rx.try_recv() {
                        Ok(Cmd::Push {
                            gen: g,
                            samples: more,
                        }) => {
                            if current == Some(g) {
                                batch.extend_from_slice(&more);
                            }
                        }
                        Ok(other) => {
                            pending = Some(other);
                            break;
                        }
                        Err(_) => break,
                    }
                }
                let (Some(a), Some(l)) = (active.as_mut(), loaded.as_mut()) else {
                    continue;
                };
                if batch.is_empty() {
                    continue;
                }
                let behind = batch.len() > BEHIND_THRESHOLD;
                a.session.push(&batch);
                if let Some(text) = a.session.process(
                    l.recognizer.as_mut(),
                    a.vad.as_mut(),
                    false,
                    !behind,
                    Instant::now(),
                ) {
                    let _ = a
                        .app
                        .emit("stt-partial", serde_json::json!({ "text": text }));
                }
            }
            Cmd::Finish { gen, reply } => {
                let result = match (active.take(), loaded.as_mut()) {
                    (Some(mut a), Some(l)) if a.gen == gen => {
                        Ok(a.session.finish(l.recognizer.as_mut(), a.vad.as_mut()))
                    }
                    _ => Err("沒有進行中的 SenseVoice 辨識".to_string()),
                };
                let _ = reply.send(result);
            }
            Cmd::Cancel => active = None,
            Cmd::Unload => {
                active = None;
                loaded = None;
            }
        }
    }
}

// MARK: - 即時辨識命令

#[tauri::command]
pub async fn sensevoice_start(app: AppHandle, language: String) -> Result<(), String> {
    if !SUPPORTED {
        return Err(MSG_UNSUPPORTED.into());
    }
    let paths = model_paths(&app)?;
    let gen = SESSION_GEN.fetch_add(1, Ordering::SeqCst) + 1;
    let (tx, rx) = oneshot::channel();
    send(Cmd::Start(Box::new(StartRequest {
        gen,
        app,
        paths,
        language: normalize_language(&language),
        reply: tx,
    })))?;
    rx.await
        .map_err(|_| "SenseVoice 背景執行緒無回應".to_string())?
}

/// 16 kHz 單聲道 f32；只排進 channel，VAD / decode / stt-partial 都在 worker 做
#[tauri::command]
pub async fn sensevoice_push(samples: Vec<f32>) -> Result<(), String> {
    if samples.is_empty() {
        return Ok(());
    }
    send(Cmd::Push {
        gen: SESSION_GEN.load(Ordering::SeqCst),
        samples,
    })
}

#[tauri::command]
pub async fn sensevoice_finish() -> Result<String, String> {
    let (tx, rx) = oneshot::channel();
    send(Cmd::Finish {
        gen: SESSION_GEN.load(Ordering::SeqCst),
        reply: tx,
    })?;
    rx.await
        .map_err(|_| "SenseVoice 背景執行緒無回應".to_string())?
}

#[tauri::command]
pub async fn sensevoice_cancel() -> Result<(), String> {
    SESSION_GEN.fetch_add(1, Ordering::SeqCst);
    // worker 從未啟動過就不用特地叫起來
    if WORKER.get().is_some() {
        send(Cmd::Cancel)?;
    }
    Ok(())
}

// MARK: - 模型下載 / 刪除

/// 目前下載的識別碼；取消就清成 None，舊的下載在下一個 chunk 發現不符就自行收尾
static DOWNLOAD_TOKEN: Mutex<Option<u64>> = Mutex::new(None);
static DOWNLOAD_SEQ: AtomicU64 = AtomicU64::new(0);

fn download_active(token: u64) -> bool {
    DOWNLOAD_TOKEN
        .lock()
        .map(|g| *g == Some(token))
        .unwrap_or(false)
}

/// 進度 0..1：已完成檔案的位元組 + 目前檔案已寫入，除以總大小；完成前最多 0.999
pub fn download_progress(done_bytes: u64, written: u64, total: u64) -> f64 {
    if total == 0 {
        return 0.0;
    }
    ((done_bytes + written) as f64 / total as f64).clamp(0.0, 0.999)
}

fn emit_progress(app: &AppHandle, progress: f64) {
    let _ = app.emit(
        "sensevoice-model-progress",
        serde_json::json!({ "progress": progress }),
    );
}

#[tauri::command]
pub fn sensevoice_status(app: AppHandle) -> Result<serde_json::Value, String> {
    let dir = model_dir(&app)?;
    Ok(serde_json::json!({
        "installed": is_installed(&dir),
        "dir": dir.to_string_lossy(),
        "total_bytes": total_bytes(),
        // 契約外的附加欄位：不支援的平台為 false（UI 可藏起下載面板）
        "supported": SUPPORTED,
    }))
}

#[tauri::command]
pub async fn download_sensevoice_model(app: AppHandle) -> Result<(), String> {
    let dir = model_dir(&app)?;
    if is_installed(&dir) {
        emit_progress(&app, 1.0);
        return Ok(());
    }
    let token = {
        let mut guard = DOWNLOAD_TOKEN.lock().map_err(|e| e.to_string())?;
        if guard.is_some() {
            return Err("模型下載進行中".into());
        }
        let t = DOWNLOAD_SEQ.fetch_add(1, Ordering::SeqCst) + 1;
        *guard = Some(t);
        t
    };
    let result = download_all(&app, &dir, token).await;
    if let Ok(mut guard) = DOWNLOAD_TOKEN.lock() {
        if *guard == Some(token) {
            *guard = None;
        }
    }
    result
}

async fn download_all(app: &AppHandle, dir: &Path, token: u64) -> Result<(), String> {
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let client = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(15))
        .read_timeout(Duration::from_secs(60))
        .build()
        .map_err(|e| e.to_string())?;
    let total = total_bytes();
    let mut done = 0u64;
    emit_progress(app, 0.0);
    for file in MODEL_FILES.iter() {
        let dest = dir.join(file.name);
        if file_size(&dest) == Some(file.size) {
            done += file.size;
            continue;
        }
        fetch_file(app, &client, file, &dest, done, total, token).await?;
        done += file.size;
    }
    if !download_active(token) {
        return Err(ERR_CANCELLED.into());
    }
    if !is_installed(dir) {
        return Err("模型檔案大小不符，請重新下載".into());
    }
    emit_progress(app, 1.0);
    Ok(())
}

async fn fetch_file(
    app: &AppHandle,
    client: &reqwest::Client,
    file: &ModelFile,
    dest: &Path,
    done: u64,
    total: u64,
    token: u64,
) -> Result<(), String> {
    use futures_util::StreamExt;

    // 每次下載用自己的暫存檔：取消後立刻重新下載時，新舊兩個下載不會寫同一個檔
    let part = dest.with_file_name(format!("{}.{token}.part", file.name));
    let resp = client
        .get(file.url)
        .send()
        .await
        .map_err(|e| format!("下載請求失敗: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("下載 {} 失敗 HTTP {}", file.name, resp.status()));
    }

    let mut out = std::fs::File::create(&part).map_err(|e| e.to_string())?;
    let mut stream = resp.bytes_stream();
    let mut written = 0u64;
    let mut last_emit = Instant::now();
    let result: Result<(), String> = async {
        while let Some(chunk) = stream.next().await {
            if !download_active(token) {
                return Err(ERR_CANCELLED.into());
            }
            let chunk = chunk.map_err(|e| format!("下載中斷: {e}"))?;
            out.write_all(&chunk).map_err(|e| e.to_string())?;
            written += chunk.len() as u64;
            if written > file.size {
                return Err(format!("{} 大小不符", file.name));
            }
            if last_emit.elapsed() >= Duration::from_millis(200) {
                emit_progress(app, download_progress(done, written, total));
                last_emit = Instant::now();
            }
        }
        Ok(())
    }
    .await;
    drop(out);

    let result = result.and_then(|_| {
        if written != file.size {
            Err(format!(
                "{} 大小不符（{written} / {} bytes）",
                file.name, file.size
            ))
        } else if !download_active(token) {
            Err(ERR_CANCELLED.into())
        } else {
            Ok(())
        }
    });
    if let Err(e) = result {
        let _ = std::fs::remove_file(&part);
        return Err(e);
    }
    std::fs::rename(&part, dest).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn cancel_sensevoice_download() {
    if let Ok(mut guard) = DOWNLOAD_TOKEN.lock() {
        *guard = None;
    }
}

#[tauri::command]
pub async fn delete_sensevoice_model(app: AppHandle) -> Result<(), String> {
    cancel_sensevoice_download();
    SESSION_GEN.fetch_add(1, Ordering::SeqCst);
    if WORKER.get().is_some() {
        let _ = send(Cmd::Unload);
    }
    let dir = model_dir(&app)?;
    if dir.exists() {
        std::fs::remove_dir_all(&dir).map_err(|e| format!("刪除模型失敗: {e}"))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;

    /// 解碼結果用樣本數表示，方便驗證送進去的範圍
    #[derive(Default)]
    struct FakeDecoder {
        calls: Vec<usize>,
    }
    impl SpeechDecoder for FakeDecoder {
        fn decode(&mut self, samples: &[f32]) -> String {
            self.calls.push(samples.len());
            format!("s{}", samples.len())
        }
    }

    #[derive(Default)]
    struct FakeVad {
        fed: usize,
        speaking: bool,
        flushed: bool,
        queued: VecDeque<VadSegment>,
    }
    impl SpeechVad for FakeVad {
        fn accept(&mut self, samples: &[f32]) {
            self.fed += samples.len();
        }
        fn flush(&mut self) {
            self.flushed = true;
        }
        fn is_speech(&mut self) -> bool {
            self.speaking
        }
        fn pop_segments(&mut self) -> Vec<VadSegment> {
            self.queued.drain(..).collect()
        }
    }

    fn tone(n: usize, amp: f32) -> Vec<f32> {
        (0..n).map(|i| amp * (i as f32 * 0.3).sin()).collect()
    }

    #[test]
    fn render_joins_with_fullwidth_comma_or_space() {
        let p = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(render(&p(&["你好", "世界"])), "你好，世界");
        assert_eq!(render(&p(&["hello", "world"])), "hello world");
        assert_eq!(render(&p(&["你好。", "世界"])), "你好。世界");
        assert_eq!(render(&p(&["ok.", "next"])), "ok.next");
        assert_eq!(render(&p(&["ok", "好"])), "ok，好");
        assert_eq!(render(&p(&[])), "");
    }

    #[test]
    fn rms_and_language() {
        assert_eq!(rms(&[]), 0.0);
        assert!((rms(&[0.5, -0.5]) - 0.5).abs() < 1e-6);
        assert_eq!(normalize_language("ZH"), "zh");
        assert_eq!(normalize_language("yue"), "yue");
        assert_eq!(normalize_language("zh-TW"), "auto");
    }

    #[test]
    fn vad_fed_in_whole_windows_until_final() {
        let (mut d, mut v) = (FakeDecoder::default(), FakeVad::default());
        let mut s = LiveSession::default();
        s.push(&vec![0.0; 1000]);
        s.process(&mut d, &mut v, false, true, Instant::now());
        assert_eq!(v.fed, 512);
        s.finish(&mut d, &mut v);
        assert_eq!(v.fed, 1000);
        assert!(v.flushed);
    }

    #[test]
    fn partial_every_0_8s_and_throttled_by_wall_clock() {
        let (mut d, mut v) = (
            FakeDecoder::default(),
            FakeVad {
                speaking: true,
                ..Default::default()
            },
        );
        let mut s = LiveSession::default();
        let t0 = Instant::now();
        s.push(&tone(SAMPLE_RATE / 2, 0.1));
        assert_eq!(s.process(&mut d, &mut v, false, true, t0), None);
        s.push(&tone(SAMPLE_RATE / 2, 0.1));
        assert_eq!(
            s.process(&mut d, &mut v, false, true, t0).as_deref(),
            Some("s16000")
        );
        // 又累積 0.9 秒但牆鐘才過 0.1 秒 → 不重算
        s.push(&tone(SAMPLE_RATE * 9 / 10, 0.1));
        assert_eq!(
            s.process(&mut d, &mut v, false, true, t0 + Duration::from_millis(100)),
            None
        );
        // 落後時不重算
        s.push(&tone(SAMPLE_RATE, 0.1));
        assert_eq!(
            s.process(&mut d, &mut v, false, false, t0 + Duration::from_secs(2)),
            None
        );
        assert_eq!(
            s.process(&mut d, &mut v, false, true, t0 + Duration::from_secs(2))
                .as_deref(),
            Some("s46400")
        );
        // 不在講話 → 沒有字幕
        v.speaking = false;
        s.push(&tone(SAMPLE_RATE, 0.1));
        assert_eq!(
            s.process(&mut d, &mut v, false, true, t0 + Duration::from_secs(5)),
            None
        );
    }

    #[test]
    fn segments_commit_and_partial_starts_after_committed_end() {
        let (mut d, mut v) = (
            FakeDecoder::default(),
            FakeVad {
                speaking: true,
                ..Default::default()
            },
        );
        let mut s = LiveSession::default();
        let t0 = Instant::now();
        s.push(&tone(SAMPLE_RATE * 2, 0.1));
        v.queued.push_back(VadSegment {
            start: 1000,
            samples: vec![0.1; 9000],
        });
        // 定稿後 last_partial_at = 目前長度，這輪不會再算字幕
        assert_eq!(
            s.process(&mut d, &mut v, false, true, t0).as_deref(),
            Some("s9000")
        );
        s.push(&tone(SAMPLE_RATE, 0.1));
        // 尾段從 committed_end(10000) 起算：48000 - 10000 = 38000
        assert_eq!(
            s.process(&mut d, &mut v, false, true, t0).as_deref(),
            Some("s9000 s38000")
        );
        v.queued.push_back(VadSegment {
            start: 20000,
            samples: vec![0.1; 100],
        });
        assert_eq!(s.finish(&mut d, &mut v), "s9000 s100");
    }

    #[test]
    fn partial_window_capped_at_8_seconds() {
        let (mut d, mut v) = (
            FakeDecoder::default(),
            FakeVad {
                speaking: true,
                ..Default::default()
            },
        );
        let mut s = LiveSession::default();
        s.push(&tone(SAMPLE_RATE * 12, 0.1));
        assert_eq!(
            s.process(&mut d, &mut v, false, true, Instant::now())
                .as_deref(),
            Some("s128000")
        );
    }

    #[test]
    fn finish_tail_gated_by_rms() {
        let (mut d, mut v) = (FakeDecoder::default(), FakeVad::default());
        let mut quiet = LiveSession::default();
        quiet.push(&tone(SAMPLE_RATE, 0.003));
        assert_eq!(quiet.finish(&mut d, &mut v), "");
        assert!(d.calls.is_empty());

        let mut loud = LiveSession::default();
        loud.push(&tone(SAMPLE_RATE, 0.1));
        assert_eq!(loud.finish(&mut d, &mut v), "s16000");

        // 太短（≤0.3 秒）也不辨識
        let mut short = LiveSession::default();
        short.push(&tone(SAMPLE_RATE * 3 / 10, 0.1));
        assert_eq!(short.finish(&mut d, &mut v), "");
    }

    #[test]
    fn progress_is_capped_until_done() {
        assert_eq!(download_progress(0, 0, 0), 0.0);
        assert!((download_progress(50, 25, 100) - 0.75).abs() < 1e-9);
        assert_eq!(download_progress(100, 0, 100), 0.999);
        assert_eq!(total_bytes(), 237_115_547 + 315_894 + 643_854);
    }

    #[test]
    fn installed_requires_exact_sizes() {
        let dir = std::env::temp_dir().join(format!("saybit-sherpa-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        assert!(!is_installed(&dir));
        for f in MODEL_FILES.iter() {
            let file = std::fs::File::create(dir.join(f.name)).unwrap();
            file.set_len(f.size).unwrap();
        }
        assert!(is_installed(&dir));
        std::fs::File::create(dir.join("tokens.txt"))
            .unwrap()
            .set_len(10)
            .unwrap();
        assert!(!is_installed(&dir));
        std::fs::remove_dir_all(&dir).unwrap();
    }
}

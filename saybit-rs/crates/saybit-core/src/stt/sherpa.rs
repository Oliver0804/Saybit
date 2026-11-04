//! SenseVoice int8 + Silero VAD（移植 saybit-desktop/src-tauri/src/sherpa_stt.rs 與 SherpaSTTEngine.swift）。
//! SenseVoice 不是串流模型：VAD 切句、每句講完就定稿；講話中每 0.8 秒把尚未定稿的尾段重新辨識一次當即時字幕。
//! sherpa 物件不是 thread-safe，全部只活在 `sensevoice-worker` 執行緒上；session 只丟訊息進 channel。
//! 輸出是簡體，除非語言偏好是 zh-CN，否則經 `traditionalize` 轉台灣繁體（partial 與定稿都轉）。
//!
//! macOS / Windows 靜態連結 sherpa-onnx；Linux 動態連結 .so（rpath 見 build.rs）。

use crate::models::{ModelManager, SENSEVOICE_FILES};
use crate::stt::traditionalize;
use crate::types::*;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

pub const SAMPLE_RATE: usize = 16_000;

pub const MSG_MODEL_MISSING: &str = "尚未下載離線辨識模型（SenseVoice），請到設定下載";
pub const MSG_LOAD_FAILED: &str = "離線辨識模型載入失敗，請到設定刪除後重新下載";
pub const MSG_UNSUPPORTED: &str = "此平台尚未支援 SenseVoice 離線辨識";

#[derive(Clone, Debug, PartialEq)]
pub struct ModelPaths {
    pub model: PathBuf,
    pub tokens: PathBuf,
    pub vad: PathBuf,
}

impl ModelPaths {
    pub fn in_dir(dir: &Path) -> Self {
        Self {
            model: dir.join(SENSEVOICE_FILES[0].name),
            tokens: dir.join(SENSEVOICE_FILES[1].name),
            vad: dir.join(SENSEVOICE_FILES[2].name),
        }
    }
}

/// 模型已完整安裝才回傳路徑（SenseVoice / VAD 建構時不檢查檔案，這裡一定要先擋）
pub fn installed_paths() -> anyhow::Result<ModelPaths> {
    let mm = ModelManager::new();
    if !mm.is_installed(ModelKind::SenseVoice) {
        anyhow::bail!(MSG_MODEL_MISSING);
    }
    Ok(ModelPaths::in_dir(&mm.dir(ModelKind::SenseVoice)))
}

/// SenseVoice 語言提示：auto / zh / en / ja / ko / yue；也接受 zh-TW / en-US 這類地區碼
pub fn normalize_language(language: &str) -> String {
    let lang = language.trim().to_ascii_lowercase();
    if lang.starts_with("yue") || lang == "zh-hk" || lang == "cantonese" {
        return "yue".into();
    }
    for code in ["zh", "en", "ja", "ko"] {
        if lang == code || lang.starts_with(&format!("{code}-")) || lang.starts_with(&format!("{code}_")) {
            return code.into();
        }
    }
    "auto".into()
}

/// 語言偏好是簡體中文時不轉繁體
pub fn wants_traditional(language_preference: &str) -> bool {
    language_wants_traditional(language_preference).unwrap_or(true)
}

/// 語言碼明確指出簡繁時回 Some：zh-CN / zh-SG / zh-Hans → Some(false)；zh-TW / zh-HK / zh-Hant → Some(true)
pub fn language_wants_traditional(language: &str) -> Option<bool> {
    match language.trim().to_ascii_lowercase().replace('_', "-").as_str() {
        "zh-cn" | "zh-sg" | "zh-hans" => Some(false),
        "zh-tw" | "zh-hk" | "zh-hant" | "zh-mo" => Some(true),
        _ => None,
    }
}

// MARK: - 辨識後端

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

    struct Recognizer(SenseVoiceRecognizer);

    impl SpeechDecoder for Recognizer {
        fn decode(&mut self, samples: &[f32]) -> String {
            if samples.is_empty() {
                return String::new();
            }
            self.0.transcribe(SAMPLE_RATE as u32, samples).text.trim().to_string()
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
                out.push(VadSegment { start: seg.start.max(0) as usize, samples: seg.samples });
            }
            out
        }
    }

    pub fn new_recognizer(paths: &ModelPaths, language: &str, num_threads: i32) -> anyhow::Result<Box<dyn SpeechDecoder>> {
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
            .map_err(|e| anyhow::anyhow!("{MSG_LOAD_FAILED}（{e}）"))
    }

    /// 參數同原生 SherpaVAD：threshold 0.5、min_speech 0.25、window 512、buffer 120 秒
    pub fn new_vad(paths: &ModelPaths, min_silence: f32, max_speech: f32) -> anyhow::Result<Box<dyn SpeechVad>> {
        let config = SileroVadConfig {
            model: paths.vad.to_string_lossy().into_owned(),
            min_silence_duration: min_silence,
            min_speech_duration: 0.25,
            max_speech_duration: max_speech,
            threshold: 0.5,
            sample_rate: SAMPLE_RATE as u32,
            window_size: super::VAD_WINDOW as i32,
            provider: Some("cpu".into()),
            num_threads: Some(1),
            debug: false,
        };
        SileroVad::new(config, 120.0)
            .map(|v| Box::new(Vad(v)) as Box<dyn SpeechVad>)
            .map_err(|e| anyhow::anyhow!("{MSG_LOAD_FAILED}（{e}）"))
    }
}

#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
mod backend {
    use super::{ModelPaths, SpeechDecoder, SpeechVad, MSG_UNSUPPORTED};

    pub const SUPPORTED: bool = false;

    pub fn new_recognizer(_: &ModelPaths, _: &str, _: i32) -> anyhow::Result<Box<dyn SpeechDecoder>> {
        anyhow::bail!(MSG_UNSUPPORTED)
    }

    pub fn new_vad(_: &ModelPaths, _: f32, _: f32) -> anyhow::Result<Box<dyn SpeechVad>> {
        anyhow::bail!(MSG_UNSUPPORTED)
    }
}

pub use backend::{new_recognizer, new_vad, SUPPORTED};
pub const VAD_WINDOW: usize = 512;

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

    /// 回傳 Some(累積文字) 表示字幕有變
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
            let from = self.committed_end.max(len.saturating_sub(MAX_PARTIAL_WINDOW));
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
            '!' | '"' | '#' | '%' | '&' | '\'' | '(' | ')' | '*' | ',' | '-' | '.' | '/' | ':' | ';' | '?' | '@' | '['
                | '\\' | ']' | '_' | '{' | '}'
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
                out.push_str(if last.is_ascii() && first.is_ascii() { " " } else { "，" });
            }
        }
        out.push_str(part);
    }
    out
}

// MARK: - Worker 執行緒（持有所有 sherpa 物件）

type SharedPartial = Arc<dyn Fn(String) + Send + Sync>;

enum Cmd {
    Start {
        gen: u64,
        paths: ModelPaths,
        language: String,
        on_partial: Option<SharedPartial>,
        reply: mpsc::Sender<anyhow::Result<()>>,
    },
    Push {
        gen: u64,
        samples: Vec<f32>,
    },
    Finish {
        gen: u64,
        reply: mpsc::Sender<anyhow::Result<String>>,
    },
    Cancel {
        gen: u64,
    },
    /// 刪除模型時釋放記憶體（約 250 MB）
    Unload,
}

static SESSION_GEN: AtomicU64 = AtomicU64::new(0);
static WORKER: OnceLock<Mutex<mpsc::Sender<Cmd>>> = OnceLock::new();

fn send(cmd: Cmd) -> anyhow::Result<()> {
    let tx = WORKER.get_or_init(|| {
        let (tx, rx) = mpsc::channel();
        std::thread::Builder::new()
            .name("sensevoice-worker".into())
            .spawn(move || worker_loop(rx))
            .expect("spawn sensevoice worker");
        Mutex::new(tx)
    });
    tx.lock()
        .map_err(|_| anyhow::anyhow!("SenseVoice 背景執行緒已停止"))?
        .send(cmd)
        .map_err(|_| anyhow::anyhow!("SenseVoice 背景執行緒已停止"))
}

/// 釋放常駐模型（刪除模型前呼叫）。worker 沒啟動過就什麼都不做。
pub fn unload() {
    SESSION_GEN.fetch_add(1, Ordering::SeqCst);
    if WORKER.get().is_some() {
        let _ = send(Cmd::Unload);
    }
}

struct Loaded {
    paths: ModelPaths,
    language: String,
    recognizer: Box<dyn SpeechDecoder>,
}

struct Active {
    gen: u64,
    vad: Box<dyn SpeechVad>,
    session: LiveSession,
    on_partial: Option<SharedPartial>,
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
            Cmd::Start { gen, paths, language, on_partial, reply } => {
                active = None;
                let need_load = loaded.as_ref().is_none_or(|l| l.paths != paths || l.language != language);
                if need_load {
                    loaded = None; // 先釋放舊的，避免兩份模型同時在記憶體
                    match new_recognizer(&paths, &language, 2) {
                        Ok(recognizer) => loaded = Some(Loaded { paths: paths.clone(), language, recognizer }),
                        Err(e) => {
                            let _ = reply.send(Err(e));
                            continue;
                        }
                    }
                }
                // sherpa-rs 沒有包 VAD reset，每次錄音重建一個（silero 只有 640 KB，很快）
                match new_vad(&paths, 0.5, 20.0) {
                    Ok(vad) => {
                        active = Some(Active { gen, vad, session: LiveSession::default(), on_partial });
                        let _ = reply.send(Ok(()));
                    }
                    Err(e) => {
                        let _ = reply.send(Err(e));
                    }
                }
            }
            Cmd::Push { gen, samples } => {
                let current = active.as_ref().map(|a| a.gen);
                let mut batch = if current == Some(gen) { samples } else { Vec::new() };
                // 合併已排隊的音訊：落後時一次追上，而不是每包都重算字幕
                loop {
                    match rx.try_recv() {
                        Ok(Cmd::Push { gen: g, samples: more }) => {
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
                if let Some(text) =
                    a.session.process(l.recognizer.as_mut(), a.vad.as_mut(), false, !behind, Instant::now())
                {
                    if let Some(cb) = a.on_partial.as_ref() {
                        cb(text);
                    }
                }
            }
            Cmd::Finish { gen, reply } => {
                let result = match (active.take(), loaded.as_mut()) {
                    (Some(mut a), Some(l)) if a.gen == gen => Ok(a.session.finish(l.recognizer.as_mut(), a.vad.as_mut())),
                    (other, _) => {
                        active = other.filter(|a| a.gen != gen);
                        Err(anyhow::anyhow!("沒有進行中的 SenseVoice 辨識"))
                    }
                };
                let _ = reply.send(result);
            }
            Cmd::Cancel { gen } => {
                if active.as_ref().is_some_and(|a| a.gen == gen) {
                    active = None;
                }
            }
            Cmd::Unload => {
                active = None;
                loaded = None;
            }
        }
    }
}

// MARK: - SttEngine / SttSession

pub struct Engine {
    model_dir: PathBuf,
    traditional: bool,
}

impl Engine {
    pub fn new(settings: &Settings, _secret: &dyn Fn(&str) -> Option<String>) -> Self {
        let traditional = wants_traditional(&settings.language_preference);
        if traditional && SUPPORTED {
            // 字典解析放背景，第一句 partial 不用等
            std::thread::spawn(traditionalize::preload);
        }
        Self { model_dir: ModelManager::new().dir(ModelKind::SenseVoice), traditional }
    }

    fn convert(traditional: bool, text: String) -> String {
        if traditional {
            traditionalize::to_traditional(&text)
        } else {
            text
        }
    }
}

impl SttEngine for Engine {
    fn kind(&self) -> SttEngineKind {
        SttEngineKind::SenseVoice
    }

    fn unavailable_reason(&self) -> Option<String> {
        if !SUPPORTED {
            return Some(MSG_UNSUPPORTED.into());
        }
        if !crate::models::is_installed_in(&self.model_dir, ModelKind::SenseVoice) {
            return Some(MSG_MODEL_MISSING.into());
        }
        None
    }

    fn start(&self, opts: SttStartOptions) -> anyhow::Result<Box<dyn SttSession>> {
        if let Some(reason) = self.unavailable_reason() {
            anyhow::bail!(reason);
        }
        let gen = SESSION_GEN.fetch_add(1, Ordering::SeqCst) + 1;
        // 這次錄音明確指定 zh-CN → 保留簡體；zh-TW → 轉繁體；其他（auto / en-US…）依設定的語言偏好
        let traditional = language_wants_traditional(&opts.language).unwrap_or(self.traditional);
        let on_partial: Option<SharedPartial> = opts.on_partial.map(|cb| {
            Arc::new(move |text: String| cb(Self::convert(traditional, text))) as SharedPartial
        });
        let (tx, rx) = mpsc::channel();
        send(Cmd::Start {
            gen,
            paths: ModelPaths::in_dir(&self.model_dir),
            language: normalize_language(&opts.language),
            on_partial,
            reply: tx,
        })?;
        // 第一次要載入模型（約 1 秒）
        rx.recv_timeout(Duration::from_secs(60))
            .map_err(|_| anyhow::anyhow!("SenseVoice 背景執行緒無回應"))??;
        Ok(Box::new(Session { gen, traditional, done: false }))
    }
}

struct Session {
    gen: u64,
    traditional: bool,
    done: bool,
}

impl SttSession for Session {
    fn push(&mut self, samples: &[f32]) {
        if samples.is_empty() || self.done {
            return;
        }
        if let Err(e) = send(Cmd::Push { gen: self.gen, samples: samples.to_vec() }) {
            log::warn!("SenseVoice push 失敗：{e}");
        }
    }

    fn finish(mut self: Box<Self>) -> anyhow::Result<String> {
        self.done = true;
        let (tx, rx) = mpsc::channel();
        send(Cmd::Finish { gen: self.gen, reply: tx })?;
        // 最後一句要辨識；長錄音的尾段最多 30 秒
        let text = rx
            .recv_timeout(Duration::from_secs(120))
            .map_err(|_| anyhow::anyhow!("SenseVoice 背景執行緒無回應"))??;
        Ok(Engine::convert(self.traditional, text))
    }

    fn cancel(mut self: Box<Self>) {
        self.done = true;
        let _ = send(Cmd::Cancel { gen: self.gen });
    }
}

impl Drop for Session {
    /// 沒 finish / cancel 就被丟掉：讓 worker 放掉這個 session
    fn drop(&mut self) {
        if !self.done {
            let _ = send(Cmd::Cancel { gen: self.gen });
        }
    }
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
        assert_eq!(render(&p(&["ok", "好"])), "ok，好");
        assert_eq!(render(&p(&[])), "");
    }

    #[test]
    fn language_mapping() {
        assert_eq!(rms(&[]), 0.0);
        assert_eq!(normalize_language("ZH"), "zh");
        assert_eq!(normalize_language("zh-TW"), "zh");
        assert_eq!(normalize_language("en-US"), "en");
        assert_eq!(normalize_language("yue"), "yue");
        assert_eq!(normalize_language("zh-HK"), "yue");
        assert_eq!(normalize_language("auto"), "auto");
        assert_eq!(normalize_language("fr"), "auto");
        assert!(wants_traditional("zh-TW"));
        assert!(!wants_traditional("zh-CN"));
        assert!(wants_traditional("auto"));
        assert_eq!(language_wants_traditional("en-US"), None);
        assert_eq!(normalize_language("ja-JP"), "ja");
        assert_eq!(normalize_language("zh-CN"), "zh");
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
        let (mut d, mut v) = (FakeDecoder::default(), FakeVad { speaking: true, ..Default::default() });
        let mut s = LiveSession::default();
        let t0 = Instant::now();
        s.push(&tone(SAMPLE_RATE / 2, 0.1));
        assert_eq!(s.process(&mut d, &mut v, false, true, t0), None);
        s.push(&tone(SAMPLE_RATE / 2, 0.1));
        assert_eq!(s.process(&mut d, &mut v, false, true, t0).as_deref(), Some("s16000"));
        s.push(&tone(SAMPLE_RATE * 9 / 10, 0.1));
        assert_eq!(s.process(&mut d, &mut v, false, true, t0 + Duration::from_millis(100)), None);
        s.push(&tone(SAMPLE_RATE, 0.1));
        assert_eq!(s.process(&mut d, &mut v, false, false, t0 + Duration::from_secs(2)), None);
        assert_eq!(s.process(&mut d, &mut v, false, true, t0 + Duration::from_secs(2)).as_deref(), Some("s46400"));
        v.speaking = false;
        s.push(&tone(SAMPLE_RATE, 0.1));
        assert_eq!(s.process(&mut d, &mut v, false, true, t0 + Duration::from_secs(5)), None);
    }

    #[test]
    fn segments_commit_and_partial_starts_after_committed_end() {
        let (mut d, mut v) = (FakeDecoder::default(), FakeVad { speaking: true, ..Default::default() });
        let mut s = LiveSession::default();
        let t0 = Instant::now();
        s.push(&tone(SAMPLE_RATE * 2, 0.1));
        v.queued.push_back(VadSegment { start: 1000, samples: vec![0.1; 9000] });
        assert_eq!(s.process(&mut d, &mut v, false, true, t0).as_deref(), Some("s9000"));
        s.push(&tone(SAMPLE_RATE, 0.1));
        assert_eq!(s.process(&mut d, &mut v, false, true, t0).as_deref(), Some("s9000 s38000"));
        v.queued.push_back(VadSegment { start: 20000, samples: vec![0.1; 100] });
        assert_eq!(s.finish(&mut d, &mut v), "s9000 s100");
    }

    #[test]
    fn partial_window_capped_at_8_seconds() {
        let (mut d, mut v) = (FakeDecoder::default(), FakeVad { speaking: true, ..Default::default() });
        let mut s = LiveSession::default();
        s.push(&tone(SAMPLE_RATE * 12, 0.1));
        assert_eq!(s.process(&mut d, &mut v, false, true, Instant::now()).as_deref(), Some("s128000"));
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
        let mut short = LiveSession::default();
        short.push(&tone(SAMPLE_RATE * 3 / 10, 0.1));
        assert_eq!(short.finish(&mut d, &mut v), "");
    }

    /// 即時路徑：音檔切 100 ms 一包餵 Engine（走 worker + on_partial），需要真模型：
    /// SAYBIT_SHERPA_DIR=<模型目錄> SAYBIT_TEST_AUDIO=<音檔> cargo test -p saybit-core real_model -- --ignored --nocapture
    #[test]
    #[ignore]
    fn real_model_live_session() {
        let (Ok(dir), Ok(audio)) = (std::env::var("SAYBIT_SHERPA_DIR"), std::env::var("SAYBIT_TEST_AUDIO")) else {
            eprintln!("略過：未設定 SAYBIT_SHERPA_DIR / SAYBIT_TEST_AUDIO");
            return;
        };
        let pcm = crate::file_transcribe::decode_to_16k_mono(Path::new(&audio)).unwrap();
        let engine = Engine { model_dir: PathBuf::from(dir), traditional: true };
        assert_eq!(engine.unavailable_reason(), None);
        let partials = Arc::new(Mutex::new(Vec::<String>::new()));
        let p2 = partials.clone();
        let mut session = engine
            .start(SttStartOptions {
                language: "auto".into(),
                hint_terms: vec![],
                on_partial: Some(Box::new(move |t| p2.lock().unwrap().push(t))),
            })
            .unwrap();
        for chunk in pcm.chunks(1600) {
            session.push(chunk);
            std::thread::sleep(Duration::from_millis(5));
        }
        let text = session.finish().unwrap();
        for p in partials.lock().unwrap().iter() {
            println!("partial: {p}");
        }
        println!("final: {text}");
        assert!(!text.is_empty());
    }
}

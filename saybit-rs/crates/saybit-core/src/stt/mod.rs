//! STT 引擎（批次 C1）。每個子模組實作 `SttEngine` + `SttSession`。
//! - sherpa：SenseVoice int8 + Silero VAD（移植 saybit-desktop/src-tauri/src/sherpa_stt.rs 與 SherpaSTTEngine.swift）
//! - whisper_local：whisper.cpp（移植 local_stt.rs）
//! - cloud_whisper：OpenAI / Groq /custom（multipart WAV）
//! - streaming：阿里雲百鍊 / 訊飛 RTASR WebSocket（移植 streaming_stt.rs；tungstenite 阻塞式）
//! - apple：macOS SFSpeechRecognizer（cfg(target_os="macos")，objc2）；其他平台 unavailable
//! - artifacts：Whisper 靜音幻聽過濾（移植 sttArtifacts.ts）
//! - traditionalize：簡體 → 台灣繁體（OpenCC s2twp 字典）
pub mod apple;
pub mod artifacts;
pub mod cloud_whisper;
pub mod sherpa;
pub mod streaming;
pub mod traditionalize;
pub mod whisper_local;

use crate::types::*;

/// secret(account) 用來拿 key："stt.openai" / "stt.groq" / "stt.custom" / "stt.alibaba" / "stt.xunfei"
/// （訊飛 "stt.xunfei" 格式為 "appid:apikey"）
pub fn make_engine(kind: SttEngineKind, settings: &Settings, secret: &dyn Fn(&str) -> Option<String>) -> Box<dyn SttEngine> {
    match kind {
        SttEngineKind::SenseVoice => Box::new(sherpa::Engine::new(settings, secret)),
        SttEngineKind::WhisperLocal => Box::new(whisper_local::Engine::new(settings, secret)),
        SttEngineKind::CloudWhisper => Box::new(cloud_whisper::Engine::new(settings, secret)),
        SttEngineKind::Streaming => Box::new(streaming::Engine::new(settings, secret)),
        SttEngineKind::Apple => Box::new(apple::Engine::new(settings, secret)),
    }
}

/// 這個 build / 平台支援哪些引擎（UI 用來灰掉選項）
pub fn supported_kinds() -> Vec<SttEngineKind> {
    let mut kinds = Vec::new();
    if sherpa::SUPPORTED {
        kinds.push(SttEngineKind::SenseVoice);
    }
    kinds.push(SttEngineKind::WhisperLocal);
    kinds.push(SttEngineKind::CloudWhisper);
    kinds.push(SttEngineKind::Streaming);
    if apple::SUPPORTED {
        kinds.push(SttEngineKind::Apple);
    }
    kinds
}

/// Whisper 系列的 initial prompt：偏向台灣繁體 + 個人字典偏好寫法（最多 30 個）
pub fn whisper_prompt(language: &str, language_preference: &str, hint_terms: &[String]) -> String {
    // language 可能是 "zh-TW" / "zh-CN" / "en-US" / "auto"；帶地區碼時以它為準，否則看語言偏好
    let full = language.trim().to_ascii_lowercase().replace('_', "-");
    let lang = full.split('-').next().unwrap_or("").to_string();
    let chinese = lang == "zh" || lang == "auto" || lang.is_empty();
    let simplified = match full.as_str() {
        "zh-cn" | "zh-sg" | "zh-hans" => true,
        "zh-tw" | "zh-hk" | "zh-hant" => false,
        _ => language_preference.eq_ignore_ascii_case("zh-CN"),
    };
    let mut prompt = String::new();
    if chinese {
        if simplified {
            prompt.push_str("以下是简体中文的语音逐字稿。");
        } else if language_preference.to_ascii_lowercase().starts_with("zh") || lang == "zh" {
            prompt.push_str("以下是繁體中文（台灣）的語音逐字稿。");
        }
    }
    let mut seen = std::collections::HashSet::new();
    let terms: Vec<&str> = hint_terms
        .iter()
        .map(|t| t.trim())
        .filter(|t| !t.is_empty() && seen.insert(t.to_string()))
        .take(30)
        .collect();
    if !terms.is_empty() {
        if prompt.is_empty() && !chinese {
            prompt.push_str(&terms.join(", "));
            prompt.push('.');
        } else {
            prompt.push_str(&format!("常見詞彙：{}。", terms.join("、")));
        }
    }
    prompt
}

/// "auto" → None（自動偵測），其餘取主語言碼
pub fn whisper_language(language: &str) -> Option<String> {
    let l = language.trim().to_ascii_lowercase();
    let main = l.split(['-', '_']).next().unwrap_or("").to_string();
    if main.is_empty() || main == "auto" {
        None
    } else {
        Some(main)
    }
}

type BatchRun = Box<dyn FnOnce(Vec<f32>) -> anyhow::Result<String> + Send>;

/// 批次引擎共用：錄音中只累積樣本，finish 才整段辨識
pub(crate) struct BufferedSession {
    samples: Vec<f32>,
    run: Option<BatchRun>,
}

impl BufferedSession {
    pub(crate) fn boxed(run: impl FnOnce(Vec<f32>) -> anyhow::Result<String> + Send + 'static) -> Box<dyn SttSession> {
        Box::new(Self { samples: Vec::with_capacity(16_000 * 30), run: Some(Box::new(run)) })
    }
}

impl SttSession for BufferedSession {
    fn push(&mut self, samples: &[f32]) {
        self.samples.extend_from_slice(samples);
    }

    fn finish(mut self: Box<Self>) -> anyhow::Result<String> {
        let samples = std::mem::take(&mut self.samples);
        match self.run.take() {
            Some(run) => run(samples),
            None => Ok(String::new()),
        }
    }

    fn cancel(self: Box<Self>) {}
}

/// 16 kHz mono f32 → 16-bit PCM WAV
pub fn pcm_to_wav(samples: &[f32], sample_rate: u32) -> Vec<u8> {
    let data_len = (samples.len() * 2) as u32;
    let mut wav = Vec::with_capacity(44 + data_len as usize);
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data_len).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&sample_rate.to_le_bytes());
    wav.extend_from_slice(&(sample_rate * 2).to_le_bytes());
    wav.extend_from_slice(&2u16.to_le_bytes());
    wav.extend_from_slice(&16u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_len.to_le_bytes());
    for s in samples {
        wav.extend_from_slice(&f32_to_i16(*s).to_le_bytes());
    }
    wav
}

pub fn f32_to_i16(s: f32) -> i16 {
    (s.clamp(-1.0, 1.0) * i16::MAX as f32).round() as i16
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn supported_kinds_per_platform() {
        let k = supported_kinds();
        assert!(k.contains(&SttEngineKind::WhisperLocal));
        assert!(k.contains(&SttEngineKind::CloudWhisper));
        assert_eq!(k.contains(&SttEngineKind::Apple), cfg!(target_os = "macos"));
        assert_eq!(k.contains(&SttEngineKind::SenseVoice), sherpa::SUPPORTED);
    }

    #[test]
    fn make_engine_kinds_match() {
        let s = Settings::default();
        let none = |_: &str| None;
        for kind in [
            SttEngineKind::SenseVoice,
            SttEngineKind::WhisperLocal,
            SttEngineKind::CloudWhisper,
            SttEngineKind::Streaming,
            SttEngineKind::Apple,
        ] {
            let e = make_engine(kind, &s, &none);
            assert_eq!(e.kind(), kind);
        }
        // 沒 key 的雲端引擎一定不可用
        assert!(make_engine(SttEngineKind::CloudWhisper, &s, &none).unavailable_reason().is_some());
        assert!(make_engine(SttEngineKind::Streaming, &s, &none).unavailable_reason().is_some());
    }

    #[test]
    fn prompt_and_language() {
        let terms = vec!["Saybit".to_string(), "  ".into(), "Saybit".into(), "顏國明".into()];
        assert_eq!(whisper_prompt("zh", "zh-TW", &terms), "以下是繁體中文（台灣）的語音逐字稿。常見詞彙：Saybit、顏國明。");
        assert_eq!(whisper_prompt("auto", "zh-CN", &[]), "以下是简体中文的语音逐字稿。");
        assert_eq!(whisper_prompt("en", "zh-TW", &terms), "Saybit, 顏國明.");
        assert_eq!(whisper_prompt("auto", "en-US", &[]), "");
        assert!(whisper_prompt("zh-CN", "zh-TW", &[]).starts_with("以下是简体中文"));
        assert!(whisper_prompt("zh-TW", "zh-CN", &[]).starts_with("以下是繁體中文"));
        assert_eq!(whisper_prompt("en-US", "zh-TW", &[]), "");
        assert_eq!(whisper_language("en-US"), Some("en".into()));
        assert_eq!(whisper_language("ja-JP"), Some("ja".into()));
        assert_eq!(whisper_language("auto"), None);
        assert_eq!(whisper_language("zh-TW"), Some("zh".into()));
        assert_eq!(whisper_language("ja"), Some("ja".into()));
    }

    #[test]
    fn wav_header_and_samples() {
        let wav = pcm_to_wav(&[0.0, 1.0, -1.0, 2.0], 16_000);
        assert_eq!(wav.len(), 44 + 8);
        assert_eq!(&wav[0..4], b"RIFF");
        assert_eq!(u32::from_le_bytes(wav[24..28].try_into().unwrap()), 16_000);
        assert_eq!(i16::from_le_bytes([wav[46], wav[47]]), i16::MAX);
        assert_eq!(i16::from_le_bytes([wav[48], wav[49]]), -i16::MAX);
        assert_eq!(i16::from_le_bytes([wav[50], wav[51]]), i16::MAX);
    }

    #[test]
    fn buffered_session_runs_once_with_all_samples() {
        let mut s = BufferedSession::boxed(|pcm| Ok(format!("{}", pcm.len())));
        s.push(&[0.0; 10]);
        s.push(&[0.0; 5]);
        assert_eq!(s.finish().unwrap(), "15");
    }
}

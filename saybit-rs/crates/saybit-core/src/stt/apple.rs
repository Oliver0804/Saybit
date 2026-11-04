//! Apple Speech（SFSpeechRecognizer）—— macOS 專屬（移植 saybit-desktop/src-tauri/src/apple_speech.rs）。
//! 批次：錄音中只累積，finish 時切 1 秒一塊餵 SFSpeechAudioBufferRecognitionRequest，等 final result。
//! `apple_on_device_only` → requiresOnDeviceRecognition：該語言沒有離線模型時直接報錯，不偷偷送 Apple 伺服器。
//!
//! 要求授權需要 bundle 的 Info.plist 有 NSSpeechRecognitionUsageDescription，缺了系統會直接終止程序；
//! 所以 Info.plist 沒這個 key 時只回錯誤、不呼叫 requestAuthorization（`cargo run` 的裸執行檔就是這種情況）。

use crate::stt::BufferedSession;
use crate::types::*;

pub const SUPPORTED: bool = cfg!(target_os = "macos");
pub const MSG_UNSUPPORTED: &str = "此平台不支援 Apple 語音辨識";

/// 設定的語言偏好 + 引擎語言 → SFSpeechRecognizer 的 locale
pub fn locale_for(language: &str, language_preference: &str) -> String {
    let pref = language_preference.trim();
    let lang = language.trim();
    // 已帶地區碼（zh-TW / en-US / ja-JP…）就直接用
    if lang.len() > 3 && lang.contains(['-', '_']) {
        return lang.replace('_', "-");
    }
    match lang.to_ascii_lowercase().as_str() {
        "en" => "en-US".into(),
        "ja" => "ja-JP".into(),
        "ko" => "ko-KR".into(),
        "yue" => "zh-HK".into(),
        "zh" if pref.to_ascii_lowercase().starts_with("zh") => pref.into(),
        "zh" => "zh-TW".into(),
        _ if pref.is_empty() => "zh-TW".into(),
        _ => pref.into(),
    }
}

pub struct Engine {
    language_preference: String,
    on_device_only: bool,
}

impl Engine {
    pub fn new(settings: &Settings, _secret: &dyn Fn(&str) -> Option<String>) -> Self {
        Self { language_preference: settings.language_preference.clone(), on_device_only: settings.apple_on_device_only }
    }
}

impl SttEngine for Engine {
    fn kind(&self) -> SttEngineKind {
        SttEngineKind::Apple
    }

    fn unavailable_reason(&self) -> Option<String> {
        if !SUPPORTED {
            return Some(MSG_UNSUPPORTED.into());
        }
        imp::denied_reason()
    }

    fn start(&self, opts: SttStartOptions) -> anyhow::Result<Box<dyn SttSession>> {
        if let Some(r) = self.unavailable_reason() {
            anyhow::bail!(r);
        }
        let locale = locale_for(&opts.language, &self.language_preference);
        let on_device = self.on_device_only;
        Ok(BufferedSession::boxed(move |pcm| imp::transcribe(&pcm, &locale, on_device).map_err(|e| anyhow::anyhow!(e))))
    }
}

#[cfg(target_os = "macos")]
mod imp {
    use block2::RcBlock;
    use objc2::rc::Retained;
    use objc2::AllocAnyThread;
    use objc2_avf_audio::{AVAudioFormat, AVAudioPCMBuffer};
    use objc2_foundation::{NSBundle, NSError, NSLocale, NSString};
    use objc2_speech::{
        SFSpeechAudioBufferRecognitionRequest, SFSpeechRecognitionResult, SFSpeechRecognizer,
        SFSpeechRecognizerAuthorizationStatus,
    };
    use std::sync::mpsc;
    use std::time::Duration;

    const SAMPLE_RATE: f64 = 16000.0;
    /// 整段一次塞進去在長錄音時容易被丟棄，切成約 1 秒一塊比較穩
    const CHUNK_FRAMES: usize = 16000;

    fn status() -> SFSpeechRecognizerAuthorizationStatus {
        unsafe { SFSpeechRecognizer::authorizationStatus() }
    }

    fn has_usage_description() -> bool {
        let bundle = NSBundle::mainBundle();
        bundle.objectForInfoDictionaryKey(&NSString::from_str("NSSpeechRecognitionUsageDescription")).is_some()
    }

    pub fn denied_reason() -> Option<String> {
        let s = status();
        if s == SFSpeechRecognizerAuthorizationStatus::Denied {
            Some("使用者拒絕了語音辨識權限（系統設定 → 隱私權與安全性 → 語音辨識）".into())
        } else if s == SFSpeechRecognizerAuthorizationStatus::Restricted {
            Some("這台機器的語音辨識功能被管理原則限制".into())
        } else if s != SFSpeechRecognizerAuthorizationStatus::Authorized && !has_usage_description() {
            Some("這個執行檔沒有語音辨識用途說明（Info.plist），無法要求權限；請用打包後的 App".into())
        } else {
            None
        }
    }

    fn request_authorization() -> Result<(), String> {
        if !has_usage_description() {
            return Err("這個執行檔沒有語音辨識用途說明（Info.plist），無法要求權限".into());
        }
        let (tx, rx) = mpsc::channel::<SFSpeechRecognizerAuthorizationStatus>();
        let block = RcBlock::new(move |status: SFSpeechRecognizerAuthorizationStatus| {
            let _ = tx.send(status);
        });
        unsafe { SFSpeechRecognizer::requestAuthorization(&block) };
        match rx.recv_timeout(Duration::from_secs(60)) {
            Ok(SFSpeechRecognizerAuthorizationStatus::Authorized) => Ok(()),
            Ok(SFSpeechRecognizerAuthorizationStatus::Denied) => {
                Err("使用者拒絕了語音辨識權限（系統設定 → 隱私權與安全性 → 語音辨識）".into())
            }
            Ok(SFSpeechRecognizerAuthorizationStatus::Restricted) => Err("這台機器的語音辨識功能被管理原則限制".into()),
            Ok(_) => Err("尚未取得語音辨識授權".into()),
            Err(_) => Err("等待語音辨識授權逾時".into()),
        }
    }

    fn make_recognizer(locale_id: &str) -> Result<Retained<SFSpeechRecognizer>, String> {
        let locale = NSLocale::initWithLocaleIdentifier(NSLocale::alloc(), &NSString::from_str(locale_id));
        let recognizer = unsafe { SFSpeechRecognizer::initWithLocale(SFSpeechRecognizer::alloc(), &locale) }
            .ok_or_else(|| format!("系統不支援這個語言的語音辨識：{locale_id}"))?;
        if !unsafe { recognizer.isAvailable() } {
            return Err("語音辨識服務目前不可用（可能正在下載語言包，稍候再試）".into());
        }
        Ok(recognizer)
    }

    fn make_buffer(format: &AVAudioFormat, samples: &[f32]) -> Result<Retained<AVAudioPCMBuffer>, String> {
        let frames = samples.len() as u32;
        let buffer = unsafe {
            AVAudioPCMBuffer::initWithPCMFormat_frameCapacity(AVAudioPCMBuffer::alloc(), format, frames)
        }
        .ok_or("無法配置音訊緩衝區")?;
        unsafe {
            buffer.setFrameLength(frames);
            let channels = buffer.floatChannelData();
            if channels.is_null() {
                return Err("音訊緩衝區沒有 float channel data".into());
            }
            // standard format 是 deinterleaved float32，單聲道只有 channel 0
            let channel0 = (*channels).as_ptr();
            std::ptr::copy_nonoverlapping(samples.as_ptr(), channel0, samples.len());
        }
        Ok(buffer)
    }

    pub fn transcribe(pcm: &[f32], locale_id: &str, require_on_device: bool) -> Result<String, String> {
        if pcm.is_empty() {
            return Ok(String::new());
        }
        if status() != SFSpeechRecognizerAuthorizationStatus::Authorized {
            request_authorization()?;
        }
        let recognizer = make_recognizer(locale_id)?;
        if require_on_device && !unsafe { recognizer.supportsOnDeviceRecognition() } {
            return Err(format!(
                "這個語言（{locale_id}）沒有離線辨識模型，關閉「僅限離線辨識」或改用其他引擎"
            ));
        }
        let request = unsafe { SFSpeechAudioBufferRecognitionRequest::new() };
        unsafe {
            request.setShouldReportPartialResults(false);
            request.setRequiresOnDeviceRecognition(require_on_device);
        }
        let format = unsafe {
            AVAudioFormat::initStandardFormatWithSampleRate_channels(AVAudioFormat::alloc(), SAMPLE_RATE, 1)
        }
        .ok_or("無法建立 16kHz 單聲道音訊格式")?;

        // resultHandler 在任意 queue 上被呼叫，用 channel 把結果帶回這個執行緒
        let (tx, rx) = mpsc::channel::<Result<String, String>>();
        let handler = RcBlock::new(move |result: *mut SFSpeechRecognitionResult, error: *mut NSError| unsafe {
            if !error.is_null() {
                let description = (*error).localizedDescription().to_string();
                let _ = tx.send(Err(format!("語音辨識失敗：{description}")));
                return;
            }
            if result.is_null() {
                return;
            }
            let result = &*result;
            if !result.isFinal() {
                return;
            }
            let _ = tx.send(Ok(result.bestTranscription().formattedString().to_string()));
        });
        let _task = unsafe { recognizer.recognitionTaskWithRequest_resultHandler(&request, &handler) };
        for chunk in pcm.chunks(CHUNK_FRAMES) {
            let buffer = make_buffer(&format, chunk)?;
            unsafe { request.appendAudioPCMBuffer(&buffer) };
        }
        unsafe { request.endAudio() };

        // 逾時給「音訊長度 + 30 秒」：首次使用某語言時 macOS 可能正在下載語言包
        let timeout = Duration::from_secs_f64(pcm.len() as f64 / SAMPLE_RATE + 30.0);
        match rx.recv_timeout(timeout) {
            Ok(outcome) => outcome.map(|t| t.trim().to_string()),
            Err(_) => Err("語音辨識逾時（沒有收到最終結果）".into()),
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    pub fn denied_reason() -> Option<String> {
        Some(super::MSG_UNSUPPORTED.into())
    }

    pub fn transcribe(_pcm: &[f32], _locale_id: &str, _require_on_device: bool) -> Result<String, String> {
        Err(super::MSG_UNSUPPORTED.into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn locale_mapping() {
        assert_eq!(locale_for("auto", "zh-TW"), "zh-TW");
        assert_eq!(locale_for("zh", "zh-CN"), "zh-CN");
        assert_eq!(locale_for("zh", "en-US"), "zh-TW");
        assert_eq!(locale_for("en", "zh-TW"), "en-US");
        assert_eq!(locale_for("yue", "zh-TW"), "zh-HK");
        assert_eq!(locale_for("auto", ""), "zh-TW");
        assert_eq!(locale_for("zh-CN", "zh-TW"), "zh-CN");
        assert_eq!(locale_for("en-US", "zh-TW"), "en-US");
    }
}

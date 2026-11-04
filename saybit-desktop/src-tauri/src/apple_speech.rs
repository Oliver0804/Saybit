// Apple Speech（SFSpeechRecognizer）語音辨識 —— macOS 專屬。
//
// 對應原生版 Core/SpeechRecognition/SpeechRecognizer.swift 的 on-device 路徑。
// Windows / Linux 沒有等價服務，該平台的 command 直接回錯，前端不會顯示這個選項。
//
// 與 whisper.cpp 路徑的差別：
//   - 不用下載 574MB 模型，系統內建（首次使用某語言時 macOS 會自行下載語言包）
//   - 延遲低很多，但標點與長句整理不如 whisper，後面的 LLM 精煉照樣會補
//   - requiresOnDeviceRecognition 打開才保證音訊不出機器
//
// macOS 需要 Info.plist 的 NSSpeechRecognitionUsageDescription，缺了會在要求
// 授權時直接終止程序。

#[cfg(target_os = "macos")]
mod imp {
    use block2::RcBlock;
    use objc2::rc::Retained;
    use objc2::AllocAnyThread;
    use objc2_avf_audio::{AVAudioFormat, AVAudioPCMBuffer};
    use objc2_foundation::{NSError, NSLocale, NSString};
    use objc2_speech::{
        SFSpeechAudioBufferRecognitionRequest, SFSpeechRecognitionResult, SFSpeechRecognizer,
        SFSpeechRecognizerAuthorizationStatus,
    };
    use std::sync::mpsc;
    use std::time::Duration;

    const SAMPLE_RATE: f64 = 16000.0;
    /// 一次餵給辨識器的 frame 數。整段一次塞進去在長錄音時容易被丟棄，
    /// 切成約 1 秒一塊比較穩，也接近實際串流的餵法。
    const CHUNK_FRAMES: usize = 16000;

    /// 要求語音辨識授權並等待使用者回應。
    pub fn request_authorization() -> Result<(), String> {
        let (tx, rx) = mpsc::channel::<SFSpeechRecognizerAuthorizationStatus>();
        let block = RcBlock::new(move |status: SFSpeechRecognizerAuthorizationStatus| {
            let _ = tx.send(status);
        });

        unsafe {
            SFSpeechRecognizer::requestAuthorization(&block);
        }

        match rx.recv_timeout(Duration::from_secs(60)) {
            Ok(SFSpeechRecognizerAuthorizationStatus::Authorized) => Ok(()),
            Ok(SFSpeechRecognizerAuthorizationStatus::Denied) => {
                Err("使用者拒絕了語音辨識權限（系統設定 → 隱私權與安全性 → 語音辨識）".into())
            }
            Ok(SFSpeechRecognizerAuthorizationStatus::Restricted) => {
                Err("這台機器的語音辨識功能被管理原則限制".into())
            }
            Ok(_) => Err("尚未取得語音辨識授權".into()),
            Err(_) => Err("等待語音辨識授權逾時".into()),
        }
    }

    /// 目前的授權狀態是否已是 Authorized（不觸發對話框）。
    pub fn is_authorized() -> bool {
        unsafe {
            SFSpeechRecognizer::authorizationStatus()
                == SFSpeechRecognizerAuthorizationStatus::Authorized
        }
    }

    fn make_recognizer(locale_id: &str) -> Result<Retained<SFSpeechRecognizer>, String> {
        let locale =
            NSLocale::initWithLocaleIdentifier(NSLocale::alloc(), &NSString::from_str(locale_id));
        let recognizer = unsafe {
            SFSpeechRecognizer::initWithLocale(SFSpeechRecognizer::alloc(), &locale)
        }
        .ok_or_else(|| format!("系統不支援這個語言的語音辨識：{locale_id}"))?;

        if !unsafe { recognizer.isAvailable() } {
            return Err("語音辨識服務目前不可用（可能正在下載語言包，稍候再試）".into());
        }
        Ok(recognizer)
    }

    /// 把 16kHz mono f32 PCM 包成 AVAudioPCMBuffer。
    fn make_buffer(format: &AVAudioFormat, samples: &[f32]) -> Result<Retained<AVAudioPCMBuffer>, String> {
        let frames = samples.len() as u32;
        let buffer = unsafe {
            AVAudioPCMBuffer::initWithPCMFormat_frameCapacity(
                AVAudioPCMBuffer::alloc(),
                format,
                frames,
            )
        }
        .ok_or("無法配置音訊緩衝區")?;

        unsafe {
            buffer.setFrameLength(frames);
            let channels = buffer.floatChannelData();
            if channels.is_null() {
                return Err("音訊緩衝區沒有 float channel data".into());
            }
            // standard format 是 deinterleaved float32，單聲道就只有 channel 0
            let channel0 = (*channels).as_ptr();
            std::ptr::copy_nonoverlapping(samples.as_ptr(), channel0, samples.len());
        }

        Ok(buffer)
    }

    pub fn transcribe(
        pcm: &[f32],
        locale_id: &str,
        require_on_device: bool,
    ) -> Result<String, String> {
        if pcm.is_empty() {
            return Ok(String::new());
        }

        if !is_authorized() {
            request_authorization()?;
        }

        let recognizer = make_recognizer(locale_id)?;

        if require_on_device && !unsafe { recognizer.supportsOnDeviceRecognition() } {
            return Err(format!(
                "這個語言（{locale_id}）沒有離線辨識模型，關閉「僅限離線辨識」或改用本地 whisper"
            ));
        }

        let request = unsafe { SFSpeechAudioBufferRecognitionRequest::new() };
        unsafe {
            // 只要最終結果：中途的 partial 對批次辨識沒有用，還會讓 handler 被叫很多次
            request.setShouldReportPartialResults(false);
            request.setRequiresOnDeviceRecognition(require_on_device);
        }

        let format = unsafe {
            AVAudioFormat::initStandardFormatWithSampleRate_channels(
                AVAudioFormat::alloc(),
                SAMPLE_RATE,
                1,
            )
        }
        .ok_or("無法建立 16kHz 單聲道音訊格式")?;

        // resultHandler 會在任意 queue 上被呼叫，用 channel 把結果帶回這個執行緒。
        // 傳 Result 而不是只傳字串，錯誤才不會變成「等到逾時」。
        let (tx, rx) = mpsc::channel::<Result<String, String>>();
        let handler = RcBlock::new(
            move |result: *mut SFSpeechRecognitionResult, error: *mut NSError| unsafe {
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
                let text = result.bestTranscription().formattedString().to_string();
                let _ = tx.send(Ok(text));
            },
        );

        let _task = unsafe {
            recognizer.recognitionTaskWithRequest_resultHandler(&request, &handler)
        };

        // 分塊餵入後收尾。endAudio 之後辨識器才會產生 final result。
        for chunk in pcm.chunks(CHUNK_FRAMES) {
            let buffer = make_buffer(&format, chunk)?;
            unsafe { request.appendAudioPCMBuffer(&buffer) };
        }
        unsafe { request.endAudio() };

        // 逾時給「音訊長度 + 30 秒」：離線辨識通常遠快於即時，但首次使用某語言
        // 時 macOS 可能正在背景下載語言包。
        let audio_seconds = pcm.len() as f64 / SAMPLE_RATE;
        let timeout = Duration::from_secs_f64(audio_seconds + 30.0);

        match rx.recv_timeout(timeout) {
            Ok(outcome) => outcome,
            Err(_) => Err("語音辨識逾時（沒有收到最終結果）".into()),
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    const UNSUPPORTED: &str = "此平台不支援 Apple 語音辨識";

    pub fn is_authorized() -> bool {
        false
    }

    pub fn request_authorization() -> Result<(), String> {
        Err(UNSUPPORTED.into())
    }

    pub fn transcribe(
        _pcm: &[f32],
        _locale_id: &str,
        _require_on_device: bool,
    ) -> Result<String, String> {
        Err(UNSUPPORTED.into())
    }
}

/// 這個平台是否有 Apple 語音辨識。前端拿它決定要不要顯示該引擎選項。
#[tauri::command]
pub fn apple_speech_supported() -> bool {
    cfg!(target_os = "macos")
}

#[tauri::command]
pub fn apple_speech_authorized() -> bool {
    imp::is_authorized()
}

#[tauri::command]
pub fn apple_speech_authorize() -> Result<(), String> {
    imp::request_authorization()
}

/// 以 Apple Speech 辨識 raw body 帶進來的 16kHz mono little-endian f32 PCM。
///
/// 送 raw body 時整個 payload 就是那串 bytes，沒有具名參數可用，所以 locale 與
/// 離線旗標改走 invoke options 的 headers 傳進來。
#[tauri::command]
pub fn transcribe_apple(request: tauri::ipc::Request<'_>) -> Result<String, String> {
    let headers = request.headers();
    let locale = headers
        .get("locale")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("zh-TW")
        .to_string();
    let require_on_device = headers
        .get("require-on-device")
        .and_then(|v| v.to_str().ok())
        .map(|v| v == "true")
        .unwrap_or(true);

    let body = match request.body() {
        tauri::ipc::InvokeBody::Raw(bytes) => bytes,
        _ => return Err("expect raw PCM body".into()),
    };
    if body.len() % 4 != 0 {
        return Err("PCM 長度不是 4 的倍數，不是合法的 f32 資料".into());
    }

    // 位元組流轉 f32：來源是 JS 的 Float32Array，固定 little-endian。
    // 直接 transmute 會有對齊問題（Vec<u8> 不保證 4-byte 對齊），逐一組裝才安全。
    let (chunks, _) = body.as_chunks::<4>();
    let samples: Vec<f32> = chunks.iter().map(|b| f32::from_le_bytes(*b)).collect();

    imp::transcribe(&samples, &locale, require_on_device)
}

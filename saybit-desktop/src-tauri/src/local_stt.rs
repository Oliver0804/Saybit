// 本地 STT：whisper.cpp（whisper-rs），macOS Metal / Windows GPU 加速
use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager};
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

const MODEL_FILE: &str = "ggml-large-v3-turbo-q5_0.bin";
const MODEL_URL: &str =
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin";

// 模型 context 常駐快取（q5_0 約 574MB，重載成本高）
static CTX: Mutex<Option<(PathBuf, WhisperContext)>> = Mutex::new(None);

fn model_path(app: &AppHandle) -> Result<PathBuf, String> {
    let dir = app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?
        .join("models");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    Ok(dir.join(MODEL_FILE))
}

#[tauri::command]
pub fn local_stt_status(app: AppHandle) -> Result<serde_json::Value, String> {
    let path = model_path(&app)?;
    let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
    Ok(serde_json::json!({
        // 模型檔完整性粗檢：q5_0 應 >500MB，避免半截檔被當可用
        "present": size > 500_000_000,
        "path": path.to_string_lossy(),
        "sizeBytes": size,
    }))
}

#[tauri::command]
pub async fn download_stt_model(app: AppHandle) -> Result<(), String> {
    use futures_util::StreamExt;
    let path = model_path(&app)?;
    let tmp = path.with_extension("part");

    let client = reqwest::Client::new();
    let resp = client
        .get(MODEL_URL)
        .send()
        .await
        .map_err(|e| format!("下載請求失敗: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("下載失敗 HTTP {}", resp.status()));
    }
    let total = resp.content_length().unwrap_or(0);

    let mut file = std::fs::File::create(&tmp).map_err(|e| e.to_string())?;
    let mut stream = resp.bytes_stream();
    let mut downloaded: u64 = 0;
    let mut last_emit = std::time::Instant::now();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| format!("下載中斷: {e}"))?;
        file.write_all(&chunk).map_err(|e| e.to_string())?;
        downloaded += chunk.len() as u64;
        if last_emit.elapsed().as_millis() > 200 {
            let _ = app.emit(
                "stt-model-progress",
                serde_json::json!({"downloaded": downloaded, "total": total}),
            );
            last_emit = std::time::Instant::now();
        }
    }
    drop(file);
    std::fs::rename(&tmp, &path).map_err(|e| e.to_string())?;
    let _ = app.emit(
        "stt-model-progress",
        serde_json::json!({"downloaded": downloaded, "total": total, "done": true}),
    );
    Ok(())
}

#[tauri::command]
pub fn transcribe_local(app: AppHandle, request: tauri::ipc::Request<'_>) -> Result<String, String> {
    // body 為 16kHz mono little-endian f32 PCM
    let body = match request.body() {
        tauri::ipc::InvokeBody::Raw(b) => b.clone(),
        _ => return Err("expect raw PCM body".into()),
    };
    if body.len() < 16_000 {
        return Err("音訊太短".into());
    }
    let samples: Vec<f32> = body
        .chunks_exact(4)
        .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect();

    let path = model_path(&app)?;
    if !path.exists() {
        return Err("本地模型未下載，請到設定 → STT 供應商下載".into());
    }

    let mut guard = CTX.lock().map_err(|e| e.to_string())?;
    let need_load = guard.as_ref().map(|(p, _)| p != &path).unwrap_or(true);
    if need_load {
        let ctx = WhisperContext::new_with_params(
            path.to_string_lossy().as_ref(),
            WhisperContextParameters::default(),
        )
        .map_err(|e| format!("模型載入失敗: {e}"))?;
        *guard = Some((path.clone(), ctx));
    }
    let (_, ctx) = guard.as_ref().unwrap();

    let mut state = ctx.create_state().map_err(|e| e.to_string())?;
    let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
    params.set_language(Some("zh"));
    params.set_initial_prompt("以下是繁體中文（台灣）的語音逐字稿。");
    params.set_print_special(false);
    params.set_print_progress(false);
    params.set_print_realtime(false);
    params.set_print_timestamps(false);
    let n_threads = std::thread::available_parallelism()
        .map(|n| n.get() as i32)
        .unwrap_or(4)
        .min(8);
    params.set_n_threads(n_threads);

    state
        .full(params, &samples)
        .map_err(|e| format!("轉錄失敗: {e}"))?;

    let n = state.full_n_segments();
    let mut out = String::new();
    for i in 0..n {
        if let Some(seg) = state.get_segment(i) {
            if let Ok(text) = seg.to_str_lossy() {
                out.push_str(&text);
            }
        }
    }
    Ok(out.trim().to_string())
}

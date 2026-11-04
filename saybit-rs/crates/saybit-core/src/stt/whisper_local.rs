//! 本地 whisper.cpp（移植 saybit-desktop/src-tauri/src/local_stt.rs）。批次：錄音中只累積，finish 才整段辨識。
//! 模型 context 常駐快取（q5_0 約 574 MB，重載成本高）；刪除模型時 `unload()`。
//! 送辨識前過能量門檻、辨識後過幻聽過濾（whisper 對靜音會吐字幕殘留）。

use crate::models::{ModelManager, WHISPER_FILES};
use crate::stt::{artifacts, whisper_language, whisper_prompt, BufferedSession};
use crate::types::*;
use std::path::PathBuf;
use std::sync::Mutex;
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

pub const MSG_MODEL_MISSING: &str = "尚未下載本地 whisper 模型，請到設定下載";

static CTX: Mutex<Option<(PathBuf, WhisperContext)>> = Mutex::new(None);

/// 釋放常駐的 whisper context
pub fn unload() {
    if let Ok(mut g) = CTX.lock() {
        *g = None;
    }
}

pub struct Engine {
    model_dir: PathBuf,
    language_preference: String,
}

impl Engine {
    pub fn new(settings: &Settings, _secret: &dyn Fn(&str) -> Option<String>) -> Self {
        Self {
            model_dir: ModelManager::new().dir(ModelKind::WhisperLocal),
            language_preference: settings.language_preference.clone(),
        }
    }
}

impl SttEngine for Engine {
    fn kind(&self) -> SttEngineKind {
        SttEngineKind::WhisperLocal
    }

    fn unavailable_reason(&self) -> Option<String> {
        if crate::models::is_installed_in(&self.model_dir, ModelKind::WhisperLocal) {
            None
        } else {
            Some(MSG_MODEL_MISSING.into())
        }
    }

    fn start(&self, opts: SttStartOptions) -> anyhow::Result<Box<dyn SttSession>> {
        if let Some(reason) = self.unavailable_reason() {
            anyhow::bail!(reason);
        }
        let model = self.model_dir.join(WHISPER_FILES[0].name);
        let language = whisper_language(&opts.language);
        let prompt = whisper_prompt(&opts.language, &self.language_preference, &opts.hint_terms);
        Ok(BufferedSession::boxed(move |pcm| transcribe(&model, &pcm, language.as_deref(), &prompt)))
    }
}

pub fn transcribe(model: &std::path::Path, samples: &[f32], language: Option<&str>, prompt: &str) -> anyhow::Result<String> {
    // 不到 0.5 秒或幾乎沒聲音：不送（whisper 會幻聽）
    if samples.len() < 8_000 || !artifacts::has_enough_energy(samples) {
        return Ok(String::new());
    }
    let mut guard = CTX.lock().map_err(|_| anyhow::anyhow!("whisper context 鎖已損毀"))?;
    if guard.as_ref().is_none_or(|(p, _)| p != model) {
        *guard = None;
        let ctx = WhisperContext::new_with_params(model, WhisperContextParameters::default())
            .map_err(|e| anyhow::anyhow!("本地模型載入失敗：{e}"))?;
        *guard = Some((model.to_path_buf(), ctx));
    }
    let (_, ctx) = guard.as_ref().expect("whisper context");
    let mut state = ctx.create_state().map_err(|e| anyhow::anyhow!("{e}"))?;
    let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
    params.set_language(language);
    if !prompt.is_empty() {
        params.set_initial_prompt(prompt);
    }
    params.set_print_special(false);
    params.set_print_progress(false);
    params.set_print_realtime(false);
    params.set_print_timestamps(false);
    let n_threads = std::thread::available_parallelism().map(|n| n.get() as i32).unwrap_or(4).min(8);
    params.set_n_threads(n_threads);
    state.full(params, samples).map_err(|e| anyhow::anyhow!("轉錄失敗：{e}"))?;

    let mut out = String::new();
    for i in 0..state.full_n_segments() {
        if let Some(seg) = state.get_segment(i) {
            if let Ok(text) = seg.to_str_lossy() {
                out.push_str(&text);
            }
        }
    }
    let text = out.trim().to_string();
    Ok(if artifacts::is_known_artifact(&text) { String::new() } else { text })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn silence_never_reaches_model() {
        // 模型檔不存在也不會報錯：能量不足直接回空字串
        let missing = std::path::Path::new("/nonexistent/ggml.bin");
        assert_eq!(transcribe(missing, &vec![0.001; 32_000], Some("zh"), "").unwrap(), "");
        assert_eq!(transcribe(missing, &[0.5; 100], Some("zh"), "").unwrap(), "");
        assert!(transcribe(missing, &vec![0.3; 32_000], Some("zh"), "").is_err());
    }
}

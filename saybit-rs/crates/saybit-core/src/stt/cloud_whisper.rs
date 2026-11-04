//! 雲端 Whisper（OpenAI / Groq / 自訂 OpenAI 相容端點），移植 saybit-desktop/src/services/llm.ts 的 transcribeAudio。
//! 批次：finish 時把整段 16 kHz PCM 包成 WAV，multipart 上傳 `{base}/audio/transcriptions`。
//! 遠端端點必須是 HTTPS（localhost 例外），否則不送 key。

use crate::stt::{artifacts, pcm_to_wav, whisper_language, whisper_prompt, BufferedSession};
use crate::types::*;
use std::time::Duration;

pub struct Engine {
    provider: String,
    base_url: String,
    model: String,
    key: Option<String>,
    language_preference: String,
}

pub fn default_base_url(provider: &str) -> &'static str {
    match provider {
        "groq" => "https://api.groq.com/openai/v1",
        _ => "https://api.openai.com/v1",
    }
}

pub fn default_model(provider: &str) -> &'static str {
    match provider {
        "groq" => "whisper-large-v3",
        _ => "whisper-1",
    }
}

/// 遠端必須 HTTPS；http 只允許本機（避免 key 明文外流）
pub fn validate_base_url(url: &str) -> Result<(), String> {
    let u = url.trim().to_ascii_lowercase();
    if u.starts_with("https://") {
        return Ok(());
    }
    if let Some(rest) = u.strip_prefix("http://") {
        let host = rest.split(['/', '?', '#']).next().unwrap_or("");
        let host = if host.starts_with('[') {
            host.split(']').next().map(|h| format!("{h}]")).unwrap_or_default()
        } else {
            host.split(':').next().unwrap_or("").to_string()
        };
        if matches!(host.as_str(), "localhost" | "127.0.0.1" | "[::1]") {
            return Ok(());
        }
        return Err(format!("STT 端點必須使用 HTTPS（{url}）"));
    }
    Err(format!("STT 端點格式錯誤（{url}）"))
}

impl Engine {
    pub fn new(settings: &Settings, secret: &dyn Fn(&str) -> Option<String>) -> Self {
        let provider = match settings.whisper_cloud_provider.as_str() {
            p @ ("openai" | "groq" | "custom") => p.to_string(),
            _ => "openai".to_string(),
        };
        let base_url = if settings.whisper_cloud_base_url.trim().is_empty() {
            default_base_url(&provider).to_string()
        } else {
            settings.whisper_cloud_base_url.trim().to_string()
        };
        let model = if settings.whisper_cloud_model.trim().is_empty() {
            default_model(&provider).to_string()
        } else {
            settings.whisper_cloud_model.trim().to_string()
        };
        let key = secret(&format!("stt.{provider}")).filter(|k| !k.trim().is_empty());
        Self { provider, base_url, model, key, language_preference: settings.language_preference.clone() }
    }

    pub(crate) fn has_key(&self) -> bool {
        self.key.is_some()
    }
}

impl SttEngine for Engine {
    fn kind(&self) -> SttEngineKind {
        SttEngineKind::CloudWhisper
    }

    fn unavailable_reason(&self) -> Option<String> {
        if self.key.is_none() {
            return Some(format!("未設定 STT API Key（{}），請前往設定填入（或改用離線辨識）", self.provider));
        }
        validate_base_url(&self.base_url).err()
    }

    fn start(&self, opts: SttStartOptions) -> anyhow::Result<Box<dyn SttSession>> {
        if let Some(reason) = self.unavailable_reason() {
            anyhow::bail!(reason);
        }
        let key = self.key.clone().unwrap_or_default();
        let url = format!("{}/audio/transcriptions", self.base_url.trim_end_matches('/'));
        let model = self.model.clone();
        // API 只收 ISO 639-1：粵語（yue）沒有兩碼，退回 zh
        let language = whisper_language(&opts.language).map(|l| if l == "yue" { "zh".to_string() } else { l });
        let prompt = whisper_prompt(&opts.language, &self.language_preference, &opts.hint_terms);
        Ok(BufferedSession::boxed(move |pcm| {
            if !artifacts::has_enough_energy(&pcm) {
                return Ok(String::new());
            }
            let text = transcribe(&url, &key, &model, language.as_deref(), &prompt, &pcm)?;
            Ok(if artifacts::is_known_artifact(&text) { String::new() } else { text })
        }))
    }
}

pub fn multipart_body(boundary: &str, wav: &[u8], fields: &[(&str, &str)]) -> Vec<u8> {
    let mut body = Vec::with_capacity(wav.len() + 1024);
    for (name, value) in fields {
        body.extend_from_slice(
            format!("--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n").as_bytes(),
        );
    }
    body.extend_from_slice(
        format!(
            "--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n"
        )
        .as_bytes(),
    );
    body.extend_from_slice(wav);
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
    body
}

pub fn transcribe(url: &str, key: &str, model: &str, language: Option<&str>, prompt: &str, pcm: &[f32]) -> anyhow::Result<String> {
    let wav = pcm_to_wav(pcm, 16_000);
    let boundary = format!("saybit-{}", uuid::Uuid::new_v4().simple());
    let mut fields: Vec<(&str, &str)> = vec![("model", model), ("response_format", "json")];
    if let Some(l) = language {
        fields.push(("language", l));
    }
    if !prompt.is_empty() {
        fields.push(("prompt", prompt));
    }
    let body = multipart_body(&boundary, &wav, &fields);

    let agent: ureq::Agent = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(90)))
        .http_status_as_error(false)
        .build()
        .into();
    let mut resp = agent
        .post(url)
        .header("Authorization", &format!("Bearer {key}"))
        .header("Content-Type", &format!("multipart/form-data; boundary={boundary}"))
        .send(&body[..])
        .map_err(|e| anyhow::anyhow!("STT 連線失敗：{e}"))?;
    let status = resp.status().as_u16();
    let text = resp.body_mut().read_to_string().unwrap_or_default();
    match status {
        200..=299 => {}
        401 => anyhow::bail!("STT 401：key 與供應商不符（OpenAI 需 sk-...，Groq 需 gsk_...），請到設定確認。"),
        429 => anyhow::bail!("STT 429：該帳號額度不足。OpenAI 需綁卡儲值；或切換到 Groq 免費 STT 或離線辨識。"),
        _ => {
            let snippet: String = text.chars().take(200).collect();
            anyhow::bail!("STT API 錯誤：{status} - {snippet}")
        }
    }
    let v: serde_json::Value = serde_json::from_str(&text).map_err(|e| anyhow::anyhow!("STT 回應格式錯誤：{e}"))?;
    Ok(v.get("text").and_then(|t| t.as_str()).unwrap_or("").trim().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base_url_policy() {
        assert!(validate_base_url("https://api.openai.com/v1").is_ok());
        assert!(validate_base_url("http://localhost:8080/v1").is_ok());
        assert!(validate_base_url("http://127.0.0.1/v1").is_ok());
        assert!(validate_base_url("http://[::1]:9000/v1").is_ok());
        assert!(validate_base_url("http://example.com/v1").is_err());
        assert!(validate_base_url("http://localhost.evil.com/v1").is_err());
        assert!(validate_base_url("ftp://x").is_err());
    }

    #[test]
    fn engine_reads_provider_key_and_defaults() {
        let s = Settings { whisper_cloud_provider: "groq".into(), whisper_cloud_base_url: "".into(), whisper_cloud_model: "".into(), ..Default::default() };
        let e = Engine::new(&s, &|acc| (acc == "stt.groq").then(|| "gsk_x".to_string()));
        assert_eq!(e.base_url, "https://api.groq.com/openai/v1");
        assert_eq!(e.model, "whisper-large-v3");
        assert!(e.unavailable_reason().is_none());
        let e = Engine::new(&Settings::default(), &|_| Some("   ".into()));
        assert!(e.unavailable_reason().is_some());
    }

    #[test]
    fn multipart_shape() {
        let body = multipart_body("B", b"WAV", &[("model", "whisper-1")]);
        let s = String::from_utf8(body).unwrap();
        assert!(s.starts_with("--B\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n"));
        assert!(s.contains("filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\nWAV\r\n--B--\r\n"));
    }

    #[test]
    fn silent_audio_is_not_uploaded() {
        let s = Settings { whisper_cloud_base_url: "https://127.0.0.1:1/v1".into(), ..Default::default() };
        let e = Engine::new(&s, &|_| Some("sk-test".into()));
        let mut session = e
            .start(SttStartOptions { language: "zh".into(), hint_terms: vec![], on_partial: None })
            .unwrap();
        session.push(&vec![0.001; 16_000]);
        // 若真的送出會連線失敗回 Err；能量不足應直接回空字串
        assert_eq!(session.finish().unwrap(), "");
    }
}

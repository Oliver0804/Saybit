//! OpenAI 相容 chat/completions 串流（SSE）。阻塞式 ureq；Apple 本機模型不在 Rust 版。
use crate::settings::{base_url_validation_message, validate_base_url};
use crate::types::*;
use crossbeam_channel::{Receiver, RecvTimeoutError};
use std::io::BufRead;
use std::time::{Duration, Instant};

const MAX_RETRIES: u32 = 3;
const RETRYABLE: &[u16] = &[429, 500, 502, 503, 504];
const POLL: Duration = Duration::from_millis(50);
const ERROR_BODY_LIMIT: usize = 4096;

/// 阻塞式 OpenAI 相容 client。實際 HTTP 在背景執行緒進行，呼叫端每 50 ms 檢查取消，
/// 所以 cancel 置位後最慢 ~50 ms 返回（背景執行緒在下一行到達或逾時後自行結束）。
#[derive(Clone)]
pub struct LlmClient {
    agent: ureq::Agent,
    /// 非串流請求（測試連線、列模型）的逾時
    short_agent: ureq::Agent,
}

impl LlmClient {
    pub fn new() -> Self {
        let agent = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_connect(Some(Duration::from_secs(15)))
            .timeout_recv_response(Some(Duration::from_secs(60)))
            .timeout_recv_body(Some(Duration::from_secs(300)))
            .build()
            .new_agent();
        let short_agent = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_global(Some(Duration::from_secs(15)))
            .build()
            .new_agent();
        LlmClient { agent, short_agent }
    }

    /// 串流聊天：每個 delta / usage 呼叫 on_event；cancel 置位後盡快回 Err(Cancelled)。
    /// 送出前必須 `settings::validate_base_url`；非 2xx 讀 body 前 4KB 進錯誤；SSE 中的 {"error":…} 也要 throw。
    #[allow(clippy::too_many_arguments)]
    pub fn stream_chat(
        &self,
        provider: &LlmProvider,
        api_key: Option<&str>,
        model: &str,
        system_prompt: &str,
        user_message: &str,
        opts: &LlmRequestOptions,
        cancel: &CancelToken,
        on_event: &mut dyn FnMut(LlmStreamEvent),
    ) -> anyhow::Result<()> {
        let key = check_endpoint_and_key(provider, api_key)?;
        let url = provider.base_url.trim().to_string();
        let is_custom = provider.id.starts_with("custom-");
        let mut use_stream_options = provider.id != "lmstudio" && provider.id != "ollama";
        let mut skip_delay = false;

        for attempt in 0..=MAX_RETRIES {
            if attempt > 0 && !skip_delay {
                sleep_cancellable(retry_delay(attempt - 1), cancel)?;
            }
            skip_delay = false;
            if cancel.is_cancelled() {
                return Err(LlmError::Cancelled.into());
            }
            let body = chat_body(provider, model, system_prompt, user_message, opts, true, use_stream_options);
            let rx = spawn_request(self.agent.clone(), url.clone(), headers(provider, &key), body);

            let status = match wait(&rx, cancel)? {
                Wire::Status(s) => s,
                Wire::Failed(e) => return Err(LlmError::Network(e).into()),
                _ => return Err(LlmError::Network("連線中斷".into()).into()),
            };

            if status == 400 && is_custom && use_stream_options && attempt < MAX_RETRIES {
                crate::logging::log(LogLevel::Info, "LLM", "自訂端點回 400，改為不送 stream_options 重試");
                use_stream_options = false;
                skip_delay = true;
                continue;
            }
            if !(200..300).contains(&status) {
                let body = match wait(&rx, cancel)? {
                    Wire::ErrBody(b) => b,
                    _ => String::new(),
                };
                if RETRYABLE.contains(&status) {
                    if attempt < MAX_RETRIES {
                        continue;
                    }
                    if !body.is_empty() {
                        crate::logging::log(
                            LogLevel::Error,
                            "LLM",
                            format!("LLM 重試耗盡，最後回應: {}", extract_error_message(&body)),
                        );
                    }
                    return Err(LlmError::RetriesExhausted { status, attempts: MAX_RETRIES + 1 }.into());
                }
                return Err(LlmError::Http { status, detail: extract_error_message(&body) }.into());
            }

            // 2xx → 逐行解析 SSE
            let mut received = false;
            loop {
                match wait(&rx, cancel)? {
                    Wire::Line(line) => match parse_sse_line(&line) {
                        SseItem::Skip => {}
                        SseItem::Done => break,
                        SseItem::Error(msg) => {
                            crate::logging::log(
                                LogLevel::Error,
                                "LLM",
                                format!("LLM stream 收到伺服器錯誤: {}", truncate_chars(&msg, 200)),
                            );
                            return Err(LlmError::Stream(msg).into());
                        }
                        SseItem::Events(events) => {
                            for ev in events {
                                if matches!(ev, LlmStreamEvent::Delta(_)) {
                                    received = true;
                                }
                                on_event(ev);
                            }
                        }
                    },
                    Wire::End => break,
                    Wire::Failed(e) => return Err(LlmError::Network(e).into()),
                    Wire::Status(_) | Wire::ErrBody(_) => {}
                }
            }
            if cancel.is_cancelled() {
                return Err(LlmError::Cancelled.into());
            }
            if !received {
                crate::logging::log(LogLevel::Error, "LLM", format!("LLM stream 完成但無內容 (provider={})", provider.id));
            }
            return Ok(());
        }
        Err(LlmError::RetriesExhausted { status: 0, attempts: MAX_RETRIES + 1 }.into())
    }

    /// 非串流收集全文（Stage 1 / 動作解析用）；回 (全文, usage)
    #[allow(clippy::too_many_arguments)]
    pub fn complete(
        &self,
        provider: &LlmProvider,
        api_key: Option<&str>,
        model: &str,
        system_prompt: &str,
        user_message: &str,
        opts: &LlmRequestOptions,
        cancel: &CancelToken,
    ) -> anyhow::Result<(String, TokenUsage)> {
        let mut text = String::new();
        let mut usage = TokenUsage::default();
        self.stream_chat(provider, api_key, model, system_prompt, user_message, opts, cancel, &mut |ev| match ev {
            LlmStreamEvent::Delta(d) => text.push_str(&d),
            LlmStreamEvent::Usage(u) => usage = u,
        })?;
        Ok((text, usage))
    }

    /// 最小請求驗證 key / 模型（含重試）
    pub fn test_connection(&self, provider: &LlmProvider, api_key: Option<&str>, model: &str) -> anyhow::Result<()> {
        let key = check_endpoint_and_key(provider, api_key)?;
        let body = serde_json::json!({
            "model": model,
            "messages": [{"role": "user", "content": "Hi"}],
            "stream": false,
            "temperature": 0,
        });
        let body = serde_json::to_vec(&body)?;
        for attempt in 0..=MAX_RETRIES {
            if attempt > 0 {
                std::thread::sleep(retry_delay(attempt - 1));
            }
            let mut req = self.short_agent.post(provider.base_url.trim());
            for (k, v) in headers(provider, &key) {
                req = req.header(k.as_str(), v.as_str());
            }
            let resp = req.send(&body[..]).map_err(|e| LlmError::Network(e.to_string()))?;
            let status = resp.status().as_u16();
            if (200..300).contains(&status) {
                return Ok(());
            }
            if RETRYABLE.contains(&status) {
                if attempt < MAX_RETRIES {
                    continue;
                }
                return Err(LlmError::RetriesExhausted { status, attempts: MAX_RETRIES + 1 }.into());
            }
            let body = read_limited(resp.into_body().into_reader());
            return Err(LlmError::Http { status, detail: extract_error_message(&body) }.into());
        }
        Ok(())
    }

    /// 可用模型清單：Ollama 走 /api/tags；LM Studio 先試 /api/v1/models（只取 llm）；其他走 OpenAI 相容 /models
    pub fn list_models(&self, provider: &LlmProvider, api_key: Option<&str>) -> anyhow::Result<Vec<String>> {
        if let Some(msg) = base_url_validation_message(validate_base_url(&provider.base_url), &provider.base_url) {
            return Err(LlmError::InsecureEndpoint(msg).into());
        }
        let key = api_key.unwrap_or("").to_string();
        let origin = super::providers::origin(&provider.base_url);
        if provider.id == "ollama" {
            if let Some(o) = &origin {
                let v = self.get_json(&format!("{o}/api/tags"), provider, &key)?;
                let mut names: Vec<String> = v["models"]
                    .as_array()
                    .map(|a| a.iter().filter_map(|m| m["name"].as_str().map(String::from)).collect())
                    .unwrap_or_default();
                names.sort();
                return Ok(names);
            }
        }
        if provider.id == "lmstudio" {
            if let Some(o) = &origin {
                if let Ok(v) = self.get_json(&format!("{o}/api/v1/models"), provider, &key) {
                    if let Some(arr) = v["models"].as_array() {
                        return Ok(arr
                            .iter()
                            .filter(|m| m["type"].as_str() == Some("llm"))
                            .filter_map(|m| m["key"].as_str().map(String::from))
                            .collect());
                    }
                }
            }
        }
        let endpoint = super::providers::models_endpoint(&provider.base_url)
            .ok_or_else(|| anyhow::anyhow!("無法解析 models 端點：{}", provider.base_url))?;
        let v = self.get_json(&endpoint, provider, &key)?;
        let mut ids: Vec<String> = v["data"]
            .as_array()
            .map(|a| a.iter().filter_map(|m| m["id"].as_str().map(String::from)).collect())
            .unwrap_or_default();
        ids.sort();
        Ok(ids)
    }

    fn get_json(&self, url: &str, provider: &LlmProvider, key: &str) -> anyhow::Result<serde_json::Value> {
        let mut req = self.short_agent.get(url);
        for (k, v) in headers(provider, key) {
            req = req.header(k.as_str(), v.as_str());
        }
        let resp = req.call().map_err(|e| LlmError::Network(e.to_string()))?;
        let status = resp.status().as_u16();
        let body = read_limited_n(resp.into_body().into_reader(), 8 * 1024 * 1024);
        if !(200..300).contains(&status) {
            return Err(LlmError::Http { status, detail: extract_error_message(&body) }.into());
        }
        Ok(serde_json::from_str(&body)?)
    }
}

impl Default for LlmClient { fn default() -> Self { Self::new() } }

#[derive(Debug, thiserror::Error)]
pub enum LlmError {
    #[error("未設定 {0} API Key")] NoApiKey(String),
    #[error("{0}")] InsecureEndpoint(String),
    #[error("HTTP {status}：{detail}")] Http { status: u16, detail: String },
    #[error("AI 服務回報錯誤：{0}")] Stream(String),
    #[error("已取消")] Cancelled,
    #[error("網路錯誤：{0}")] Network(String),
    #[error("重試 {attempts} 次後仍失敗（{}）", humanize_status(*status))] RetriesExhausted { status: u16, attempts: u32 },
}

/// 判斷錯誤是不是使用者取消（不是錯誤，不顯示）
pub fn is_cancelled(err: &anyhow::Error) -> bool {
    matches!(err.downcast_ref::<LlmError>(), Some(LlmError::Cancelled))
}

/// HTTP status 翻成使用者看得懂的訊息
pub fn humanize_status(code: u16) -> String {
    match code {
        400 => "HTTP 400：請求格式錯誤（可能是模型名稱不正確或參數不被支援）".into(),
        401 => "HTTP 401：API Key 無效或已失效".into(),
        402 => "HTTP 402：餘額不足，請至服務商儲值".into(),
        403 => "HTTP 403：權限不足（可能是模型未授權）".into(),
        404 => "HTTP 404：模型不存在或端點錯誤".into(),
        408 => "HTTP 408：請求逾時".into(),
        413 => "HTTP 413：請求內容過大".into(),
        429 => "HTTP 429：超過速率限制，稍候再試".into(),
        500 => "HTTP 500：服務商內部錯誤".into(),
        502 => "HTTP 502：上游服務無回應".into(),
        503 => "HTTP 503：服務暫時不可用".into(),
        504 => "HTTP 504：上游逾時".into(),
        c => format!("HTTP {c}：API 回應錯誤"),
    }
}

/// 端點檢查必須在用 key 之前：不安全 / 無效端點一律不送 key。回實際要送的 key（可為空字串）。
fn check_endpoint_and_key(provider: &LlmProvider, api_key: Option<&str>) -> Result<String, LlmError> {
    if let Some(msg) = base_url_validation_message(validate_base_url(&provider.base_url), &provider.base_url) {
        return Err(LlmError::InsecureEndpoint(msg));
    }
    let key = api_key.map(str::trim).unwrap_or("").to_string();
    if provider.requires_api_key && key.is_empty() {
        return Err(LlmError::NoApiKey(provider.name.clone()));
    }
    Ok(key)
}

fn headers(provider: &LlmProvider, key: &str) -> Vec<(String, String)> {
    let mut h = vec![("Content-Type".to_string(), "application/json".to_string())];
    if !key.is_empty() {
        h.push(("Authorization".into(), format!("Bearer {key}")));
    }
    h.extend(provider.extra_headers.iter().cloned());
    h
}

/// 只對文件明確支援 `response_format: json_object` 的服務商送（LM Studio 等會回 400）
fn supports_json_mode(provider_id: &str) -> bool {
    matches!(provider_id, "openai" | "deepseek" | "groq")
}

fn chat_body(
    provider: &LlmProvider,
    model: &str,
    system_prompt: &str,
    user_message: &str,
    opts: &LlmRequestOptions,
    stream: bool,
    stream_options: bool,
) -> Vec<u8> {
    let mut body = serde_json::json!({
        "model": model,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_message},
        ],
        "stream": stream,
    });
    let obj = body.as_object_mut().expect("object");
    if let Some(t) = opts.temperature {
        obj.insert("temperature".into(), serde_json::json!(round2(t)));
    }
    if stream && stream_options {
        obj.insert("stream_options".into(), serde_json::json!({"include_usage": true}));
    }
    if let Some(m) = opts.max_tokens {
        obj.insert("max_tokens".into(), serde_json::json!(m));
    }
    if let Some(p) = opts.top_p {
        obj.insert("top_p".into(), serde_json::json!(round2(p)));
    }
    if opts.json_mode && supports_json_mode(&provider.id) {
        obj.insert("response_format".into(), serde_json::json!({"type": "json_object"}));
    }
    serde_json::to_vec(&body).unwrap_or_default()
}

/// f32 → f64 會變 0.30000001192…，送出前四捨五入
fn round2(v: f32) -> f64 {
    (v as f64 * 100.0).round() / 100.0
}

/// 指數退避 1s → 2s → 4s，加 0–0.5s 抖動
fn retry_delay(attempt: u32) -> Duration {
    let jitter = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos() % 500)
        .unwrap_or(0);
    Duration::from_secs(1u64 << attempt.min(4)) + Duration::from_millis(jitter as u64)
}

fn sleep_cancellable(d: Duration, cancel: &CancelToken) -> Result<(), LlmError> {
    let until = Instant::now() + d;
    while Instant::now() < until {
        if cancel.is_cancelled() {
            return Err(LlmError::Cancelled);
        }
        std::thread::sleep(POLL.min(until.saturating_duration_since(Instant::now())));
    }
    Ok(())
}

#[derive(Debug)]
enum Wire {
    Status(u16),
    ErrBody(String),
    Line(String),
    End,
    Failed(String),
}

/// 背景執行緒送請求並把狀態碼 / 每一行丟回 channel；接收端丟掉後下一行就結束（關閉連線）
fn spawn_request(agent: ureq::Agent, url: String, headers: Vec<(String, String)>, body: Vec<u8>) -> Receiver<Wire> {
    let (tx, rx) = crossbeam_channel::unbounded();
    std::thread::Builder::new()
        .name("saybit-llm-http".into())
        .spawn(move || {
            let mut req = agent.post(&url);
            for (k, v) in &headers {
                req = req.header(k.as_str(), v.as_str());
            }
            let resp = match req.send(&body[..]) {
                Ok(r) => r,
                Err(e) => {
                    let _ = tx.send(Wire::Failed(e.to_string()));
                    return;
                }
            };
            let status = resp.status().as_u16();
            if tx.send(Wire::Status(status)).is_err() {
                return;
            }
            let reader = resp.into_body().into_reader();
            if !(200..300).contains(&status) {
                let _ = tx.send(Wire::ErrBody(read_limited(reader)));
                return;
            }
            let mut reader = std::io::BufReader::new(reader);
            let mut buf = Vec::new();
            loop {
                buf.clear();
                match reader.read_until(b'\n', &mut buf) {
                    Ok(0) => {
                        let _ = tx.send(Wire::End);
                        return;
                    }
                    Ok(_) => {
                        let line = String::from_utf8_lossy(&buf).into_owned();
                        if tx.send(Wire::Line(line)).is_err() {
                            return;
                        }
                    }
                    Err(e) => {
                        let _ = tx.send(Wire::Failed(e.to_string()));
                        return;
                    }
                }
            }
        })
        .ok();
    rx
}

fn wait(rx: &Receiver<Wire>, cancel: &CancelToken) -> Result<Wire, LlmError> {
    loop {
        if cancel.is_cancelled() {
            return Err(LlmError::Cancelled);
        }
        match rx.recv_timeout(POLL) {
            Ok(w) => return Ok(w),
            Err(RecvTimeoutError::Timeout) => continue,
            Err(RecvTimeoutError::Disconnected) => return Ok(Wire::End),
        }
    }
}

fn read_limited(r: impl std::io::Read) -> String {
    read_limited_n(r, ERROR_BODY_LIMIT)
}

fn read_limited_n(r: impl std::io::Read, limit: usize) -> String {
    use std::io::Read;
    let mut buf = Vec::new();
    let _ = r.take(limit as u64).read_to_end(&mut buf);
    String::from_utf8_lossy(&buf).into_owned()
}

fn truncate_chars(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

/// 一行 SSE 的解析結果
#[derive(Debug, Clone, PartialEq)]
pub enum SseItem {
    Skip,
    Done,
    Events(Vec<LlmStreamEvent>),
    Error(String),
}

/// `{"error": …}` 可能是物件（message / code，code 可為數字或字串）或單純字串
fn error_message(v: &serde_json::Value) -> Option<String> {
    let err = v.get("error")?;
    if err.is_null() {
        return None;
    }
    if let Some(s) = err.as_str() {
        return Some(s.trim().to_string()).filter(|s| !s.is_empty()).or(Some("unknown error".into()));
    }
    let msg = err.get("message").and_then(|m| m.as_str()).map(str::trim).unwrap_or("");
    if !msg.is_empty() {
        return Some(msg.to_string());
    }
    match err.get("code") {
        Some(serde_json::Value::Number(n)) => Some(format!("error {n}")),
        Some(serde_json::Value::String(s)) => Some(format!("error {s}")),
        _ => Some("unknown error".into()),
    }
}

/// 解析一行 SSE：`data: {...}`、`data: [DONE]`、註解、非 SSE 的錯誤 JSON
pub fn parse_sse_line(line: &str) -> SseItem {
    let line = line.trim_end_matches(['\r', '\n']);
    let Some(rest) = line.strip_prefix("data:") else {
        let t = line.trim();
        if t.starts_with('{') {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(t) {
                if let Some(m) = error_message(&v) {
                    return SseItem::Error(m);
                }
            }
        }
        return SseItem::Skip;
    };
    let payload = rest.trim();
    if payload == "[DONE]" {
        return SseItem::Done;
    }
    let Ok(v) = serde_json::from_str::<serde_json::Value>(payload) else { return SseItem::Skip };
    if let Some(m) = error_message(&v) {
        return SseItem::Error(m);
    }
    let mut events = Vec::new();
    if let Some(content) = v["choices"][0]["delta"]["content"].as_str() {
        if !content.is_empty() {
            events.push(LlmStreamEvent::Delta(content.to_string()));
        }
    }
    let u = &v["usage"];
    if u.is_object() {
        let n = |k: &str| u[k].as_u64().unwrap_or(0) as u32;
        events.push(LlmStreamEvent::Usage(TokenUsage {
            prompt_tokens: n("prompt_tokens"),
            completion_tokens: n("completion_tokens"),
            total_tokens: n("total_tokens"),
        }));
    }
    if events.is_empty() { SseItem::Skip } else { SseItem::Events(events) }
}

/// 從錯誤回應 body 取 `error.message`（OpenAI 相容），取不到回前 200 字
pub fn extract_error_message(body: &str) -> String {
    let t = body.trim();
    if t.is_empty() {
        return String::new();
    }
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(t) {
        if let Some(m) = error_message(&v) {
            return truncate_chars(&m, 200);
        }
    }
    truncate_chars(t, 200)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn llm_sse_parse_delta_usage_done() {
        assert_eq!(
            parse_sse_line("data: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}\n"),
            SseItem::Events(vec![LlmStreamEvent::Delta("你好".into())])
        );
        assert_eq!(parse_sse_line("data:[DONE]"), SseItem::Done);
        assert_eq!(parse_sse_line("data: [DONE]\r\n"), SseItem::Done);
        assert_eq!(parse_sse_line(": OPENROUTER PROCESSING"), SseItem::Skip);
        assert_eq!(parse_sse_line(""), SseItem::Skip);
        assert_eq!(parse_sse_line("data: {not json"), SseItem::Skip);
        assert_eq!(parse_sse_line("data: {\"choices\":[{\"delta\":{}}]}"), SseItem::Skip);
        let u = parse_sse_line(
            "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5,\"total_tokens\":15}}",
        );
        assert_eq!(
            u,
            SseItem::Events(vec![LlmStreamEvent::Usage(TokenUsage { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 })])
        );
    }

    #[test]
    fn llm_sse_parse_error_objects() {
        assert_eq!(
            parse_sse_line("data: {\"error\":{\"message\":\"Provider returned error\",\"code\":502}}"),
            SseItem::Error("Provider returned error".into())
        );
        assert_eq!(parse_sse_line("data: {\"error\":{\"code\":502}}"), SseItem::Error("error 502".into()));
        assert_eq!(parse_sse_line("data: {\"error\":{\"code\":\"overloaded\"}}"), SseItem::Error("error overloaded".into()));
        assert_eq!(parse_sse_line("data: {\"error\":\"boom\"}"), SseItem::Error("boom".into()));
        // 非 SSE 的錯誤 JSON 行
        assert_eq!(parse_sse_line("{\"error\":{\"message\":\"bad key\"}}"), SseItem::Error("bad key".into()));
        assert_eq!(parse_sse_line("data: {\"error\":null,\"choices\":[{\"delta\":{\"content\":\"a\"}}]}"),
            SseItem::Events(vec![LlmStreamEvent::Delta("a".into())]));
    }

    #[test]
    fn llm_error_body_and_status() {
        assert_eq!(extract_error_message("{\"error\":{\"message\":\"Invalid API key\"}}"), "Invalid API key");
        assert_eq!(extract_error_message("  "), "");
        assert_eq!(extract_error_message(&"x".repeat(500)).chars().count(), 200);
        assert!(humanize_status(402).contains("餘額不足"));
        assert!(LlmError::RetriesExhausted { status: 503, attempts: 4 }.to_string().contains("重試 4 次"));
    }

    #[test]
    fn llm_insecure_endpoint_rejected_before_key() {
        let mut p = super::super::providers::custom("custom-x", "X", "http://api.example.com/v1/chat/completions");
        let c = LlmClient::new();
        let err = c
            .stream_chat(&p, Some("sk-secret"), "m", "s", "u", &LlmRequestOptions::default(), &CancelToken::new(), &mut |_| {})
            .unwrap_err();
        assert!(matches!(err.downcast_ref::<LlmError>(), Some(LlmError::InsecureEndpoint(_))));
        p.base_url = "https://api.example.com/v1/chat/completions".into();
        let err = c
            .stream_chat(&p, None, "m", "s", "u", &LlmRequestOptions::default(), &CancelToken::new(), &mut |_| {})
            .unwrap_err();
        assert!(matches!(err.downcast_ref::<LlmError>(), Some(LlmError::NoApiKey(_))));
    }

    #[test]
    fn llm_chat_body_shape() {
        let p = super::super::providers::find(&Settings::default(), "lmstudio").unwrap();
        let opts = LlmRequestOptions { temperature: Some(0.3), max_tokens: Some(100), top_p: None, json_mode: true };
        let v: serde_json::Value = serde_json::from_slice(&chat_body(&p, "m", "sys", "usr", &opts, true, false)).unwrap();
        assert_eq!(v["temperature"], serde_json::json!(0.3));
        assert_eq!(v["max_tokens"], 100);
        assert!(v.get("stream_options").is_none());
        assert!(v.get("response_format").is_none());
        assert_eq!(v["messages"][0]["role"], "system");
        let o = super::super::providers::find(&Settings::default(), "openai").unwrap();
        let v: serde_json::Value = serde_json::from_slice(&chat_body(&o, "m", "s", "u", &opts, true, true)).unwrap();
        assert_eq!(v["stream_options"]["include_usage"], true);
        assert_eq!(v["response_format"]["type"], "json_object");
    }

    /// 本機假伺服器：送 SSE（含 error 物件）驗證整條串流
    #[test]
    fn llm_stream_against_local_server() {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = std::thread::spawn(move || {
            for body in [
                "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\ndata: {\"choices\":[],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2,\"total_tokens\":5}}\n\ndata: [DONE]\n\n",
                "data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\ndata: {\"error\":{\"message\":\"upstream died\",\"code\":502}}\n\n",
            ] {
                let (mut s, _) = listener.accept().unwrap();
                let mut buf = [0u8; 8192];
                let mut req = Vec::new();
                // 讀到 header 結束 + body（Content-Length）
                loop {
                    let n = s.read(&mut buf).unwrap();
                    req.extend_from_slice(&buf[..n]);
                    let text = String::from_utf8_lossy(&req).to_string();
                    if let Some(h) = text.find("\r\n\r\n") {
                        let len = text[..h]
                            .lines()
                            .find_map(|l| l.to_ascii_lowercase().strip_prefix("content-length:").map(|v| v.trim().parse::<usize>().unwrap()))
                            .unwrap_or(0);
                        if req.len() >= h + 4 + len {
                            break;
                        }
                    }
                    if n == 0 {
                        break;
                    }
                }
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                s.write_all(resp.as_bytes()).unwrap();
            }
        });
        let p = super::super::providers::custom("custom-t", "T", &format!("http://127.0.0.1:{port}/v1/chat/completions"));
        let c = LlmClient::new();
        let mut text = String::new();
        let mut usage = None;
        c.stream_chat(&p, Some("k"), "m", "s", "u", &LlmRequestOptions::default(), &CancelToken::new(), &mut |e| match e {
            LlmStreamEvent::Delta(d) => text.push_str(&d),
            LlmStreamEvent::Usage(u) => usage = Some(u),
        })
        .unwrap();
        assert_eq!(text, "Hello");
        assert_eq!(usage.unwrap().total_tokens, 5);

        let err = c
            .stream_chat(&p, Some("k"), "m", "s", "u", &LlmRequestOptions::default(), &CancelToken::new(), &mut |_| {})
            .unwrap_err();
        assert!(matches!(err.downcast_ref::<LlmError>(), Some(LlmError::Stream(m)) if m == "upstream died"));
        server.join().unwrap();
    }

    #[test]
    fn llm_cancel_returns_quickly() {
        // 只接受連線不回應：取消後應在 ~50ms 內返回 Cancelled
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let _hold = std::thread::spawn(move || {
            let c = listener.accept();
            std::thread::sleep(Duration::from_secs(2));
            drop(c);
        });
        let p = super::super::providers::custom("custom-t", "T", &format!("http://127.0.0.1:{port}/v1/chat/completions"));
        let cancel = CancelToken::new();
        let c2 = cancel.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(150));
            c2.cancel();
        });
        let t0 = Instant::now();
        let err = LlmClient::new()
            .stream_chat(&p, Some("k"), "m", "s", "u", &LlmRequestOptions::default(), &cancel, &mut |_| {})
            .unwrap_err();
        assert!(is_cancelled(&err));
        assert!(t0.elapsed() < Duration::from_millis(1000));
    }
}

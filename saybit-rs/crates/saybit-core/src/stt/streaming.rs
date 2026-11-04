//! 串流語音辨識：邊講邊辨識，講完的瞬間逐字稿就已經好了（移植 saybit-desktop/src-tauri/src/streaming_stt.rs，改 tungstenite 阻塞式）。
//!
//!   阿里雲百鍊 — DashScope 即時語音辨識（Fun-ASR-Realtime），handshake `Authorization: bearer <key>`；
//!                JSON 指令（run-task / finish-task）+ binary 音訊幀；收到 task-started 後才送音訊
//!   訊飛 RTASR — 簽章走 query string（signa = base64(HmacSHA1(MD5(appid+ts), apiKey))），結束訊號 {"end":true}
//!
//! 金鑰：阿里雲 secret("stt.alibaba") 單一 key；訊飛 secret("stt.xunfei") 格式 "appid:apikey"（第一個冒號分隔）。
//! 連線失敗時若雲端 Whisper 有 key，就退回批次雲端 Whisper（同 desktop 行為），錄音不會因此失敗。
//!
//! 每個 session 一條 `stt-streaming` 執行緒持有 socket：讀取用 20 ms timeout 輪詢，空檔把 channel 裡的音訊送出去。
//! ⚠️ 兩家協定照官方文件實作，沒有在真實帳號上跑過。

use crate::stt::{cloud_whisper, f32_to_i16};
use crate::types::*;
use base64::Engine as _;
use crossbeam_channel::{unbounded, Receiver, Sender, TryRecvError};
use hmac::{Hmac, Mac};
use md5::{Digest, Md5};
use sha1::Sha1;
use std::net::{TcpStream, ToSocketAddrs};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tungstenite::client::IntoClientRequest;
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{Message, WebSocket};

pub const ALIYUN_ENDPOINT: &str = "wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference/";
pub const ALIYUN_MODEL: &str = "fun-asr-realtime";
pub const XUNFEI_ENDPOINT: &str = "wss://rtasr.xfyun.cn/v1/ws";
const FINISH_TIMEOUT: Duration = Duration::from_secs(20);
const POLL: Duration = Duration::from_millis(20);

type Socket = WebSocket<MaybeTlsStream<TcpStream>>;

#[derive(Clone, Debug)]
struct Credentials {
    provider: StreamingProvider,
    api_key: String,
    app_id: String,
}

pub struct Engine {
    creds: Option<Credentials>,
    provider: StreamingProvider,
    fallback: cloud_whisper::Engine,
}

impl Engine {
    pub fn new(settings: &Settings, secret: &dyn Fn(&str) -> Option<String>) -> Self {
        let provider = settings.streaming_provider;
        let nonempty = |s: Option<String>| s.map(|v| v.trim().to_string()).filter(|v| !v.is_empty());
        let creds = match provider {
            StreamingProvider::Alibaba => {
                nonempty(secret("stt.alibaba")).map(|k| Credentials { provider, api_key: k, app_id: String::new() })
            }
            StreamingProvider::Xunfei => {
                nonempty(secret("stt.xunfei"))
                    .and_then(|v| v.split_once(':').map(|(a, k)| (a.trim().to_string(), k.trim().to_string())))
                    .filter(|(a, k)| !a.is_empty() && !k.is_empty())
                    .map(|(app_id, api_key)| Credentials { provider, api_key, app_id })
            }
        };
        Self { creds, provider, fallback: cloud_whisper::Engine::new(settings, secret) }
    }
}

impl SttEngine for Engine {
    fn kind(&self) -> SttEngineKind {
        SttEngineKind::Streaming
    }

    fn unavailable_reason(&self) -> Option<String> {
        if self.creds.is_some() {
            return None;
        }
        Some(match self.provider {
            StreamingProvider::Alibaba => "阿里雲串流辨識需要 API Key，請到設定填入".into(),
            StreamingProvider::Xunfei => "訊飛串流辨識需要 appId 與 apiKey，請到設定填入".into(),
        })
    }

    fn start(&self, opts: SttStartOptions) -> anyhow::Result<Box<dyn SttSession>> {
        let creds = self.creds.clone().ok_or_else(|| anyhow::anyhow!(self.unavailable_reason().unwrap_or_default()))?;
        match connect(&creds) {
            Ok(socket) => Ok(Box::new(StreamSession::spawn(socket, creds, opts.on_partial))),
            Err(e) if self.fallback.has_key() => {
                log::warn!("串流辨識連線失敗，改用雲端 Whisper：{e}");
                self.fallback.start(opts)
            }
            Err(e) => Err(e),
        }
    }
}

/// 只連線再斷開，用來在設定畫面驗證憑證與端點
pub fn test_connection(settings: &Settings, secret: &dyn Fn(&str) -> Option<String>) -> anyhow::Result<()> {
    let engine = Engine::new(settings, secret);
    let creds = engine.creds.ok_or_else(|| anyhow::anyhow!("尚未設定串流辨識金鑰"))?;
    let mut socket = connect(&creds)?;
    let _ = socket.close(None);
    let _ = socket.flush();
    Ok(())
}

// MARK: - 連線

fn connect(creds: &Credentials) -> anyhow::Result<Socket> {
    match creds.provider {
        StreamingProvider::Alibaba => {
            let mut request = ALIYUN_ENDPOINT.into_client_request()?;
            request.headers_mut().insert(
                "Authorization",
                format!("bearer {}", creds.api_key)
                    .parse()
                    .map_err(|_| anyhow::anyhow!("API Key 含有無法放進 header 的字元"))?,
            );
            // DashScope 要求宣告啟用資料檢查，缺這個部分模型會拒絕連線
            request.headers_mut().insert("X-DashScope-DataInspection", "enable".parse().expect("static header"));
            open(request).map_err(|e| anyhow::anyhow!("阿里雲連線失敗：{e}"))
        }
        StreamingProvider::Xunfei => {
            let ts = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs().to_string();
            let signa = xunfei_signature(&creds.app_id, &creds.api_key, &ts)?;
            let url = format!("{XUNFEI_ENDPOINT}?appid={}&ts={ts}&signa={}", urlencode(&creds.app_id), urlencode(&signa));
            open(url.into_client_request()?).map_err(|e| anyhow::anyhow!("訊飛連線失敗：{e}"))
        }
    }
}

fn open(request: tungstenite::handshake::client::Request) -> anyhow::Result<Socket> {
    let uri = request.uri().clone();
    let host = uri.host().ok_or_else(|| anyhow::anyhow!("端點沒有主機名稱"))?.to_string();
    let port = uri.port_u16().unwrap_or(if uri.scheme_str() == Some("wss") { 443 } else { 80 });
    let addr = (host.as_str(), port)
        .to_socket_addrs()?
        .next()
        .ok_or_else(|| anyhow::anyhow!("無法解析 {host}"))?;
    let tcp = TcpStream::connect_timeout(&addr, Duration::from_secs(5))?;
    tcp.set_read_timeout(Some(Duration::from_secs(10)))?;
    tcp.set_write_timeout(Some(Duration::from_secs(10)))?;
    tcp.set_nodelay(true)?;
    let (socket, _resp) = tungstenite::client_tls(request, tcp).map_err(|e| anyhow::anyhow!("{e}"))?;
    Ok(socket)
}

fn set_read_timeout(socket: &Socket, t: Duration) {
    #[allow(unreachable_patterns)]
    let tcp: Option<&TcpStream> = match socket.get_ref() {
        MaybeTlsStream::Plain(s) => Some(s),
        MaybeTlsStream::Rustls(s) => Some(&s.sock),
        _ => None,
    };
    if let Some(tcp) = tcp {
        let _ = tcp.set_read_timeout(Some(t));
    }
}

pub fn xunfei_signature(app_id: &str, api_key: &str, ts: &str) -> anyhow::Result<String> {
    let mut md5 = Md5::new();
    md5.update(format!("{app_id}{ts}").as_bytes());
    let base_string = format!("{:x}", md5.finalize());
    let mut mac = Hmac::<Sha1>::new_from_slice(api_key.as_bytes()).map_err(|e| anyhow::anyhow!("apiKey 無法作為簽章金鑰：{e}"))?;
    mac.update(base_string.as_bytes());
    Ok(base64::engine::general_purpose::STANDARD.encode(mac.finalize().into_bytes()))
}

/// signa 的 base64 會含有 `+` `/` `=`，直接塞進 query string 會被誤解
pub fn urlencode(input: &str) -> String {
    input
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

// MARK: - Session

enum AudioMsg {
    Chunk(Vec<u8>),
    Finish,
}

struct StreamSession {
    audio_tx: Option<Sender<AudioMsg>>,
    result_rx: Receiver<anyhow::Result<String>>,
}

impl StreamSession {
    fn spawn(socket: Socket, creds: Credentials, on_partial: Option<PartialCallback>) -> Self {
        let (audio_tx, audio_rx) = unbounded();
        let (result_tx, result_rx) = crossbeam_channel::bounded(1);
        std::thread::Builder::new()
            .name("stt-streaming".into())
            .spawn(move || {
                let r = pump(socket, &creds, audio_rx, on_partial);
                let _ = result_tx.send(r);
            })
            .expect("spawn stt-streaming");
        Self { audio_tx: Some(audio_tx), result_rx }
    }
}

impl SttSession for StreamSession {
    fn push(&mut self, samples: &[f32]) {
        if samples.is_empty() {
            return;
        }
        let mut bytes = Vec::with_capacity(samples.len() * 2);
        for s in samples {
            bytes.extend_from_slice(&f32_to_i16(*s).to_le_bytes());
        }
        if let Some(tx) = &self.audio_tx {
            let _ = tx.send(AudioMsg::Chunk(bytes));
        }
    }

    fn finish(mut self: Box<Self>) -> anyhow::Result<String> {
        if let Some(tx) = self.audio_tx.take() {
            let _ = tx.send(AudioMsg::Finish);
            // 保留 sender 直到結果回來：drop 會被 pump 當成取消
            let r = self.result_rx.recv_timeout(FINISH_TIMEOUT + Duration::from_secs(2));
            drop(tx);
            return r.map_err(|_| anyhow::anyhow!("等待串流辨識最終結果逾時"))?;
        }
        Ok(String::new())
    }

    /// drop sender → pump 發現 channel 斷開就關連線收工，不等結果
    fn cancel(mut self: Box<Self>) {
        self.audio_tx.take();
    }
}

fn pump(
    mut socket: Socket,
    creds: &Credentials,
    audio_rx: Receiver<AudioMsg>,
    on_partial: Option<PartialCallback>,
) -> anyhow::Result<String> {
    let task_id = uuid::Uuid::new_v4().simple().to_string();
    let aliyun = creds.provider == StreamingProvider::Alibaba;
    if aliyun {
        let run_task = serde_json::json!({
            "header": { "action": "run-task", "task_id": task_id, "streaming": "duplex" },
            "payload": {
                "task_group": "audio", "task": "asr", "function": "recognition",
                "model": ALIYUN_MODEL,
                "parameters": { "sample_rate": 16000, "format": "pcm" },
                "input": {}
            }
        });
        socket.send(Message::text(run_task.to_string())).map_err(|e| anyhow::anyhow!("送出 run-task 失敗：{e}"))?;
    }
    set_read_timeout(&socket, POLL);

    // 阿里雲要等 task-started 才能送音訊；在那之前先排隊
    let mut ready = !aliyun;
    let mut queued: Vec<Vec<u8>> = Vec::new();
    let mut finish_requested = false;
    let mut finish_sent = false;
    let mut deadline: Option<Instant> = None;
    let mut acc = Transcript::default();

    loop {
        // 1) 把 channel 裡的音訊送出去（不阻塞）
        loop {
            match audio_rx.try_recv() {
                Ok(AudioMsg::Chunk(b)) => queued.push(b),
                Ok(AudioMsg::Finish) => {
                    finish_requested = true;
                    deadline = Some(Instant::now() + FINISH_TIMEOUT);
                }
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    if !finish_requested {
                        // 取消錄音
                        let _ = socket.close(None);
                        let _ = socket.flush();
                        return Ok(String::new());
                    }
                    break;
                }
            }
        }
        if ready {
            for b in queued.drain(..) {
                socket.write(Message::binary(b)).map_err(|e| anyhow::anyhow!("串流連線中斷：{e}"))?;
            }
            if finish_requested && !finish_sent {
                let closing = if aliyun {
                    serde_json::json!({
                        "header": { "action": "finish-task", "task_id": task_id, "streaming": "duplex" },
                        "payload": { "input": {} }
                    })
                    .to_string()
                } else {
                    "{\"end\": true}".to_string()
                };
                socket.write(Message::text(closing)).map_err(|e| anyhow::anyhow!("串流連線中斷：{e}"))?;
                finish_sent = true;
            }
            match socket.flush() {
                Ok(()) => {}
                Err(tungstenite::Error::Io(e)) if is_timeout(&e) => {}
                Err(e) => anyhow::bail!("串流連線中斷：{e}"),
            }
        }
        if deadline.is_some_and(|d| Instant::now() >= d) {
            log::warn!("串流辨識最終結果逾時，使用目前累積的文字");
            break;
        }

        // 2) 讀一則訊息（最多等 POLL）
        match socket.read() {
            Ok(Message::Text(text)) => match parse_message(creds.provider, text.as_str()) {
                ParsedEvent::Started => ready = true,
                ParsedEvent::Final(seg) => {
                    acc.commit(seg);
                    if let Some(cb) = &on_partial {
                        cb(acc.text());
                    }
                }
                ParsedEvent::Partial(seg) => {
                    acc.partial = seg;
                    if let Some(cb) = &on_partial {
                        cb(acc.text());
                    }
                }
                ParsedEvent::Completed => break,
                ParsedEvent::Failed(reason) => anyhow::bail!(reason),
                ParsedEvent::Ignore => {}
            },
            Ok(Message::Close(_)) => break,
            Ok(_) => {}
            Err(tungstenite::Error::Io(e)) if is_timeout(&e) => {}
            Err(tungstenite::Error::ConnectionClosed) | Err(tungstenite::Error::AlreadyClosed) => break,
            Err(e) => anyhow::bail!("串流連線中斷：{e}"),
        }
    }
    let _ = socket.close(None);
    let _ = socket.flush();
    Ok(acc.text().trim().to_string())
}

fn is_timeout(e: &std::io::Error) -> bool {
    matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut)
}

#[derive(Default)]
struct Transcript {
    finalized: String,
    partial: String,
}

impl Transcript {
    fn commit(&mut self, seg: String) {
        self.finalized.push_str(&seg);
        self.partial.clear();
    }
    fn text(&self) -> String {
        format!("{}{}", self.finalized, self.partial)
    }
}

// MARK: - 回應解析

#[derive(Debug, PartialEq)]
enum ParsedEvent {
    Started,
    /// 已定稿的一段，要接到結果尾巴
    Final(String),
    /// 還在變動的一段，會被下一次覆寫
    Partial(String),
    Completed,
    Failed(String),
    Ignore,
}

fn parse_message(provider: StreamingProvider, text: &str) -> ParsedEvent {
    match provider {
        StreamingProvider::Alibaba => parse_aliyun(text),
        StreamingProvider::Xunfei => parse_xunfei(text),
    }
}

fn parse_aliyun(text: &str) -> ParsedEvent {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(text) else {
        return ParsedEvent::Ignore;
    };
    let header = value.get("header");
    let event = header.and_then(|h| h.get("event")).and_then(|e| e.as_str()).unwrap_or("");
    match event {
        "task-started" => ParsedEvent::Started,
        "task-finished" => ParsedEvent::Completed,
        "task-failed" => {
            let message = header.and_then(|h| h.get("error_message")).and_then(|m| m.as_str()).unwrap_or("未知錯誤");
            ParsedEvent::Failed(format!("阿里雲辨識失敗：{message}"))
        }
        "result-generated" => {
            let Some(sentence) = value.get("payload").and_then(|p| p.get("output")).and_then(|o| o.get("sentence")) else {
                return ParsedEvent::Ignore;
            };
            let content = sentence.get("text").and_then(|t| t.as_str()).unwrap_or("").to_string();
            if content.is_empty() {
                return ParsedEvent::Ignore;
            }
            if sentence.get("sentence_end").and_then(|v| v.as_bool()).unwrap_or(false) {
                ParsedEvent::Final(content)
            } else {
                ParsedEvent::Partial(content)
            }
        }
        _ => ParsedEvent::Ignore,
    }
}

fn parse_xunfei(text: &str) -> ParsedEvent {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(text) else {
        return ParsedEvent::Ignore;
    };
    let action = value.get("action").and_then(|a| a.as_str()).unwrap_or("");
    if action == "error" {
        let desc = value.get("desc").and_then(|d| d.as_str()).unwrap_or("未知錯誤");
        return ParsedEvent::Failed(format!("訊飛辨識失敗：{desc}"));
    }
    if action == "started" {
        return ParsedEvent::Started;
    }
    if action != "result" {
        return ParsedEvent::Ignore;
    }
    // data 是一個「字串化的 JSON」，要再 parse 一層
    let Some(data) = value
        .get("data")
        .and_then(|d| d.as_str())
        .and_then(|s| serde_json::from_str::<serde_json::Value>(s).ok())
    else {
        return ParsedEvent::Ignore;
    };
    let Some(st) = data.get("cn").and_then(|c| c.get("st")) else {
        return ParsedEvent::Ignore;
    };
    // type "0" = 已定稿，"1" = 中間結果
    let is_final = st.get("type").and_then(|t| t.as_str()).unwrap_or("1") == "0";
    let mut content = String::new();
    for rt in st.get("rt").and_then(|r| r.as_array()).into_iter().flatten() {
        for ws in rt.get("ws").and_then(|w| w.as_array()).into_iter().flatten() {
            for cw in ws.get("cw").and_then(|c| c.as_array()).into_iter().flatten() {
                if let Some(word) = cw.get("w").and_then(|w| w.as_str()) {
                    content.push_str(word);
                }
            }
        }
    }
    if content.is_empty() {
        ParsedEvent::Ignore
    } else if is_final {
        ParsedEvent::Final(content)
    } else {
        ParsedEvent::Partial(content)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aliyun_events() {
        assert_eq!(parse_aliyun(r#"{"header":{"event":"task-started"}}"#), ParsedEvent::Started);
        assert_eq!(parse_aliyun(r#"{"header":{"event":"task-finished"}}"#), ParsedEvent::Completed);
        assert_eq!(
            parse_aliyun(r#"{"header":{"event":"task-failed","error_message":"bad key"}}"#),
            ParsedEvent::Failed("阿里雲辨識失敗：bad key".into())
        );
        let partial = r#"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"text":"你好","sentence_end":false}}}}"#;
        assert_eq!(parse_aliyun(partial), ParsedEvent::Partial("你好".into()));
        let fin = r#"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"text":"你好。","sentence_end":true}}}}"#;
        assert_eq!(parse_aliyun(fin), ParsedEvent::Final("你好。".into()));
        assert_eq!(parse_aliyun("not json"), ParsedEvent::Ignore);
    }

    #[test]
    fn xunfei_events() {
        let data = r#"{"cn":{"st":{"type":"0","rt":[{"ws":[{"cw":[{"w":"今天"}]},{"cw":[{"w":"天氣"}]}]}]}}}"#;
        let msg = serde_json::json!({ "action": "result", "data": data }).to_string();
        assert_eq!(parse_xunfei(&msg), ParsedEvent::Final("今天天氣".into()));
        let data1 = data.replace("\"type\":\"0\"", "\"type\":\"1\"");
        let msg1 = serde_json::json!({ "action": "result", "data": data1 }).to_string();
        assert_eq!(parse_xunfei(&msg1), ParsedEvent::Partial("今天天氣".into()));
        assert_eq!(parse_xunfei(r#"{"action":"started"}"#), ParsedEvent::Started);
        assert_eq!(parse_xunfei(r#"{"action":"error","desc":"x"}"#), ParsedEvent::Failed("訊飛辨識失敗：x".into()));
    }

    #[test]
    fn transcript_accumulates() {
        let mut t = Transcript { partial: "你".into(), ..Default::default() };
        assert_eq!(t.text(), "你");
        t.commit("你好。".into());
        t.partial = "今天".into();
        assert_eq!(t.text(), "你好。今天");
    }

    #[test]
    fn signature_and_urlencode() {
        // 固定輸入的簽章要可重現，且 base64 字元要被 escape
        let s1 = xunfei_signature("app", "key", "1700000000").unwrap();
        let s2 = xunfei_signature("app", "key", "1700000000").unwrap();
        assert_eq!(s1, s2);
        assert_eq!(s1.len(), 28); // SHA1 20 bytes → base64 28 字元
        assert_eq!(urlencode("a+b/c="), "a%2Bb%2Fc%3D");
    }

    #[test]
    fn credentials_from_secrets() {
        let s = Settings { streaming_provider: StreamingProvider::Xunfei, ..Default::default() };
        let e = Engine::new(&s, &|acc| (acc == "stt.xunfei").then(|| "myapp:mykey".to_string()));
        let c = e.creds.unwrap();
        assert_eq!((c.app_id.as_str(), c.api_key.as_str()), ("myapp", "mykey"));
        // 沒有冒號、或任一邊為空 → 不可用
        for bad in ["onlykey", ":k", "a:"] {
            let e = Engine::new(&s, &|acc| (acc == "stt.xunfei").then(|| bad.to_string()));
            assert!(e.unavailable_reason().is_some(), "{bad}");
        }
        let a = Settings { streaming_provider: StreamingProvider::Alibaba, ..Default::default() };
        let e = Engine::new(&a, &|acc| (acc == "stt.alibaba").then(|| "sk-1".to_string()));
        assert_eq!(e.creds.unwrap().api_key, "sk-1");
        let e = Engine::new(&Settings::default(), &|_| None);
        assert!(e.unavailable_reason().is_some());
    }
}

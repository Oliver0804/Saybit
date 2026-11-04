// 串流語音辨識：邊講邊辨識，講完的瞬間逐字稿就已經好了。
//
// 為什麼放在 Rust 而不是前端：阿里雲的 WebSocket 認證走 handshake 的
// `Authorization: bearer <key>` header，而瀏覽器的 WebSocket API 沒有辦法設定
// 自訂 header（只能帶 subprotocol）。放 Rust 順帶讓金鑰不用進 webview。
//
// 目前支援兩家，兩者的協定差異很大，各自一個 parser：
//   aliyun — DashScope 即時語音辨識（Fun-ASR-Realtime / Qwen3-ASR-Flash-Realtime）
//            JSON 指令（run-task / finish-task）+ binary 音訊幀
//   xunfei — 訊飛實時語音轉寫 RTASR
//            簽章走 query string，結束訊號是 {"end":true}
//
// ⚠️ 這兩家的協定是照官方文件實作的，但沒有在真實帳號上跑過（我沒有金鑰）。
//    設定畫面有「測試連線」可以驗證憑證與端點。

use base64::Engine;
use futures_util::{SinkExt, StreamExt};
use hmac::{Hmac, Mac};
use md5::{Digest, Md5};
use serde::{Deserialize, Serialize};
use sha1::Sha1;
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter};
use tokio::sync::{mpsc, oneshot};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::Message;

// ---------------------------------------------------------------- 設定

#[derive(Deserialize, Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct StreamingConfig {
    /// "aliyun" | "xunfei"
    pub provider: String,
    /// 阿里雲：完整的 wss 端點；訊飛留空走預設
    pub endpoint: String,
    /// 阿里雲的 API Key／訊飛的 apiKey
    pub api_key: String,
    /// 訊飛專用
    pub app_id: String,
    /// 阿里雲專用，例如 fun-asr-realtime
    pub model: String,
}

const XUNFEI_ENDPOINT: &str = "wss://rtasr.xfyun.cn/v1/ws";

// ---------------------------------------------------------------- Session

enum AudioMsg {
    Chunk(Vec<u8>),
    Finish,
}

struct SessionHandle {
    audio_tx: mpsc::Sender<AudioMsg>,
    result_rx: oneshot::Receiver<Result<String, String>>,
}

fn session_slot() -> &'static Mutex<Option<SessionHandle>> {
    static SLOT: OnceLock<Mutex<Option<SessionHandle>>> = OnceLock::new();
    SLOT.get_or_init(|| Mutex::new(None))
}

// ---------------------------------------------------------------- commands

/// 開一條串流辨識連線。已經有連線時會先收掉舊的。
#[tauri::command]
pub async fn streaming_stt_start(app: AppHandle, config: StreamingConfig) -> Result<(), String> {
    // 音訊 channel 給足緩衝：錄音端推送的速度可能短暫快過網路
    let (audio_tx, audio_rx) = mpsc::channel::<AudioMsg>(256);
    let (result_tx, result_rx) = oneshot::channel::<Result<String, String>>();

    // 先確認連得上再登記 session，否則失敗了還留一個死 session 在那
    let socket = connect(&config).await?;

    {
        let mut slot = session_slot().lock().map_err(|e| e.to_string())?;
        *slot = Some(SessionHandle {
            audio_tx,
            result_rx,
        });
    }

    let app_for_task = app.clone();
    tauri::async_runtime::spawn(async move {
        let outcome = pump(app_for_task, config, socket, audio_rx).await;
        let _ = result_tx.send(outcome);
    });

    Ok(())
}

/// 推一塊音訊進去。body 是 16kHz mono little-endian **i16** PCM。
#[tauri::command]
pub async fn streaming_stt_push(request: tauri::ipc::Request<'_>) -> Result<(), String> {
    let bytes = match request.body() {
        tauri::ipc::InvokeBody::Raw(b) => b.clone(),
        _ => return Err("expect raw PCM body".into()),
    };

    let tx = {
        let slot = session_slot().lock().map_err(|e| e.to_string())?;
        match slot.as_ref() {
            Some(handle) => handle.audio_tx.clone(),
            None => return Err("串流辨識尚未啟動".into()),
        }
    };

    tx.send(AudioMsg::Chunk(bytes))
        .await
        .map_err(|_| "串流連線已關閉".to_string())
}

/// 收尾並取回完整逐字稿。
#[tauri::command]
pub async fn streaming_stt_finish() -> Result<String, String> {
    let handle = {
        let mut slot = session_slot().lock().map_err(|e| e.to_string())?;
        slot.take()
    };
    let handle = handle.ok_or("串流辨識尚未啟動")?;

    // 送出結束訊號；channel 已關閉代表連線早就掛了，還是要去把結果收回來
    let _ = handle.audio_tx.send(AudioMsg::Finish).await;

    match tokio::time::timeout(std::time::Duration::from_secs(20), handle.result_rx).await {
        Ok(Ok(outcome)) => outcome,
        Ok(Err(_)) => Err("串流工作已中止".into()),
        Err(_) => Err("等待串流辨識最終結果逾時".into()),
    }
}

/// 丟棄目前的串流（取消錄音時用），不等結果。
#[tauri::command]
pub async fn streaming_stt_cancel() -> Result<(), String> {
    let mut slot = session_slot().lock().map_err(|e| e.to_string())?;
    *slot = None; // drop 掉 sender，pump 的 recv 會收到 None 然後收工
    Ok(())
}

/// 只連線再斷開，用來在設定畫面驗證憑證與端點。
#[tauri::command]
pub async fn streaming_stt_test(config: StreamingConfig) -> Result<String, String> {
    let mut socket = connect(&config).await?;
    let _ = socket.close(None).await;
    Ok(format!("連線成功（{}）", config.provider))
}

// ---------------------------------------------------------------- 連線

type Socket = tokio_tungstenite::WebSocketStream<
    tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
>;

async fn connect(config: &StreamingConfig) -> Result<Socket, String> {
    match config.provider.as_str() {
        "aliyun" => connect_aliyun(config).await,
        "xunfei" => connect_xunfei(config).await,
        other => Err(format!("未知的串流辨識服務商：{other}")),
    }
}

async fn connect_aliyun(config: &StreamingConfig) -> Result<Socket, String> {
    if config.api_key.is_empty() {
        return Err("阿里雲串流辨識需要 API Key".into());
    }
    let endpoint = if config.endpoint.is_empty() {
        // 國際站（新加坡）預設值；北京站與自建 workspace 端點請自行填入
        "wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference/"
    } else {
        config.endpoint.as_str()
    };

    let mut request = endpoint
        .into_client_request()
        .map_err(|e| format!("端點格式錯誤：{e}"))?;
    request.headers_mut().insert(
        "Authorization",
        format!("bearer {}", config.api_key)
            .parse()
            .map_err(|_| "API Key 含有無法放進 header 的字元")?,
    );
    // DashScope 要求宣告啟用資料檢查，缺這個部分模型會拒絕連線
    request
        .headers_mut()
        .insert("X-DashScope-DataInspection", "enable".parse().unwrap());

    let (socket, _) = tokio_tungstenite::connect_async(request)
        .await
        .map_err(|e| format!("阿里雲連線失敗：{e}"))?;
    Ok(socket)
}

async fn connect_xunfei(config: &StreamingConfig) -> Result<Socket, String> {
    if config.app_id.is_empty() || config.api_key.is_empty() {
        return Err("訊飛串流辨識需要 appId 與 apiKey".into());
    }

    // signa = base64( HmacSHA1( MD5(appid + ts), apiKey ) )
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_secs()
        .to_string();

    let mut md5 = Md5::new();
    md5.update(format!("{}{}", config.app_id, ts).as_bytes());
    let base_string = format!("{:x}", md5.finalize());

    let mut mac = Hmac::<Sha1>::new_from_slice(config.api_key.as_bytes())
        .map_err(|e| format!("apiKey 無法作為簽章金鑰：{e}"))?;
    mac.update(base_string.as_bytes());
    let signa = base64::engine::general_purpose::STANDARD.encode(mac.finalize().into_bytes());

    let base = if config.endpoint.is_empty() {
        XUNFEI_ENDPOINT
    } else {
        config.endpoint.as_str()
    };
    let url = format!(
        "{base}?appid={}&ts={ts}&signa={}",
        config.app_id,
        urlencode(&signa)
    );

    let (socket, _) = tokio_tungstenite::connect_async(url)
        .await
        .map_err(|e| format!("訊飛連線失敗：{e}"))?;
    Ok(socket)
}

/// signa 的 base64 會含有 `+` `/` `=`，直接塞進 query string 會被誤解。
fn urlencode(input: &str) -> String {
    input
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

// ---------------------------------------------------------------- 主迴圈

async fn pump(
    app: AppHandle,
    config: StreamingConfig,
    socket: Socket,
    mut audio_rx: mpsc::Receiver<AudioMsg>,
) -> Result<String, String> {
    let (mut write, mut read) = socket.split();
    let task_id = uuid::Uuid::new_v4().simple().to_string();

    // 阿里雲要先送 run-task 並等 task-started 才能推音訊
    if config.provider == "aliyun" {
        let run_task = serde_json::json!({
            "header": {
                "action": "run-task",
                "task_id": task_id,
                "streaming": "duplex"
            },
            "payload": {
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": if config.model.is_empty() { "fun-asr-realtime" } else { &config.model },
                "parameters": { "sample_rate": 16000, "format": "pcm" },
                "input": {}
            }
        });
        write
            .send(Message::Text(run_task.to_string()))
            .await
            .map_err(|e| format!("送出 run-task 失敗：{e}"))?;
    }

    let mut finalized = String::new();
    let mut partial = String::new();
    let mut finishing = false;

    loop {
        tokio::select! {
            incoming = audio_rx.recv() => {
                match incoming {
                    Some(AudioMsg::Chunk(bytes)) => {
                        if write.send(Message::Binary(bytes)).await.is_err() {
                            break;
                        }
                    }
                    Some(AudioMsg::Finish) => {
                        finishing = true;
                        let closing = match config.provider.as_str() {
                            "aliyun" => Message::Text(serde_json::json!({
                                "header": {
                                    "action": "finish-task",
                                    "task_id": task_id,
                                    "streaming": "duplex"
                                },
                                "payload": { "input": {} }
                            }).to_string()),
                            // 訊飛的結束訊號是一個內容為 {"end":true} 的訊息
                            _ => Message::Text("{\"end\": true}".to_string()),
                        };
                        let _ = write.send(closing).await;
                    }
                    // sender 被 drop（取消錄音）→ 收工
                    None => break,
                }
            }

            message = read.next() => {
                let Some(message) = message else { break };
                let message = match message {
                    Ok(m) => m,
                    Err(e) => return Err(format!("串流連線中斷：{e}")),
                };

                match message {
                    Message::Text(text) => {
                        match parse_message(&config.provider, &text) {
                            ParsedEvent::Final(segment) => {
                                finalized.push_str(&segment);
                                partial.clear();
                                let _ = app.emit("stt-partial", finalized.clone());
                            }
                            ParsedEvent::Partial(segment) => {
                                partial = segment;
                                let _ = app.emit(
                                    "stt-partial",
                                    format!("{finalized}{partial}"),
                                );
                            }
                            ParsedEvent::Completed => break,
                            ParsedEvent::Failed(reason) => return Err(reason),
                            ParsedEvent::Ignore => {}
                        }
                    }
                    Message::Close(_) => break,
                    _ => {}
                }
            }
        }
    }

    if !finishing {
        // 沒送過結束訊號就跳出來，代表是被取消或連線掉了
        let _ = write.close().await;
    }

    let mut result = finalized;
    result.push_str(&partial);
    Ok(result.trim().to_string())
}

// ---------------------------------------------------------------- 回應解析

enum ParsedEvent {
    /// 已定稿的一段，要接到結果尾巴
    Final(String),
    /// 還在變動的一段，會被下一次覆寫
    Partial(String),
    Completed,
    Failed(String),
    Ignore,
}

fn parse_message(provider: &str, text: &str) -> ParsedEvent {
    match provider {
        "aliyun" => parse_aliyun(text),
        "xunfei" => parse_xunfei(text),
        _ => ParsedEvent::Ignore,
    }
}

fn parse_aliyun(text: &str) -> ParsedEvent {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(text) else {
        return ParsedEvent::Ignore;
    };
    let event = value
        .get("header")
        .and_then(|h| h.get("event"))
        .and_then(|e| e.as_str())
        .unwrap_or("");

    match event {
        "task-started" => ParsedEvent::Ignore,
        "task-finished" => ParsedEvent::Completed,
        "task-failed" => {
            let message = value
                .get("header")
                .and_then(|h| h.get("error_message"))
                .and_then(|m| m.as_str())
                .unwrap_or("未知錯誤");
            ParsedEvent::Failed(format!("阿里雲辨識失敗：{message}"))
        }
        "result-generated" => {
            let sentence = value
                .get("payload")
                .and_then(|p| p.get("output"))
                .and_then(|o| o.get("sentence"));
            let Some(sentence) = sentence else {
                return ParsedEvent::Ignore;
            };
            let content = sentence
                .get("text")
                .and_then(|t| t.as_str())
                .unwrap_or("")
                .to_string();
            if content.is_empty() {
                return ParsedEvent::Ignore;
            }
            // sentence_end 為 true 代表這句定稿了，不會再變
            let ended = sentence
                .get("sentence_end")
                .and_then(|v| v.as_bool())
                .unwrap_or(false);
            if ended {
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
        let desc = value
            .get("desc")
            .and_then(|d| d.as_str())
            .unwrap_or("未知錯誤");
        return ParsedEvent::Failed(format!("訊飛辨識失敗：{desc}"));
    }
    if action != "result" {
        // started / 心跳之類的都略過
        return ParsedEvent::Ignore;
    }

    // data 是一個「字串化的 JSON」，要再 parse 一層
    let Some(data_str) = value.get("data").and_then(|d| d.as_str()) else {
        return ParsedEvent::Ignore;
    };
    let Ok(data) = serde_json::from_str::<serde_json::Value>(data_str) else {
        return ParsedEvent::Ignore;
    };

    let Some(st) = data.get("cn").and_then(|c| c.get("st")) else {
        return ParsedEvent::Ignore;
    };

    // type "0" = 已定稿，"1" = 中間結果
    let is_final = st.get("type").and_then(|t| t.as_str()).unwrap_or("1") == "0";

    // 文字散在 rt[].ws[].cw[].w，逐層攤平接起來
    let mut content = String::new();
    if let Some(rt_list) = st.get("rt").and_then(|r| r.as_array()) {
        for rt in rt_list {
            let Some(ws_list) = rt.get("ws").and_then(|w| w.as_array()) else {
                continue;
            };
            for ws in ws_list {
                let Some(cw_list) = ws.get("cw").and_then(|c| c.as_array()) else {
                    continue;
                };
                for cw in cw_list {
                    if let Some(word) = cw.get("w").and_then(|w| w.as_str()) {
                        content.push_str(word);
                    }
                }
            }
        }
    }

    if content.is_empty() {
        return ParsedEvent::Ignore;
    }
    if is_final {
        ParsedEvent::Final(content)
    } else {
        ParsedEvent::Partial(content)
    }
}

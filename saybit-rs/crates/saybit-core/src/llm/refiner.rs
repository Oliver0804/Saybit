//! 兩階段處理（移植 TextRefiner.swift）：字典替換 → （有 mode 跳過）Stage 1 意圖分類（8 秒逾時 fallback）→ Stage 2 潤飾/動作
use super::client::{is_cancelled, LlmClient, LlmError};
use crate::logging::{log, log_sensitive};
use crate::prompts::{self, Intent};
use crate::types::*;
use std::time::{Duration, Instant};

/// Stage 1 意圖分類逾時：超過就當 dictation
pub const INTENT_TIMEOUT: Duration = Duration::from_secs(8);

#[derive(Debug, thiserror::Error)]
pub enum RefinerError {
    #[error("LLM 未回傳任何文字")]
    EmptyResponse,
    /// 動作意圖（行事曆 / 提醒）解析失敗
    #[error("{0}")]
    ActionFailed(String),
}

pub struct RefineRequest {
    pub transcript: String,
    pub selected_text: Option<String>,
    pub app_context: AppContext,
    pub mode_instructions: Option<String>,
    pub dictionary: Vec<DictionaryEntry>,
    pub skills: Vec<Skill>,
}

pub struct RefineResult {
    pub outcome: RefineOutcome,
    pub usage: TokenUsage,
    pub model: String,
}

fn add_usage(total: &mut TokenUsage, u: &TokenUsage) {
    total.prompt_tokens += u.prompt_tokens;
    total.completion_tokens += u.completion_tokens;
    total.total_tokens += u.total_tokens;
}

fn custom_opts(settings: &Settings, temperature: f32) -> LlmRequestOptions {
    if settings.use_custom_llm_params {
        LlmRequestOptions {
            temperature: Some(settings.llm_temperature),
            max_tokens: Some(settings.llm_max_tokens),
            top_p: Some(settings.llm_top_p),
            json_mode: false,
        }
    } else {
        LlmRequestOptions { temperature: Some(temperature), ..Default::default() }
    }
}

fn tone_str(t: ToneStyle) -> Option<&'static str> {
    match t {
        ToneStyle::Auto => None,
        ToneStyle::Formal => Some("formal"),
        ToneStyle::Casual => Some("casual"),
        ToneStyle::VeryCasual => Some("very_casual"),
    }
}

/// JSON metadata（不含 existing_text / screen_context，那兩個走標籤）
#[allow(clippy::too_many_arguments)]
fn metadata_json(
    transcript: &str,
    context: &str,
    mode: Option<&str>,
    tone: Option<&str>,
    language_preference: &str,
    dictionary: &[DictionaryEntry],
    skills: &[Skill],
    whisper_mode: bool,
) -> String {
    let mut m = serde_json::Map::new();
    m.insert("transcript".into(), transcript.into());
    if !context.is_empty() {
        m.insert("context".into(), context.into());
    }
    if let Some(mode) = mode {
        m.insert("mode".into(), mode.into());
    }
    if let Some(t) = tone {
        m.insert("tone".into(), t.into());
    }
    if !language_preference.is_empty() {
        m.insert("language_preference".into(), language_preference.into());
    }
    if !dictionary.is_empty() {
        let d: serde_json::Map<String, serde_json::Value> =
            dictionary.iter().map(|e| (e.term.clone(), serde_json::Value::String(e.preferred.clone()))).collect();
        m.insert("personal_dictionary".into(), d.into());
    }
    if !skills.is_empty() {
        let s: serde_json::Map<String, serde_json::Value> =
            skills.iter().map(|e| (e.trigger.clone(), serde_json::Value::String(e.content.clone()))).collect();
        m.insert("snippets".into(), s.into());
    }
    if whisper_mode {
        m.insert("whisper_mode".into(), true.into());
    }
    serde_json::Value::Object(m).to_string()
}

fn preview(s: &str, n: usize) -> String {
    let head: String = s.chars().take(n).collect();
    if s.chars().count() > n { format!("{head}...") } else { head }
}

/// on_partial 收到累積文字。取消時回 Err(LlmError::Cancelled)。
pub fn refine(
    client: &LlmClient,
    settings: &Settings,
    api_key: Option<&str>,
    req: &RefineRequest,
    cancel: &CancelToken,
    on_partial: &mut dyn FnMut(&str),
) -> anyhow::Result<RefineResult> {
    let provider = super::providers::selected(settings);
    let model = settings.selected_model.clone();
    let style = settings.prompt_style;
    let mut usage = TokenUsage::default();

    // 字典字面替換：辨識錯的專有名詞先修正，LLM 收到的就是正確寫法
    let transcript = crate::dictionary::apply(&req.transcript, &req.dictionary);
    if transcript != req.transcript {
        log_sensitive(
            LogLevel::Info,
            "LLM",
            format!("字典替換: {} → {}", preview(&req.transcript, 60), preview(&transcript, 60)),
        );
    }
    let selected = req.selected_text.as_deref().filter(|s| !s.is_empty());
    let has_selected = selected.is_some();
    let context_id = crate::app_context::context_identifier(&req.app_context);
    let rule = crate::context_rules::matching_rule(settings, &req.app_context);

    log(
        LogLevel::Info,
        "LLM",
        format!("LLM 處理開始 (provider={}, model={model}, style={style:?})", provider.name),
    );

    let system_prompt: String;
    let content: String;
    let existing: Option<&str>;

    let mode_instr = req.mode_instructions.as_deref().map(str::trim).filter(|s| !s.is_empty());
    if let Some(instructions) = mode_instr {
        log(LogLevel::Info, "LLM", format!("語音模式指令處理 ({} 字)", instructions.chars().count()));
        system_prompt = prompts::for_mode(instructions, has_selected, settings);
        content = transcript.clone();
        existing = selected;
    } else if let Some(picked) = selected {
        log(LogLevel::Info, "LLM", format!("有選取文字 ({} 字), 單階段處理", picked.chars().count()));
        system_prompt = prompts::for_style(style).to_string();
        content = transcript.clone();
        existing = Some(picked);
    } else {
        let intent = classify_intent(client, settings, &provider, api_key, &model, &transcript, &context_id, &req.skills, cancel, &mut usage)?;
        if intent.intent == "create_event" || intent.intent == "create_reminder" {
            let (outcome, u) = process_action_intent(client, settings, &provider, api_key, &model, &intent, &transcript, cancel)?;
            add_usage(&mut usage, &u);
            return Ok(RefineResult { outcome, usage, model });
        }
        let extracted = intent.content.as_deref().filter(|c| !c.is_empty());
        if intent.intent != "dictation" && extracted.is_some() {
            let skill = if intent.intent == "skill" {
                intent
                    .skill_name
                    .as_deref()
                    .and_then(|n| req.skills.iter().find(|s| s.trigger == n))
            } else {
                None
            };
            if let Some(skill) = skill {
                system_prompt = format!("{}\n\nOutput ONLY the processed result. No explanation.", skill.content);
                log(LogLevel::Info, "LLM", format!("Stage 2 使用技能: {}", skill.trigger));
            } else {
                let action = prompts::for_intent(&intent, &settings.language_preference);
                system_prompt = if action.is_empty() { prompts::for_style(style).to_string() } else { action };
                log(LogLevel::Info, "LLM", format!("Stage 2 執行: {}", intent.intent));
            }
            content = extracted.unwrap_or_default().to_string();
            existing = None;
        } else if intent.intent != "dictation" && looks_like_bare_command(&transcript, 25) {
            log(LogLevel::Info, "LLM", format!("Stage 1 意圖={} 但無可操作內容，提示使用者", intent.intent));
            let hint = match intent.intent.as_str() {
                "translate" => {
                    let lang = intent
                        .language
                        .as_deref()
                        .and_then(prompts::language_display_name)
                        .unwrap_or("目標語言");
                    format!("請先選取要翻譯成{lang}的文字")
                }
                "rewrite" => "請先選取要改寫的文字".into(),
                "skill" => "請先選取要處理的文字".into(),
                _ => "請先選取要操作的文字".into(),
            };
            return Ok(RefineResult { outcome: RefineOutcome::NeedsSelection(hint), usage, model });
        } else {
            if intent.intent != "dictation" {
                log(LogLevel::Info, "LLM", format!("Stage 1 意圖={} 但無內容且轉錄較長，改以口述處理", intent.intent));
            }
            system_prompt = prompts::for_style(style).to_string();
            content = transcript.clone();
            existing = None;
        }
    }

    // Context rule 覆蓋語氣 / 附加指示
    let mut tone = tone_str(settings.tone_style);
    if let Some(r) = rule {
        if let Some(t) = r.tone_override.and_then(tone_str) {
            tone = Some(t);
            log(LogLevel::Info, "Context", format!("Context rule 覆蓋語氣: {context_id} → {t}"));
        }
        if !r.extra_prompt.trim().is_empty() {
            log(LogLevel::Info, "Context", format!("Context rule 注入附加指示 ({context_id})"));
        }
    }
    let final_prompt = prompts::append_rule(&system_prompt, rule);

    let meta = metadata_json(
        &content,
        &context_id,
        if has_selected { Some("edit") } else { None },
        tone,
        &settings.language_preference,
        &req.dictionary,
        &req.skills,
        settings.enable_whisper_mode,
    );
    let user_message = prompts::build_user_message(&content, existing, &meta);

    let opts = custom_opts(settings, prompts::temperature_for_style(style));
    let mut accumulated = String::new();
    client.stream_chat(&provider, api_key, &model, &final_prompt, &user_message, &opts, cancel, &mut |ev| match ev {
        LlmStreamEvent::Delta(d) => {
            accumulated.push_str(&d);
            on_partial(&accumulated);
        }
        LlmStreamEvent::Usage(u) => add_usage(&mut usage, &u),
    })?;
    // 取消時串流可能只是提早結束：回 Cancelled，別被當成「AI 沒有回應」
    if cancel.is_cancelled() {
        return Err(LlmError::Cancelled.into());
    }
    if accumulated.trim().is_empty() {
        log(LogLevel::Error, "LLM", "LLM 回傳空結果");
        return Err(RefinerError::EmptyResponse.into());
    }
    let text = extract_replacement_if_command_json(&accumulated);
    log_sensitive(LogLevel::Info, "LLM", format!("LLM 結果: {}", preview(&text, 100)));
    Ok(RefineResult { outcome: RefineOutcome::Text(text), usage, model })
}

/// Stage 1：8 秒逾時或失敗 fallback dictation；外部取消 rethrow Cancelled
#[allow(clippy::too_many_arguments)]
fn classify_intent(
    client: &LlmClient,
    settings: &Settings,
    provider: &LlmProvider,
    api_key: Option<&str>,
    model: &str,
    transcript: &str,
    context_id: &str,
    skills: &[Skill],
    cancel: &CancelToken,
    usage: &mut TokenUsage,
) -> anyhow::Result<Intent> {
    let skill_list: Vec<(String, String)> = skills.iter().map(|s| (s.trigger.clone(), s.content.clone())).collect();
    let system = prompts::intent_classification_with_skills(&skill_list);
    let meta = metadata_json(
        &format!("Transcript: {transcript}"),
        context_id,
        None,
        None,
        &settings.language_preference,
        &[],
        &[],
        false,
    );
    let opts = LlmRequestOptions { temperature: Some(0.1), json_mode: true, ..Default::default() };
    let result = run_with_timeout(INTENT_TIMEOUT, cancel, {
        let client = client.clone();
        let provider = provider.clone();
        let key = api_key.map(String::from);
        let model = model.to_string();
        move |child: &CancelToken| client.complete(&provider, key.as_deref(), &model, &system, &meta, &opts, child)
    });
    match result {
        TimedResult::Cancelled => Err(LlmError::Cancelled.into()),
        TimedResult::TimedOut => {
            log(LogLevel::Error, "LLM", "Stage 1 逾時 (8s)，fallback dictation");
            Ok(Intent::dictation())
        }
        TimedResult::Done(Err(e)) => {
            if cancel.is_cancelled() {
                return Err(LlmError::Cancelled.into());
            }
            log(LogLevel::Error, "LLM", format!("Stage 1 失敗: {e}，fallback dictation"));
            Ok(Intent::dictation())
        }
        TimedResult::Done(Ok((raw, u))) => {
            add_usage(usage, &u);
            match serde_json::from_str::<Intent>(&strip_code_fence(&raw)) {
                Ok(parsed) => {
                    let mut msg = format!("Stage 1 意圖: {}", parsed.intent);
                    if let Some(l) = &parsed.language {
                        msg.push_str(&format!(", lang={l}"));
                    }
                    if let Some(s) = &parsed.style {
                        msg.push_str(&format!(", style={s}"));
                    }
                    if let Some(s) = &parsed.skill_name {
                        msg.push_str(&format!(", skill={s}"));
                    }
                    log(LogLevel::Info, "LLM", msg);
                    Ok(parsed)
                }
                Err(_) => {
                    log_sensitive(LogLevel::Info, "LLM", format!("Stage 1 JSON 解析失敗，fallback dictation: {}", preview(&raw, 100)));
                    Ok(Intent::dictation())
                }
            }
        }
    }
}

enum TimedResult<T> {
    Done(T),
    TimedOut,
    Cancelled,
}

/// 在背景執行緒跑 `f(child_token)`；逾時或外部取消時置位 child token 並立即返回
fn run_with_timeout<T: Send + 'static>(
    timeout: Duration,
    cancel: &CancelToken,
    f: impl FnOnce(&CancelToken) -> T + Send + 'static,
) -> TimedResult<T> {
    let child = CancelToken::new();
    let (tx, rx) = crossbeam_channel::bounded(1);
    let c2 = child.clone();
    let spawned = std::thread::Builder::new().name("saybit-llm-stage1".into()).spawn(move || {
        let _ = tx.send(f(&c2));
    });
    if spawned.is_err() {
        return TimedResult::TimedOut;
    }
    let deadline = Instant::now() + timeout;
    loop {
        if cancel.is_cancelled() {
            child.cancel();
            return TimedResult::Cancelled;
        }
        let now = Instant::now();
        if now >= deadline {
            child.cancel();
            return TimedResult::TimedOut;
        }
        match rx.recv_timeout((deadline - now).min(Duration::from_millis(50))) {
            Ok(v) => return TimedResult::Done(v),
            Err(crossbeam_channel::RecvTimeoutError::Timeout) => continue,
            Err(crossbeam_channel::RecvTimeoutError::Disconnected) => return TimedResult::TimedOut,
        }
    }
}

#[derive(serde::Deserialize)]
struct EventResponse {
    title: String,
    date: String,
    #[serde(default)]
    duration_minutes: Option<i64>,
    #[serde(default)]
    location: Option<String>,
    #[serde(default)]
    notes: Option<String>,
    confirmation_text: String,
}

#[derive(serde::Deserialize)]
struct ReminderResponse {
    title: String,
    #[serde(default)]
    due_date: Option<String>,
    #[serde(default)]
    notes: Option<String>,
    confirmation_text: String,
}

/// 解析行事曆 / 提醒的 JSON（給 pipeline 外部也能用）；回 (動作, 確認文字)
pub fn parse_action_json(intent: &str, raw: &str) -> anyhow::Result<(PendingAction, String)> {
    let cleaned = strip_code_fence(raw);
    if intent == "create_event" {
        let r: EventResponse = serde_json::from_str(&cleaned)?;
        let end = chrono::DateTime::parse_from_rfc3339(&r.date)
            .ok()
            .map(|start| (start + chrono::Duration::minutes(r.duration_minutes.unwrap_or(60).max(1))).to_rfc3339());
        let notes = match (r.notes.filter(|s| !s.trim().is_empty()), r.location.filter(|s| !s.trim().is_empty())) {
            (Some(n), Some(l)) => Some(format!("{n}\n地點：{l}")),
            (Some(n), None) => Some(n),
            (None, Some(l)) => Some(format!("地點：{l}")),
            (None, None) => None,
        };
        Ok((PendingAction::CalendarEvent { title: r.title, start: r.date, end, notes }, r.confirmation_text))
    } else {
        let r: ReminderResponse = serde_json::from_str(&cleaned)?;
        Ok((
            PendingAction::Reminder { title: r.title, due: r.due_date.filter(|s| !s.is_empty()), notes: r.notes },
            r.confirmation_text,
        ))
    }
}

#[allow(clippy::too_many_arguments)]
fn process_action_intent(
    client: &LlmClient,
    settings: &Settings,
    provider: &LlmProvider,
    api_key: Option<&str>,
    model: &str,
    intent: &Intent,
    transcript: &str,
    cancel: &CancelToken,
) -> anyhow::Result<(RefineOutcome, TokenUsage)> {
    let content = intent.content.clone().filter(|c| !c.is_empty()).unwrap_or_else(|| transcript.to_string());
    let system = prompts::for_intent(intent, &settings.language_preference);
    let meta = metadata_json(&content, "", None, None, &settings.language_preference, &[], &[], false);
    log_sensitive(LogLevel::Info, "Action", format!("Action intent: {}, content: {}", intent.intent, preview(&content, 80)));
    let opts = LlmRequestOptions { temperature: Some(0.1), json_mode: true, ..Default::default() };
    let (raw, usage) = match client.complete(provider, api_key, model, &system, &meta, &opts, cancel) {
        Ok(v) => v,
        Err(e) => {
            if cancel.is_cancelled() || is_cancelled(&e) {
                return Err(LlmError::Cancelled.into());
            }
            let msg = format!("動作執行失敗：{}", friendly_error(&e));
            log(LogLevel::Error, "Action", msg.clone());
            return Err(RefinerError::ActionFailed(msg).into());
        }
    };
    match parse_action_json(&intent.intent, &raw) {
        Ok((action, confirmation)) => {
            log_sensitive(LogLevel::Info, "Action", format!("Action preview: {action:?}"));
            Ok((RefineOutcome::Action { action, confirmation }, usage))
        }
        Err(_) => {
            let msg = "動作執行失敗：動作資料解析失敗".to_string();
            log(LogLevel::Error, "Action", msg.clone());
            Err(RefinerError::ActionFailed(msg).into())
        }
    }
}

/// 轉錄是否短到像「單純指令」。CJK 字元每字算 1、其他以英數連續片段每段算 1。
pub fn looks_like_bare_command(transcript: &str, max_units: usize) -> bool {
    let mut units = 0usize;
    let mut in_word = false;
    for c in transcript.chars() {
        let v = c as u32;
        let cjk = (0x3040..=0x30FF).contains(&v)
            || (0x3400..=0x4DBF).contains(&v)
            || (0x4E00..=0x9FFF).contains(&v)
            || (0xAC00..=0xD7AF).contains(&v)
            || (0xF900..=0xFAFF).contains(&v);
        if cjk {
            units += 1;
            in_word = false;
        } else if c.is_alphabetic() || c.is_ascii_digit() {
            if !in_word {
                units += 1;
                in_word = true;
            }
        } else {
            in_word = false;
        }
        if units > max_units {
            return false;
        }
    }
    true
}

pub fn strip_code_fence(raw: &str) -> String {
    raw.trim().replace("```json", "").replace("```", "").trim().to_string()
}

/// LLM 有時把 edit 模式結果以 Command JSON 回（`{"action":…,"replacement":…}`），取出 replacement
pub fn extract_replacement_if_command_json(text: &str) -> String {
    let trimmed = strip_code_fence(text);
    if trimmed.starts_with('{') && trimmed.ends_with('}') {
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&trimmed) {
            if v["action"].is_string() {
                if let Some(r) = v["replacement"].as_str().filter(|r| !r.is_empty()) {
                    log(LogLevel::Info, "LLM", "偵測到 Command JSON，提取 replacement 欄位");
                    return r.to_string();
                }
            }
        }
    }
    text.to_string()
}

fn status_message(code: u16) -> String {
    match code {
        401 => "API Key 無效".into(),
        402 => "API 餘額不足".into(),
        429 => "API 請求過於頻繁，請稍後再試".into(),
        500..=599 => "伺服器暫時不可用".into(),
        c => format!("API 錯誤 ({c})"),
    }
}

/// 把使用者看得懂的錯誤訊息（401 → key 錯、402 → 餘額不足、網路…）
pub fn friendly_error(err: &anyhow::Error) -> String {
    if let Some(e) = err.downcast_ref::<LlmError>() {
        return match e {
            LlmError::NoApiKey(p) => format!("未設定 {p} API Key，請在設定中輸入"),
            LlmError::Http { status, detail } => {
                let base = status_message(*status);
                if detail.trim().is_empty() {
                    base
                } else {
                    format!("{base}（{}）", detail.chars().take(120).collect::<String>())
                }
            }
            LlmError::RetriesExhausted { status, attempts } => format!("重試 {attempts} 次仍失敗 (HTTP {status})"),
            LlmError::Network(_) => "網路連線失敗".into(),
            LlmError::Stream(_) | LlmError::InsecureEndpoint(_) | LlmError::Cancelled => e.to_string(),
        };
    }
    if let Some(e) = err.downcast_ref::<RefinerError>() {
        return e.to_string();
    }
    err.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn llm_bare_command() {
        assert!(looks_like_bare_command("翻譯成日文", 25));
        assert!(looks_like_bare_command("translate to Japanese", 25));
        assert!(!looks_like_bare_command(&"今天天氣很好".repeat(5), 25));
        assert!(!looks_like_bare_command(&"word ".repeat(26), 25));
    }

    #[test]
    fn llm_command_json_and_fence() {
        assert_eq!(extract_replacement_if_command_json("```json\n{\"action\":\"replace\",\"replacement\":\"嗨\"}\n```"), "嗨");
        assert_eq!(extract_replacement_if_command_json("{\"a\":1}"), "{\"a\":1}");
        assert_eq!(extract_replacement_if_command_json("hello"), "hello");
        assert_eq!(strip_code_fence("```json\n{}\n```"), "{}");
    }

    #[test]
    fn llm_parse_actions() {
        let (a, c) = parse_action_json(
            "create_event",
            "```json\n{\"title\":\"會議\",\"date\":\"2026-01-29T15:00:00+08:00\",\"duration_minutes\":30,\"location\":\"A室\",\"notes\":null,\"confirmation_text\":\"已建立\"}\n```",
        )
        .unwrap();
        assert_eq!(c, "已建立");
        match a {
            PendingAction::CalendarEvent { title, start, end, notes } => {
                assert_eq!(title, "會議");
                assert_eq!(start, "2026-01-29T15:00:00+08:00");
                assert_eq!(end.as_deref(), Some("2026-01-29T15:30:00+08:00"));
                assert_eq!(notes.as_deref(), Some("地點：A室"));
            }
            _ => panic!(),
        }
        let (r, _) = parse_action_json("create_reminder", "{\"title\":\"買牛奶\",\"due_date\":null,\"confirmation_text\":\"ok\"}").unwrap();
        assert_eq!(r, PendingAction::Reminder { title: "買牛奶".into(), due: None, notes: None });
        assert!(parse_action_json("create_event", "nope").is_err());
    }

    #[test]
    fn llm_friendly_errors() {
        let e: anyhow::Error = LlmError::Http { status: 401, detail: "bad".into() }.into();
        assert_eq!(friendly_error(&e), "API Key 無效（bad）");
        let e: anyhow::Error = LlmError::Http { status: 402, detail: String::new() }.into();
        assert_eq!(friendly_error(&e), "API 餘額不足");
        let e: anyhow::Error = LlmError::Network("x".into()).into();
        assert_eq!(friendly_error(&e), "網路連線失敗");
        let e: anyhow::Error = RefinerError::EmptyResponse.into();
        assert_eq!(friendly_error(&e), "LLM 未回傳任何文字");
    }

    #[test]
    fn llm_metadata_json_fields() {
        let d = vec![DictionaryEntry { id: 1, term: "openai".into(), preferred: "OpenAI".into() }];
        let m = metadata_json("hi", "slack", Some("edit"), Some("casual"), "zh-TW", &d, &[], true);
        let v: serde_json::Value = serde_json::from_str(&m).unwrap();
        assert_eq!(v["transcript"], "hi");
        assert_eq!(v["context"], "slack");
        assert_eq!(v["personal_dictionary"]["openai"], "OpenAI");
        assert_eq!(v["whisper_mode"], true);
        assert!(v.get("existing_text").is_none());
        assert!(v.get("snippets").is_none());
    }

    #[test]
    fn llm_timeout_helper() {
        let cancel = CancelToken::new();
        let r = run_with_timeout(Duration::from_millis(100), &cancel, |c: &CancelToken| {
            while !c.is_cancelled() {
                std::thread::sleep(Duration::from_millis(5));
            }
            1
        });
        assert!(matches!(r, TimedResult::TimedOut));
        cancel.cancel();
        let r = run_with_timeout(Duration::from_secs(5), &cancel, |_c: &CancelToken| 1);
        assert!(matches!(r, TimedResult::Cancelled | TimedResult::Done(1)));
        let r = run_with_timeout(Duration::from_secs(5), &CancelToken::new(), |_c: &CancelToken| 7);
        assert!(matches!(r, TimedResult::Done(7)));
    }
}

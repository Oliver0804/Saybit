//! 設定讀寫（批次 C2）。JSON 存在 `paths::settings_file()`；新欄位靠 `#[serde(default)]` 向後相容。
use crate::types::*;
use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BaseUrlValidation { Ok, InsecureRemote, Invalid }

/// 讀 `paths::settings_file()`；檔案不存在回預設；JSON 壞掉時先把原檔改名保留（不覆蓋）再回預設。
pub fn load() -> Settings {
    load_from(&crate::paths::settings_file())
}

pub fn save(settings: &Settings) -> anyhow::Result<()> {
    save_to(&crate::paths::settings_file(), settings)
}

pub fn load_from(path: &Path) -> Settings {
    let raw = match std::fs::read_to_string(path) {
        Ok(s) => s,
        Err(_) => return Settings::default(),
    };
    match serde_json::from_str::<serde_json::Value>(&raw) {
        Ok(v) => from_value_lenient(v),
        Err(e) => {
            let backup = path.with_extension(format!("json.corrupt-{}", chrono::Local::now().format("%Y%m%d-%H%M%S")));
            let _ = std::fs::rename(path, &backup);
            crate::logging::log(
                LogLevel::Error,
                "Settings",
                format!("設定檔解析失敗（{e}），已備份到 {} 並改用預設值", backup.display()),
            );
            Settings::default()
        }
    }
}

/// 先寫暫存檔再 rename，寫到一半當機也不會留下半個 JSON
pub fn save_to(path: &Path, settings: &Settings) -> anyhow::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let json = serde_json::to_string_pretty(settings)?;
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, json)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

/// 逐欄合併：某個欄位的值不合法（手改壞、舊版 enum 值）只丟掉那一欄，其他欄位保留。
pub fn from_value_lenient(stored: serde_json::Value) -> Settings {
    let mut settings = match serde_json::from_value::<Settings>(stored.clone()) {
        Ok(s) => s,
        Err(_) => {
            let serde_json::Value::Object(stored) = stored else { return Settings::default() };
            let mut merged = match serde_json::to_value(Settings::default()) {
                Ok(serde_json::Value::Object(m)) => m,
                _ => return Settings::default(),
            };
            for (k, v) in stored {
                if !merged.contains_key(&k) {
                    continue;
                }
                let mut candidate = merged.clone();
                candidate.insert(k, v);
                if serde_json::from_value::<Settings>(serde_json::Value::Object(candidate.clone())).is_ok() {
                    merged = candidate;
                }
            }
            serde_json::from_value(serde_json::Value::Object(merged)).unwrap_or_default()
        }
    };
    sanitize(&mut settings);
    settings
}

/// 數值範圍與壞掉的項目（移植 saybit-desktop loadSettings 的防呆）
pub fn sanitize(s: &mut Settings) {
    let d = Settings::default();
    if s.max_recording_secs < 5 {
        s.max_recording_secs = d.max_recording_secs;
    }
    s.voice_modes.retain(|m| !m.id.trim().is_empty() && !m.name.trim().is_empty());
    fn finite_or(v: f32, lo: f32, hi: f32, def: f32) -> f32 {
        if v.is_finite() { v.clamp(lo, hi) } else { def }
    }
    s.mic_sensitivity = finite_or(s.mic_sensitivity, 0.1, 5.0, d.mic_sensitivity);
    s.silence_timeout_secs = finite_or(s.silence_timeout_secs, 0.5, 30.0, d.silence_timeout_secs);
    s.preview_timeout_secs = finite_or(s.preview_timeout_secs, 1.0, 120.0, d.preview_timeout_secs);
    s.smart_send_delay_secs = finite_or(s.smart_send_delay_secs, 0.0, 30.0, d.smart_send_delay_secs);
    s.capsule_scale = finite_or(s.capsule_scale, 0.5, 2.0, d.capsule_scale);
    s.llm_temperature = finite_or(s.llm_temperature, 0.0, 2.0, d.llm_temperature);
    s.llm_top_p = finite_or(s.llm_top_p, 0.0, 1.0, d.llm_top_p);
    if s.llm_max_tokens == 0 {
        s.llm_max_tokens = d.llm_max_tokens;
    }
    if s.selected_provider_id.trim().is_empty() {
        s.selected_provider_id = d.selected_provider_id;
    }
}

/// https → Ok；http 且 host 是 localhost / 127.x / 10.x / 172.16-31.x / 192.168.x / *.local → Ok；其他 http → InsecureRemote；解析失敗 → Invalid
pub fn validate_base_url(raw: &str) -> BaseUrlValidation {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return BaseUrlValidation::Invalid;
    }
    let Ok(url) = url::Url::parse(trimmed) else { return BaseUrlValidation::Invalid };
    let Some(host) = url.host() else { return BaseUrlValidation::Invalid };
    match url.scheme() {
        "https" => BaseUrlValidation::Ok,
        "http" => {
            if is_local_host(&host) {
                BaseUrlValidation::Ok
            } else {
                BaseUrlValidation::InsecureRemote
            }
        }
        _ => BaseUrlValidation::Invalid,
    }
}

fn is_local_host(host: &url::Host<&str>) -> bool {
    match host {
        url::Host::Domain(d) => {
            let h = d.trim_end_matches('.').to_ascii_lowercase();
            h == "localhost" || h.ends_with(".localhost") || h.ends_with(".local")
        }
        url::Host::Ipv4(ip) => {
            let [a, b, _, _] = ip.octets();
            a == 127 || a == 10 || (a == 172 && (16..=31).contains(&b)) || (a == 192 && b == 168)
        }
        url::Host::Ipv6(ip) => ip.is_loopback(),
    }
}

/// `validate_base_url` 的中文說明（Ok 回 None）
pub fn base_url_validation_message(v: BaseUrlValidation, url: &str) -> Option<String> {
    match v {
        BaseUrlValidation::Ok => None,
        BaseUrlValidation::InsecureRemote => Some(format!(
            "端點 {url} 使用未加密的 http:// 連到外部主機，API Key 與內容會以明文傳送；請改用 https://（http 僅允許本機或區網位址）"
        )),
        BaseUrlValidation::Invalid => Some(format!("端點 URL 無效：{url}（需為 https://… 或本機 / 區網的 http://…）")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_base_url_three_results() {
        use BaseUrlValidation::*;
        assert_eq!(validate_base_url("https://api.openai.com/v1/chat/completions"), Ok);
        assert_eq!(validate_base_url("  https://example.com  "), Ok);
        assert_eq!(validate_base_url("http://localhost:1234/v1/chat/completions"), Ok);
        assert_eq!(validate_base_url("http://127.0.0.1:11434/v1"), Ok);
        assert_eq!(validate_base_url("http://10.0.0.5/v1"), Ok);
        assert_eq!(validate_base_url("http://172.16.1.1/v1"), Ok);
        assert_eq!(validate_base_url("http://172.31.255.1/v1"), Ok);
        assert_eq!(validate_base_url("http://192.168.1.10:8080"), Ok);
        assert_eq!(validate_base_url("http://my-box.local:8080"), Ok);
        assert_eq!(validate_base_url("http://[::1]:8080/v1"), Ok);
        assert_eq!(validate_base_url("http://api.example.com/v1"), InsecureRemote);
        assert_eq!(validate_base_url("http://172.32.0.1/v1"), InsecureRemote);
        assert_eq!(validate_base_url("http://8.8.8.8/v1"), InsecureRemote);
        assert_eq!(validate_base_url("http://localhost.evil.com/v1"), InsecureRemote);
        assert_eq!(validate_base_url(""), Invalid);
        assert_eq!(validate_base_url("not a url"), Invalid);
        assert_eq!(validate_base_url("ftp://example.com"), Invalid);
        assert_eq!(validate_base_url("file:///etc/passwd"), Invalid);
        assert!(base_url_validation_message(InsecureRemote, "http://x").unwrap().contains("http://x"));
        assert!(base_url_validation_message(Ok, "https://x").is_none());
    }

    #[test]
    fn settings_round_trip_and_lenient_load() {
        let dir = std::env::temp_dir().join(format!("saybit-settings-test-{}", uuid::Uuid::new_v4()));
        let path = dir.join("settings.json");
        assert_eq!(load_from(&path), Settings::default());

        let s = Settings { selected_model: "gpt-4.1-nano".into(), enable_smart_send: true, ..Default::default() };
        save_to(&path, &s).unwrap();
        assert_eq!(load_from(&path), s);

        // 一個欄位壞掉只丟那一欄
        std::fs::write(&path, r#"{"selected_model":"x","stt_engine":"no_such_engine","max_recording_secs":1}"#).unwrap();
        let l = load_from(&path);
        assert_eq!(l.selected_model, "x");
        assert_eq!(l.stt_engine, Settings::default().stt_engine);
        assert_eq!(l.max_recording_secs, 300);

        // JSON 壞掉：備份原檔、回預設
        std::fs::write(&path, "{not json").unwrap();
        assert_eq!(load_from(&path), Settings::default());
        assert!(!path.exists());
        let backups: Vec<_> = std::fs::read_dir(&dir).unwrap().flatten().collect();
        assert_eq!(backups.len(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }
}

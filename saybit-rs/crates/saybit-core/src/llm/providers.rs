//! 服務商表（移植 LLMProvider.swift：OpenRouter / OpenAI / DeepSeek / Groq / Together / Ollama / LM Studio）
use crate::types::*;

fn p(
    id: &str,
    name: &str,
    base_url: &str,
    headers: &[(&str, &str)],
    key_placeholder: &str,
    model_hint: &str,
    requires_api_key: bool,
) -> LlmProvider {
    LlmProvider {
        id: id.into(),
        name: name.into(),
        base_url: base_url.into(),
        extra_headers: headers.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(),
        key_placeholder: key_placeholder.into(),
        model_hint: model_hint.into(),
        is_built_in: true,
        requires_api_key,
    }
}

/// 內建服務商（Apple 本機模型不在 Rust 版）
pub fn built_in() -> Vec<LlmProvider> {
    vec![
        p(
            "openrouter",
            "OpenRouter",
            "https://openrouter.ai/api/v1/chat/completions",
            &[("HTTP-Referer", "https://saybit.bashcat.net"), ("X-Title", "Saybit")],
            "sk-or-v1-...",
            "deepseek/deepseek-v4-flash · deepseek/deepseek-v4-pro · openai/gpt-4.1-nano · google/gemini-2.5-flash",
            true,
        ),
        p("openai", "OpenAI", "https://api.openai.com/v1/chat/completions", &[], "sk-...", "gpt-4.1-nano · gpt-4.1-mini · gpt-4o", true),
        p("deepseek", "DeepSeek", "https://api.deepseek.com/chat/completions", &[], "sk-...", "deepseek-chat · deepseek-reasoner", true),
        p("groq", "Groq", "https://api.groq.com/openai/v1/chat/completions", &[], "gsk_...", "llama-3.3-70b-versatile · gemma2-9b-it", true),
        p(
            "together",
            "Together AI",
            "https://api.together.xyz/v1/chat/completions",
            &[],
            "...",
            "meta-llama/Llama-3.3-70B-Instruct-Turbo · Qwen/Qwen2.5-72B-Instruct-Turbo",
            true,
        ),
        p("ollama", "Ollama (本地)", "http://localhost:11434/v1/chat/completions", &[], "", "llama3 · qwen2.5 · gemma2 · mistral", false),
        p("lmstudio", "LM Studio (本地)", "http://localhost:1234/v1/chat/completions", &[], "lm-studio-...", "", false),
    ]
}

/// 內建 + 自訂；LM Studio 的位址換成設定裡的（正規化後）
pub fn all(settings: &Settings) -> Vec<LlmProvider> {
    let mut v = built_in();
    for prov in v.iter_mut() {
        if prov.id == "lmstudio" && !settings.lm_studio_base_url.trim().is_empty() {
            prov.base_url = normalize_local_base_url(&settings.lm_studio_base_url);
        }
    }
    v.extend(settings.custom_providers.iter().cloned());
    v
}

pub fn find(settings: &Settings, id: &str) -> Option<LlmProvider> {
    all(settings).into_iter().find(|p| p.id == id)
}

/// 目前選的服務商；找不到（自訂的被刪掉）退回 OpenRouter
pub fn selected(settings: &Settings) -> LlmProvider {
    find(settings, &settings.selected_provider_id).unwrap_or_else(|| built_in().remove(0))
}

/// 自訂服務商（id 以 `custom-` 開頭，失敗 400 時 client 會拿掉 stream_options 重試）
pub fn custom(id: &str, name: &str, base_url: &str) -> LlmProvider {
    LlmProvider {
        id: id.into(),
        name: name.into(),
        base_url: base_url.into(),
        extra_headers: Vec::new(),
        key_placeholder: "...".into(),
        model_hint: String::new(),
        is_built_in: false,
        requires_api_key: true,
    }
}

pub fn default_model(provider_id: &str) -> Option<&'static str> {
    Some(match provider_id {
        "openrouter" => "deepseek/deepseek-v4-flash",
        "openai" => "gpt-4.1-nano",
        "deepseek" => "deepseek-chat",
        "groq" => "llama-3.3-70b-versatile",
        "together" => "meta-llama/Llama-3.3-70B-Instruct-Turbo",
        _ => return None,
    })
}

pub fn key_portal_url(provider_id: &str) -> Option<&'static str> {
    Some(match provider_id {
        "openrouter" => "https://openrouter.ai/keys",
        "openai" => "https://platform.openai.com/api-keys",
        "deepseek" => "https://platform.deepseek.com/api_keys",
        "groq" => "https://console.groq.com/keys",
        "together" => "https://api.together.xyz/settings/api-keys",
        _ => return None,
    })
}

/// 要先儲值才能呼叫（沒儲值會回 402）；Groq 有免費額度
pub fn needs_prepaid_credit(provider_id: &str) -> bool {
    matches!(provider_id, "openrouter" | "openai" | "deepseek")
}

/// LM Studio / Ollama 位址正規化（移植 SettingsStore.normalizeLMStudioURL）：
/// 容忍尾巴 `/`、已含 `/v1`、已含 `/v1/chat/completions`，統一成 `<origin>/v1/chat/completions`
pub fn normalize_local_base_url(raw: &str) -> String {
    let s = raw.trim().trim_end_matches('/');
    if s.ends_with("/chat/completions") {
        s.to_string()
    } else if s.ends_with("/v1") {
        format!("{s}/chat/completions")
    } else {
        format!("{s}/v1/chat/completions")
    }
}

/// `scheme://host[:port]`（Ollama /api/tags、LM Studio /api/v1/models 用）
pub fn origin(base_url: &str) -> Option<String> {
    let url = url::Url::parse(base_url.trim()).ok()?;
    let host = url.host_str()?;
    let port = url.port().map(|p| format!(":{p}")).unwrap_or_default();
    Some(format!("{}://{host}{port}", url.scheme()))
}

/// 從 chat/completions 推導 /models：".../v1/chat/completions" → ".../v1/models"
pub fn models_endpoint(base_url: &str) -> Option<String> {
    let url = url::Url::parse(base_url.trim()).ok()?;
    let mut parts: Vec<&str> = url.path().split('/').filter(|s| !s.is_empty()).collect();
    if parts.last() == Some(&"completions") {
        parts.pop();
    }
    if parts.last() == Some(&"chat") {
        parts.pop();
    }
    parts.push("models");
    Some(format!("{}/{}", origin(base_url)?, parts.join("/")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn llm_providers_table() {
        let b = built_in();
        assert_eq!(b.len(), 7);
        assert!(b.iter().all(|p| p.is_built_in));
        assert!(!b.iter().find(|p| p.id == "ollama").unwrap().requires_api_key);
        assert_eq!(default_model("openai"), Some("gpt-4.1-nano"));
        assert_eq!(default_model("ollama"), None);
        assert!(needs_prepaid_credit("deepseek"));
        assert!(!needs_prepaid_credit("groq"));
        assert!(key_portal_url("groq").is_some());

        let mut s = Settings { lm_studio_base_url: "http://192.168.1.5:1234/".into(), ..Default::default() };
        s.custom_providers.push(custom("custom-1", "Mine", "https://x.example/v1/chat/completions"));
        assert_eq!(find(&s, "lmstudio").unwrap().base_url, "http://192.168.1.5:1234/v1/chat/completions");
        assert_eq!(find(&s, "custom-1").unwrap().name, "Mine");
        s.selected_provider_id = "gone".into();
        assert_eq!(selected(&s).id, "openrouter");
    }

    #[test]
    fn llm_normalize_and_endpoints() {
        assert_eq!(normalize_local_base_url("http://localhost:1234"), "http://localhost:1234/v1/chat/completions");
        assert_eq!(normalize_local_base_url("http://localhost:1234/v1/"), "http://localhost:1234/v1/chat/completions");
        assert_eq!(
            normalize_local_base_url(" http://localhost:1234/v1/chat/completions "),
            "http://localhost:1234/v1/chat/completions"
        );
        assert_eq!(models_endpoint("https://api.openai.com/v1/chat/completions").unwrap(), "https://api.openai.com/v1/models");
        assert_eq!(models_endpoint("https://api.deepseek.com/chat/completions").unwrap(), "https://api.deepseek.com/models");
        assert_eq!(origin("http://localhost:11434/v1/chat/completions").unwrap(), "http://localhost:11434");
    }
}

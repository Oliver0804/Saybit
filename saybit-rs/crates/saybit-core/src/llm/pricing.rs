//! 價格表（移植 ModelPricing.swift；前綴＋邊界比對，去掉 provider/ 前綴與 :tag，:free 為 0）
//! 概略單價（USD per 1K tokens），實際以服務商當下定價為準，僅作粗估顯示。

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ModelPrice {
    pub input_per_1k: f64,
    pub output_per_1k: f64,
}

impl ModelPrice {
    pub fn cost(&self, prompt_tokens: u32, completion_tokens: u32) -> f64 {
        prompt_tokens as f64 / 1000.0 * self.input_per_1k + completion_tokens as f64 / 1000.0 * self.output_per_1k
    }
}

/// 第一個命中的 entry 會被採用，順序由「具體 → 通用」
const TABLE: &[(&str, f64, f64)] = &[
    // OpenAI
    ("gpt-4.1-nano", 0.0001, 0.0004),
    ("gpt-4.1-mini", 0.0004, 0.0016),
    ("gpt-4.1", 0.002, 0.008),
    ("gpt-4o-mini", 0.00015, 0.0006),
    ("gpt-4o", 0.0025, 0.010),
    ("o1-mini", 0.003, 0.012),
    ("o1", 0.015, 0.060),
    // Anthropic（Opus 4.5 起 $5 / $25 per 1M；4.0 / 4.1 為 $15 / $75）
    ("claude-haiku-4-5", 0.001, 0.005),
    ("claude-sonnet-4-7", 0.003, 0.015),
    ("claude-sonnet-4-6", 0.003, 0.015),
    ("claude-sonnet-4", 0.003, 0.015),
    ("claude-opus-4-7", 0.005, 0.025),
    ("claude-opus-4-6", 0.005, 0.025),
    ("claude-opus-4-5", 0.005, 0.025),
    ("claude-opus-4", 0.015, 0.075),
    // Google
    ("gemini-2.5-flash", 0.000075, 0.0003),
    ("gemini-2.5-pro", 0.00125, 0.010),
    ("gemini-2.0-flash", 0.0001, 0.0004),
    // DeepSeek
    ("deepseek-v4-flash", 0.00014, 0.00028),
    ("deepseek-v4-pro", 0.00055, 0.00219),
    ("deepseek-reasoner", 0.00055, 0.00219),
    ("deepseek-chat", 0.00014, 0.00028),
    ("deepseek-flash", 0.00007, 0.00028),
    ("deepseek-pro", 0.00055, 0.00219),
    ("deepseek-v3", 0.00014, 0.00028),
    // Groq（隨方案變動，僅參考）
    ("llama-3.3-70b", 0.00059, 0.00079),
    ("llama-3.1-70b", 0.00059, 0.00079),
    ("llama-3.1-8b", 0.00005, 0.00008),
    ("gemma2-9b-it", 0.0002, 0.0002),
    // Together AI
    ("qwen2.5-72b", 0.0012, 0.0012),
];

/// 去掉 `provider/` 前綴與 `:tag` 後綴、`.` 視同 `-`
fn normalize(model: &str) -> String {
    let mut lower = model.trim().to_lowercase();
    if let Some(i) = lower.rfind('/') {
        lower = lower[i + 1..].to_string();
    }
    if let Some(i) = lower.find(':') {
        lower.truncate(i);
    }
    lower.replace('.', "-")
}

/// 前綴比對且要求邊界（下一字元非英數），避免 `sao10k/...` 之類被短 pattern 誤配
pub fn price(model: &str) -> Option<ModelPrice> {
    let name = normalize(model);
    if name.is_empty() {
        return None;
    }
    for (pattern, input, output) in TABLE {
        let pat = normalize(pattern);
        let Some(rest) = name.strip_prefix(pat.as_str()) else { continue };
        if rest.chars().next().is_some_and(|c| c.is_alphanumeric()) {
            continue;
        }
        return Some(ModelPrice { input_per_1k: *input, output_per_1k: *output });
    }
    None
}

/// 本地（local/、ollama/）與 `:free` 為 0；未知模型 None
pub fn cost_usd(model: &str, prompt_tokens: u32, completion_tokens: u32) -> Option<f64> {
    let lower = model.trim().to_lowercase();
    if lower.is_empty() {
        return None;
    }
    if lower.starts_with("local/") || lower.starts_with("ollama/") || lower.ends_with(":free") {
        return Some(0.0);
    }
    price(model).map(|p| p.cost(prompt_tokens, completion_tokens))
}

pub fn format_usd(v: f64) -> String {
    if v == 0.0 {
        "$0".into()
    } else if v < 0.0001 {
        "<$0.0001".into()
    } else {
        format!("${v:.4}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn llm_pricing_boundary_match() {
        assert!(cost_usd("sao10k/l3-euryale-70b", 1000, 1000).is_none());
        assert!(price("o1x").is_none());
        assert_eq!(price("openai/o1").unwrap().input_per_1k, 0.015);
        assert_eq!(price("o1-mini").unwrap().input_per_1k, 0.003);
        assert_eq!(price("openai/gpt-4.1-nano").unwrap().input_per_1k, 0.0001);
        assert_eq!(price("gpt-4.1-2025-04-14").unwrap().input_per_1k, 0.002);
        assert_eq!(price("anthropic/claude-opus-4.5").unwrap().input_per_1k, 0.005);
        assert_eq!(price("anthropic/claude-opus-4.1").unwrap().input_per_1k, 0.015);
        assert_eq!(price("meta-llama/llama-3.3-70b-versatile").unwrap().output_per_1k, 0.00079);
        assert_eq!(cost_usd("deepseek/deepseek-v4-flash:free", 999, 999), Some(0.0));
        assert_eq!(cost_usd("ollama/llama3", 999, 999), Some(0.0));
        assert_eq!(cost_usd("", 1, 1), None);
        let c = cost_usd("gpt-4o", 1000, 1000).unwrap();
        assert!((c - 0.0125).abs() < 1e-12);
    }

    #[test]
    fn llm_pricing_format() {
        assert_eq!(format_usd(0.0), "$0");
        assert_eq!(format_usd(0.00001), "<$0.0001");
        assert_eq!(format_usd(0.01234), "$0.0123");
    }
}

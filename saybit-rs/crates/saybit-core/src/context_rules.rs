//! App 語氣規則比對（移植 ContextRule.swift）
use crate::types::*;

/// 第一個啟用、且 `app_identifier` 等於 context identifier（或不分大小寫等於 bundle id）的規則
pub fn matching_rule<'a>(settings: &'a Settings, ctx: &AppContext) -> Option<&'a ContextRule> {
    let id = crate::app_context::context_identifier(ctx);
    settings.context_rules.iter().find(|r| {
        let key = r.app_identifier.trim();
        r.enabled
            && !key.is_empty()
            && (key == id || (!ctx.bundle_id.is_empty() && key.eq_ignore_ascii_case(&ctx.bundle_id)))
    })
}

/// 預設規則（移植 ContextRule.defaultRules；Rust 版語氣只有 formal / casual，technical / neutral 改為不覆寫）
pub fn default_rules() -> Vec<ContextRule> {
    [
        ("slack", Some(ToneStyle::Casual)),
        ("discord", Some(ToneStyle::Casual)),
        ("line", Some(ToneStyle::Casual)),
        ("telegram", Some(ToneStyle::Casual)),
        ("gmail", Some(ToneStyle::Formal)),
        ("outlook", Some(ToneStyle::Formal)),
    ]
    .into_iter()
    .map(|(app, tone)| ContextRule {
        id: uuid::Uuid::new_v4().to_string(),
        app_identifier: app.into(),
        tone_override: tone,
        extra_prompt: String::new(),
        enabled: true,
    })
    .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn context_rules_match() {
        let mut s = Settings { context_rules: default_rules(), ..Default::default() };
        s.context_rules.push(ContextRule {
            id: "x".into(),
            app_identifier: "com.example.App".into(),
            tone_override: None,
            extra_prompt: "x".into(),
            enabled: true,
        });
        let slack = AppContext { app_name: "Slack".into(), ..Default::default() };
        assert_eq!(matching_rule(&s, &slack).unwrap().app_identifier, "slack");
        let custom = AppContext { app_name: "Foo".into(), bundle_id: "com.example.app".into(), ..Default::default() };
        assert_eq!(matching_rule(&s, &custom).unwrap().extra_prompt, "x");
        s.context_rules[0].enabled = false;
        assert!(matching_rule(&s, &slack).is_none());
    }
}

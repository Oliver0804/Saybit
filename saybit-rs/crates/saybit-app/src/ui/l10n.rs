//! 四語字串表。A1 的字串在 `strings_app.rs`，A2 的在 `strings_settings.rs`；key 找不到時回 key 本身。
use saybit_core::AppLanguage;
use std::sync::atomic::{AtomicU8, Ordering};

static LANG: AtomicU8 = AtomicU8::new(0);

pub fn set_language(lang: AppLanguage) {
    LANG.store(index(lang) as u8, Ordering::Relaxed);
}

#[allow(dead_code)]
pub fn current_language() -> AppLanguage {
    match LANG.load(Ordering::Relaxed) {
        1 => AppLanguage::ZhCn,
        2 => AppLanguage::En,
        3 => AppLanguage::Ja,
        _ => AppLanguage::ZhTw,
    }
}

fn index(lang: AppLanguage) -> usize {
    match lang {
        AppLanguage::ZhTw => 0,
        AppLanguage::ZhCn => 1,
        AppLanguage::En => 2,
        AppLanguage::Ja => 3,
    }
}

/// 查字串（zh-TW / zh-CN / en / ja）
pub fn t(key: &str) -> String {
    let i = LANG.load(Ordering::Relaxed) as usize;
    for table in [crate::strings_app::STRINGS, crate::strings_settings::STRINGS] {
        if let Some((_, v)) = table.iter().find(|(k, _)| *k == key) {
            return v[i].to_string();
        }
    }
    key.to_string()
}

/// 帶參數：`{name}` 會被取代
pub fn tf(key: &str, args: &[(&str, &str)]) -> String {
    let mut s = t(key);
    for (k, v) in args {
        s = s.replace(&format!("{{{k}}}"), v);
    }
    s
}

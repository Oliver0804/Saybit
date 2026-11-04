//! 簡體 → 繁體（台灣用詞），等同 OpenCC `s2twp`：
//!   1. STPhrases + STCharacters（最長詞優先）
//!   2. TWPhrases（台灣慣用詞：軟件→軟體、代碼→程式碼…）
//!   3. TWVariants（台灣字形：啓→啟、裏→裡…）
//!
//! 字典是 OpenCC 官方資料（Apache-2.0，見 `opencc/LICENSE`），以 `include_str!` 編進執行檔，
//! 第一次呼叫時解析（約 5 萬筆，數十毫秒）。不用 opencc-rs：它要編 C++ 的 OpenCC，三平台 CI 風險高。

use std::collections::HashMap;
use std::sync::OnceLock;

const ST_PHRASES: &str = include_str!("opencc/STPhrases.txt");
const ST_CHARACTERS: &str = include_str!("opencc/STCharacters.txt");
const TW_PHRASES: &str = include_str!("opencc/TWPhrases.txt");
const TW_VARIANTS: &str = include_str!("opencc/TWVariants.txt");

struct Dict {
    map: HashMap<String, String>,
    /// 最長詞的字數
    max_len: usize,
}

impl Dict {
    fn parse(sources: &[&str]) -> Self {
        let mut map = HashMap::new();
        let mut max_len = 1;
        for src in sources {
            for line in src.lines() {
                if line.starts_with('#') {
                    continue;
                }
                let Some((key, values)) = line.split_once('\t') else {
                    continue;
                };
                // 多個候選時取第一個（OpenCC 的預設）
                let Some(value) = values.split(' ').next().filter(|v| !v.is_empty()) else {
                    continue;
                };
                let key = key.trim();
                if key.is_empty() {
                    continue;
                }
                max_len = max_len.max(key.chars().count());
                // 先載入的優先（詞組在前、單字在後時，同 key 不覆蓋）
                map.entry(key.to_string()).or_insert_with(|| value.to_string());
            }
        }
        Self { map, max_len }
    }

    /// 正向最長匹配
    fn convert(&self, text: &str) -> String {
        let chars: Vec<char> = text.chars().collect();
        let mut out = String::with_capacity(text.len());
        let mut key = String::new();
        let mut i = 0;
        while i < chars.len() {
            let longest = self.max_len.min(chars.len() - i);
            let mut matched = false;
            for len in (1..=longest).rev() {
                key.clear();
                key.extend(&chars[i..i + len]);
                if let Some(v) = self.map.get(&key) {
                    out.push_str(v);
                    i += len;
                    matched = true;
                    break;
                }
            }
            if !matched {
                out.push(chars[i]);
                i += 1;
            }
        }
        out
    }
}

struct Converter {
    st: Dict,
    tw_phrases: Dict,
    tw_variants: Dict,
}

fn converter() -> &'static Converter {
    static C: OnceLock<Converter> = OnceLock::new();
    C.get_or_init(|| Converter {
        st: Dict::parse(&[ST_PHRASES, ST_CHARACTERS]),
        tw_phrases: Dict::parse(&[TW_PHRASES]),
        tw_variants: Dict::parse(&[TW_VARIANTS]),
    })
}

/// 預先解析字典（例如選了 SenseVoice 時），避免第一句 partial 多等幾十毫秒
pub fn preload() {
    let _ = converter();
}

/// 簡體 → 繁體（台灣用詞）。非中文原樣保留。
pub fn to_traditional(text: &str) -> String {
    if !text.chars().any(|c| ('\u{3400}'..='\u{9fff}').contains(&c) || ('\u{20000}'..='\u{2ffff}').contains(&c)) {
        return text.to_string();
    }
    let c = converter();
    let t = c.st.convert(text);
    let t = c.tw_phrases.convert(&t);
    c.tw_variants.convert(&t)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_common_sentences() {
        assert_eq!(to_traditional("我们今天开会讨论软件开发"), "我們今天開會討論軟體開發");
        assert_eq!(to_traditional("头发很长，后来去理发了"), "頭髮很長，後來去理髮了");
        assert_eq!(to_traditional("这里面有什么问题吗？"), "這裡面有什麼問題嗎？");
        assert_eq!(to_traditional("请把代码发给我"), "請把程式碼發給我");
        assert_eq!(to_traditional("吃面条"), "吃麵條");
    }

    #[test]
    fn keeps_traditional_and_non_chinese() {
        assert_eq!(to_traditional("已經是繁體了"), "已經是繁體了");
        assert_eq!(to_traditional("hello, world 123"), "hello, world 123");
        assert_eq!(to_traditional(""), "");
        assert_eq!(to_traditional("OK 好的"), "OK 好的");
    }
}

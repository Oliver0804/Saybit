//! 字典作用在辨識層（移植 DictionaryHints.swift）：單次掃描、長詞優先、不分大小寫、ASCII 整字比對
use crate::types::*;

fn is_ascii_word(c: char) -> bool {
    c.is_ascii_alphanumeric()
}

/// 不分大小寫比對 `text[pos..]` 是否以 `term` 開頭
fn match_at(text: &[char], pos: usize, term: &[char]) -> bool {
    if pos + term.len() > text.len() {
        return false;
    }
    text[pos..pos + term.len()]
        .iter()
        .zip(term)
        .all(|(a, b)| a == b || a.to_lowercase().eq(b.to_lowercase()))
}

/// 單次掃描替換（不會連鎖替換）：長詞優先；ASCII 英數開頭 / 結尾的詞要整字比對
/// （line 不能吃掉 deadline / online 裡的 line）
pub fn apply(text: &str, entries: &[DictionaryEntry]) -> String {
    if text.is_empty() || entries.is_empty() {
        return text.to_string();
    }
    let mut terms: Vec<(Vec<char>, &str)> = Vec::new();
    for e in entries {
        let t = e.term.trim();
        if t.is_empty() {
            continue;
        }
        let chars: Vec<char> = t.chars().collect();
        // key 不分大小寫，重複時第一個為準
        if terms.iter().any(|(c, _)| c.len() == chars.len() && c.iter().zip(&chars).all(|(a, b)| a.to_lowercase().eq(b.to_lowercase()))) {
            continue;
        }
        terms.push((chars, e.preferred.as_str()));
    }
    terms.sort_by_key(|(c, _)| std::cmp::Reverse(c.len()));

    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    'outer: while i < chars.len() {
        for (term, preferred) in &terms {
            if !match_at(&chars, i, term) {
                continue;
            }
            let lead = is_ascii_word(term[0]);
            let trail = is_ascii_word(term[term.len() - 1]);
            if lead && i > 0 && is_ascii_word(chars[i - 1]) {
                continue;
            }
            let end = i + term.len();
            if trail && end < chars.len() && is_ascii_word(chars[end]) {
                continue;
            }
            out.push_str(preferred);
            i = end;
            continue 'outer;
        }
        out.push(chars[i]);
        i += 1;
    }
    out
}

/// 偏好寫法去重，最多 100 個（給有 initial prompt 的引擎）
pub fn hint_terms(entries: &[DictionaryEntry]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for e in entries {
        let p = e.preferred.trim();
        if p.is_empty() || out.iter().any(|x| x == p) {
            continue;
        }
        out.push(p.to_string());
        if out.len() >= 100 {
            break;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn e(term: &str, preferred: &str) -> DictionaryEntry {
        DictionaryEntry { id: 0, term: term.into(), preferred: preferred.into() }
    }

    #[test]
    fn dictionary_apply_rules() {
        let d = vec![e("line", "LINE"), e("open ai", "OpenAI"), e("open", "Open"), e("賽比", "Saybit"), e("wifi", "Wi-Fi")];
        // ASCII 整字
        assert_eq!(apply("deadline online line", &d), "deadline online LINE");
        assert_eq!(apply("Line,line!", &d), "LINE,LINE!");
        // 長詞優先
        assert_eq!(apply("use open ai now", &d), "use OpenAI now");
        assert_eq!(apply("open the door", &d), "Open the door");
        // CJK 不需要邊界；與英文相鄰也可
        assert_eq!(apply("我用賽比打字", &d), "我用Saybit打字");
        assert_eq!(apply("連wifi了", &d), "連Wi-Fi了");
        // 不連鎖替換
        let chain = vec![e("a", "b"), e("b", "c")];
        assert_eq!(apply("a b", &chain), "b c");
        assert_eq!(apply("", &d), "");
        assert_eq!(apply("abc", &[]), "abc");
    }

    #[test]
    fn dictionary_hint_terms_dedupe() {
        let mut d = vec![e("a", "X"), e("b", "X"), e("c", " "), e("d", "Y")];
        assert_eq!(hint_terms(&d), vec!["X", "Y"]);
        d = (0..150).map(|i| e(&format!("t{i}"), &format!("P{i}"))).collect();
        assert_eq!(hint_terms(&d).len(), 100);
    }
}

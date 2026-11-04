//! Whisper 靜音幻聽過濾（移植 saybit-desktop/src/services/sttArtifacts.ts）。
//! whisper 對靜音不回空字串，會吐訓練資料裡的字幕殘留（「字幕:CM 李宗盛」「謝謝。」「Thanks for watching!」）。
//! 兩道防線：送辨識前看能量（`has_enough_energy`），辨識後比對已知樣式（`is_known_artifact`）。

/// 門檻用實測校準：背景音外洩 peak 0.012 / 短促雜訊 0.033 要擋；正常說話 0.251 放行
pub const PEAK_FLOOR: f32 = 0.06;
/// 另一條放行路徑：峰值不高但整段能量足夠（講話平穩、離麥克風較遠）
pub const RMS_FLOOR: f32 = 0.02;

/// 整段轉錄「只有」這些（去標點、小寫後）才視為幻聽；完整比對，使用者真的說「感謝觀看」加上別的字不會被刪
const EXACT_ARTIFACTS: &[&str] = &[
    "謝謝", "謝謝你", "謝謝您", "感謝觀看", "謝謝觀看", "謝謝大家", "謝謝收看", "下次再見", "請訂閱", "再見",
    "好", "嗯", "哦", "thank you", "thank you.", "thanks for watching", "thanks for watching!", "you", "bye",
    "bye.", "bye bye", ".", "。",
];

pub fn energy(samples: &[f32]) -> (f32, f32) {
    if samples.is_empty() {
        return (0.0, 0.0);
    }
    let mut peak = 0.0f32;
    let mut sum = 0.0f32;
    for &s in samples {
        peak = peak.max(s.abs());
        sum += s * s;
    }
    (peak, (sum / samples.len() as f32).sqrt())
}

/// 能量門檻（peak >= 0.06 || rms >= 0.02）
pub fn has_enough_energy(samples: &[f32]) -> bool {
    let (peak, rms) = energy(samples);
    peak >= PEAK_FLOOR || rms >= RMS_FLOOR
}

const STRIP_PUNCT: &[char] = &[
    '，', '。', '！', '？', '、', '：', '；', '「', '」', '『', '』', '…', '—', '～', ',', '!', '?', ';', ':', '"',
    '\'', '(', ')', '（', '）',
];

fn normalize(text: &str) -> String {
    let lower = text.trim().to_lowercase();
    let collapsed = lower.split(|c: char| c.is_whitespace() || c == '\u{3000}').filter(|s| !s.is_empty()).collect::<Vec<_>>().join(" ");
    collapsed.chars().filter(|c| !STRIP_PUNCT.contains(c)).collect::<String>().trim().to_string()
}

fn matches_pattern(s: &str) -> bool {
    let lower = s.to_lowercase();
    if s.starts_with("字幕") {
        return true;
    }
    if ["字幕by", "字幕製作", "字幕提供", "字幕翻譯"].iter().any(|p| lower.contains(p)) {
        return true;
    }
    if let Some(rest) = lower.strip_prefix("subtitle") {
        let rest = rest.strip_prefix('s').unwrap_or(rest);
        if rest.starts_with(char::is_whitespace) && rest.trim_start().starts_with("by") {
            return true;
        }
    }
    if lower.contains("amara.org") || s.contains("明鏡與點點欄目") || s.contains("不吝點贊") || s.contains("打賞支持") {
        return true;
    }
    // ^ming\s*pin\s*tv$
    let compact: String = lower.chars().filter(|c| !c.is_whitespace()).collect();
    if compact == "mingpintv" && lower.trim().starts_with("ming") {
        return true;
    }
    // ^[（(]?(音樂|背景音樂|掌聲|笑聲|music|applause)[）)]?$
    let inner = lower.trim();
    let inner = inner.strip_prefix(['（', '(']).unwrap_or(inner);
    let inner = inner.strip_suffix(['）', ')']).unwrap_or(inner);
    matches!(inner, "音樂" | "背景音樂" | "掌聲" | "笑聲" | "music" | "applause")
}

/// 這段轉錄看起來是不是 whisper 對靜音產生的幻聽（空字串回 false）
pub fn is_known_artifact(text: &str) -> bool {
    let raw = text.trim();
    if raw.is_empty() {
        return false;
    }
    let normalized = normalize(raw);
    if normalized.is_empty() {
        return true; // 只剩標點
    }
    if EXACT_ARTIFACTS.contains(&normalized.as_str()) {
        return true;
    }
    matches_pattern(raw) || matches_pattern(&normalized)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn energy_gate_calibrated_values() {
        assert!(!has_enough_energy(&[]));
        assert!(!has_enough_energy(&[0.012, -0.01, 0.0]));
        assert!(!has_enough_energy(&[0.033, 0.0, 0.0, 0.0]));
        assert!(has_enough_energy(&[0.251, 0.0]));
        // 峰值低但 RMS 夠
        assert!(has_enough_energy(&[0.05; 100]));
        let (p, r) = energy(&[0.5, -0.5]);
        assert_eq!(p, 0.5);
        assert!((r - 0.5).abs() < 1e-6);
    }

    #[test]
    fn artifacts_exact_and_patterns() {
        for t in [
            "謝謝。", "感謝觀看", "Thanks for watching!", "  you ", "。。", "字幕:CM 李宗盛", "由 Amara.org 社群提供的字幕",
            "請不吝點贊 訂閱 轉發 打賞支持明鏡與點點欄目", "Subtitles by the Amara community", "(音樂)", "（掌聲）", "Ming Pin TV",
            "字幕製作：某人",
        ] {
            assert!(is_known_artifact(t), "應判為幻聽：{t}");
        }
        for t in ["", "感謝觀看這部影片的大家", "謝謝你幫我改報告", "音樂會在幾點", "hello world", "好啊我們走"] {
            assert!(!is_known_artifact(t), "不應判為幻聽：{t}");
        }
    }
}

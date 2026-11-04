//! 靜音偵測狀態機（移植 SilenceDetector.swift）。
//! - 講過話之後連續 `timeout_secs` 低於靜音門檻 → 觸發
//! - 開始後 3 秒內從未講話 → 觸發（noSpeechTimeout）
//! - 介於靜音與語音門檻之間的音量不重置也不累積（遲滯）
//!
//! 時間用 `Instant`（單調時鐘）；呼叫端自己負責執行緒同步。

use std::time::{Duration, Instant};

/// 原生版預設：silence 0.08 / speech 0.15
pub const DEFAULT_SILENCE_THRESHOLD: f32 = 0.08;
const SPEECH_TO_SILENCE_RATIO: f32 = 0.15 / 0.08;
pub const NO_SPEECH_TIMEOUT: Duration = Duration::from_secs(3);

/// 靜音偵測（移植 SilenceDetector.swift；VAD 有講話時可外部 `mark_speech()`）
pub struct SilenceDetector {
    timeout: Duration,
    silence_threshold: f32,
    speech_threshold: f32,
    recording_start: Option<Instant>,
    silence_start: Option<Instant>,
    has_speech: bool,
    fired: bool,
}

impl SilenceDetector {
    /// `threshold` = 靜音門檻（0..1 正規化音量，預設 0.08）；語音門檻依原生比例自動推（0.08 → 0.15）
    pub fn new(timeout_secs: f32, threshold: f32) -> Self {
        let silence = if threshold > 0.0 { threshold } else { DEFAULT_SILENCE_THRESHOLD };
        Self {
            timeout: Duration::from_secs_f32(timeout_secs.max(0.1)),
            silence_threshold: silence,
            speech_threshold: (silence * SPEECH_TO_SILENCE_RATIO).min(1.0),
            recording_start: None,
            silence_start: None,
            has_speech: false,
            fired: false,
        }
    }

    pub fn start(&mut self) {
        self.start_at(Instant::now());
    }

    pub fn start_at(&mut self, now: Instant) {
        self.recording_start = Some(now);
        self.silence_start = None;
        self.has_speech = false;
        self.fired = false;
    }

    /// 回 true 表示靜音已達 timeout（只觸發一次）
    pub fn update(&mut self, level: f32) -> bool {
        self.update_at(level, Instant::now())
    }

    pub fn update_at(&mut self, level: f32, now: Instant) -> bool {
        let Some(rec_start) = self.recording_start else {
            return false;
        };
        if level >= self.speech_threshold {
            self.mark_speech();
            return false;
        }
        if level >= self.silence_threshold || self.fired {
            return false;
        }
        let due = if self.has_speech {
            let start = *self.silence_start.get_or_insert(now);
            now.saturating_duration_since(start) >= self.timeout
        } else {
            now.saturating_duration_since(rec_start) >= NO_SPEECH_TIMEOUT
        };
        if due {
            self.fired = true;
        }
        due
    }

    pub fn mark_speech(&mut self) {
        self.has_speech = true;
        self.silence_start = None;
        self.fired = false;
    }

    pub fn has_detected_speech(&self) -> bool {
        self.has_speech
    }

    pub fn reset(&mut self) {
        self.recording_start = None;
        self.silence_start = None;
        self.has_speech = false;
        self.fired = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(n: u64) -> Duration {
        Duration::from_millis(n)
    }

    #[test]
    fn fires_once_after_speech_then_silence() {
        let t0 = Instant::now();
        let mut d = SilenceDetector::new(2.0, 0.08);
        assert!(!d.update_at(0.0, t0)); // 尚未 start
        d.start_at(t0);
        assert!(!d.update_at(0.5, t0 + ms(100)));
        assert!(!d.update_at(0.01, t0 + ms(200)));
        assert!(!d.update_at(0.01, t0 + ms(2100)));
        assert!(d.update_at(0.01, t0 + ms(2200)));
        assert!(!d.update_at(0.01, t0 + ms(3000)), "只觸發一次");
        // 再講話會重新武裝
        assert!(!d.update_at(0.3, t0 + ms(3100)));
        assert!(!d.update_at(0.0, t0 + ms(3200)));
        assert!(d.update_at(0.0, t0 + ms(5300)));
    }

    #[test]
    fn mid_level_neither_resets_nor_counts() {
        let t0 = Instant::now();
        let mut d = SilenceDetector::new(1.0, 0.08);
        d.start_at(t0);
        d.update_at(0.5, t0);
        assert!(!d.update_at(0.0, t0 + ms(100))); // 靜音開始
        assert!(!d.update_at(0.1, t0 + ms(600))); // 0.08..0.15：不影響
        assert!(d.update_at(0.0, t0 + ms(1150)));
    }

    #[test]
    fn no_speech_timeout_and_mark_speech() {
        let t0 = Instant::now();
        let mut d = SilenceDetector::new(2.0, 0.08);
        d.start_at(t0);
        assert!(!d.update_at(0.0, t0 + ms(2900)));
        assert!(d.update_at(0.0, t0 + ms(3000)));

        d.start_at(t0);
        d.mark_speech(); // VAD 說有人講話
        assert!(d.has_detected_speech());
        assert!(!d.update_at(0.0, t0 + ms(3000)));
        assert!(d.update_at(0.0, t0 + ms(5000)));
        d.reset();
        assert!(!d.update_at(0.0, t0 + ms(9000)));
    }
}

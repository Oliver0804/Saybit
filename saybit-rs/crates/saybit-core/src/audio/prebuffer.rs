/// 固定長度環形緩衝（以時間計，預設 1.5 秒 @16k）。建構時一次配置，`write` 不配置記憶體。
pub struct PreBufferRing {
    buf: Vec<f32>,
    /// 下一個寫入位置
    pos: usize,
    /// 已寫入的有效樣本數（≤ 容量）
    filled: usize,
}

/// 原生版 PreBufferRing.replayDuration
pub const REPLAY_SECONDS: f32 = 1.5;

impl PreBufferRing {
    pub fn new(seconds: f32, sample_rate: u32) -> Self {
        let cap = ((seconds.max(0.0) * sample_rate as f32).round() as usize).max(1);
        Self { buf: vec![0.0; cap], pos: 0, filled: 0 }
    }

    pub fn capacity(&self) -> usize {
        self.buf.len()
    }

    pub fn len(&self) -> usize {
        self.filled
    }

    pub fn is_empty(&self) -> bool {
        self.filled == 0
    }

    pub fn write(&mut self, samples: &[f32]) {
        let cap = self.buf.len();
        // 超過容量只保留最後 cap 個
        let src = &samples[samples.len().saturating_sub(cap)..];
        let first = (cap - self.pos).min(src.len());
        self.buf[self.pos..self.pos + first].copy_from_slice(&src[..first]);
        let rest = src.len() - first;
        if rest > 0 {
            self.buf[..rest].copy_from_slice(&src[first..]);
        }
        self.pos = (self.pos + src.len()) % cap;
        self.filled = (self.filled + src.len()).min(cap);
    }

    /// 最舊 → 最新的拷貝
    pub fn snapshot(&self) -> Vec<f32> {
        let cap = self.buf.len();
        let start = (self.pos + cap - self.filled) % cap;
        let mut out = Vec::with_capacity(self.filled);
        if start + self.filled <= cap {
            out.extend_from_slice(&self.buf[start..start + self.filled]);
        } else {
            out.extend_from_slice(&self.buf[start..]);
            out.extend_from_slice(&self.buf[..self.filled - (cap - start)]);
        }
        out
    }

    pub fn clear(&mut self) {
        self.pos = 0;
        self.filled = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_last_n_samples_in_order() {
        let mut r = PreBufferRing::new(1.0, 5);
        assert_eq!(r.capacity(), 5);
        assert!(r.snapshot().is_empty());
        r.write(&[1.0, 2.0]);
        assert_eq!(r.snapshot(), vec![1.0, 2.0]);
        r.write(&[3.0, 4.0, 5.0, 6.0]);
        assert_eq!(r.snapshot(), vec![2.0, 3.0, 4.0, 5.0, 6.0]);
        r.write(&[7.0]);
        assert_eq!(r.snapshot(), vec![3.0, 4.0, 5.0, 6.0, 7.0]);
        // 一次寫入超過容量
        r.write(&[10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0]);
        assert_eq!(r.snapshot(), vec![12.0, 13.0, 14.0, 15.0, 16.0]);
        r.clear();
        assert!(r.is_empty());
        r.write(&[9.0]);
        assert_eq!(r.snapshot(), vec![9.0]);
    }

    #[test]
    fn default_replay_is_1_5_seconds_at_16k() {
        let mut r = PreBufferRing::new(REPLAY_SECONDS, 16_000);
        assert_eq!(r.capacity(), 24_000);
        for i in 0..40 {
            r.write(&vec![i as f32; 1600]);
        }
        let s = r.snapshot();
        assert_eq!(s.len(), 24_000);
        assert_eq!(s[0], 25.0);
        assert_eq!(*s.last().unwrap(), 39.0);
    }
}

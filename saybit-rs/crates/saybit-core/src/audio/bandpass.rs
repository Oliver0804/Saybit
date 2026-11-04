//! 人聲帶通：high-pass 80 Hz → low-pass 8 kHz 兩階 biquad 串聯（移植 VoiceBandpassFilter.swift）。
//! 係數依 RBJ Audio EQ Cookbook，Butterworth Q = 1/√2，Direct Form II Transposed。

const BUTTERWORTH_Q: f32 = std::f32::consts::FRAC_1_SQRT_2;
pub const HIGH_PASS_HZ: f32 = 80.0;
pub const LOW_PASS_HZ: f32 = 8000.0;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Biquad {
    pub b0: f32,
    pub b1: f32,
    pub b2: f32,
    pub a1: f32,
    pub a2: f32,
    z1: f32,
    z2: f32,
}

impl Biquad {
    pub fn high_pass(cutoff: f32, sample_rate: f32) -> Self {
        let (cw, alpha) = Self::omega(cutoff, sample_rate);
        let a0 = 1.0 + alpha;
        Self::from_coeffs(
            (1.0 + cw) / 2.0 / a0,
            -(1.0 + cw) / a0,
            (1.0 + cw) / 2.0 / a0,
            -2.0 * cw / a0,
            (1.0 - alpha) / a0,
        )
    }

    pub fn low_pass(cutoff: f32, sample_rate: f32) -> Self {
        let (cw, alpha) = Self::omega(cutoff, sample_rate);
        let a0 = 1.0 + alpha;
        Self::from_coeffs(
            (1.0 - cw) / 2.0 / a0,
            (1.0 - cw) / a0,
            (1.0 - cw) / 2.0 / a0,
            -2.0 * cw / a0,
            (1.0 - alpha) / a0,
        )
    }

    fn omega(cutoff: f32, sample_rate: f32) -> (f32, f32) {
        let w0 = 2.0 * std::f32::consts::PI * cutoff / sample_rate;
        (w0.cos(), w0.sin() / (2.0 * BUTTERWORTH_Q))
    }

    fn from_coeffs(b0: f32, b1: f32, b2: f32, a1: f32, a2: f32) -> Self {
        Self { b0, b1, b2, a1, a2, z1: 0.0, z2: 0.0 }
    }

    #[inline(always)]
    pub fn process(&mut self, x: f32) -> f32 {
        let y = self.b0 * x + self.z1;
        self.z1 = self.b1 * x - self.a1 * y + self.z2;
        self.z2 = self.b2 * x - self.a2 * y;
        y
    }

    pub fn reset(&mut self) {
        self.z1 = 0.0;
        self.z2 = 0.0;
    }
}

/// 80Hz–8kHz Butterworth biquad（移植 VoiceBandpassFilter.swift）。單聲道，處理 16 kHz 時 low-pass 依 Nyquist 降到 7.2 kHz。
pub struct Bandpass {
    hp: Biquad,
    lp: Biquad,
}

impl Bandpass {
    pub fn new(sample_rate: f32) -> Self {
        // Nyquist guard：lowPass 不超過 sampleRate × 0.45（同原生版）
        let lp_cutoff = LOW_PASS_HZ.min(sample_rate * 0.45);
        Self {
            hp: Biquad::high_pass(HIGH_PASS_HZ, sample_rate),
            lp: Biquad::low_pass(lp_cutoff, sample_rate),
        }
    }

    pub fn process(&mut self, samples: &mut [f32]) {
        for s in samples.iter_mut() {
            *s = self.lp.process(self.hp.process(*s));
        }
    }

    pub fn reset(&mut self) {
        self.hp.reset();
        self.lp.reset();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine(rate: f32, freq: f32, n: usize) -> Vec<f32> {
        (0..n)
            .map(|i| (2.0 * std::f32::consts::PI * freq * i as f32 / rate).sin() * 0.5)
            .collect()
    }

    fn rms(x: &[f32]) -> f32 {
        (x.iter().map(|v| v * v).sum::<f32>() / x.len() as f32).sqrt()
    }

    #[test]
    fn coefficients_match_rbj_cookbook() {
        // fs=48k, fc=80 Hz：手算 RBJ 值
        let hp = Biquad::high_pass(80.0, 48_000.0);
        let w0 = 2.0 * std::f32::consts::PI * 80.0 / 48_000.0;
        let alpha = w0.sin() / (2.0 * BUTTERWORTH_Q);
        let a0 = 1.0 + alpha;
        assert!((hp.b0 - (1.0 + w0.cos()) / 2.0 / a0).abs() < 1e-7);
        assert!((hp.a2 - (1.0 - alpha) / a0).abs() < 1e-7);
        // high-pass 的 b0 + b1 + b2 = 0（DC 增益 0）；low-pass 在 DC 增益 = 1
        assert!((hp.b0 + hp.b1 + hp.b2).abs() < 1e-6);
        let lp = Biquad::low_pass(8000.0, 48_000.0);
        let dc = (lp.b0 + lp.b1 + lp.b2) / (1.0 + lp.a1 + lp.a2);
        assert!((dc - 1.0).abs() < 1e-5);
    }

    #[test]
    fn passes_voice_band_and_cuts_hum() {
        let rate = 16_000.0;
        let mut f = Bandpass::new(rate);
        let mut voice = sine(rate, 1000.0, 16_000);
        f.process(&mut voice);
        assert!((rms(&voice[4000..]) - 0.5 / 2f32.sqrt()).abs() < 0.02);

        let mut f = Bandpass::new(rate);
        let mut hum = sine(rate, 30.0, 16_000);
        f.process(&mut hum);
        assert!(rms(&hum[8000..]) < 0.06, "hum rms {}", rms(&hum[8000..]));
    }

    #[test]
    fn low_pass_respects_nyquist_guard() {
        let f = Bandpass::new(16_000.0);
        let expected = Biquad::low_pass(7200.0, 16_000.0);
        assert_eq!(f.lp.b0, expected.b0);
    }
}

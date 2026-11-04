//! 任意取樣率／聲道 → 16 kHz 單聲道。先平均下混，再用 rubato 的 FFT 同步重取樣器。
//! 串流式：輸入攢到重取樣器要的 chunk 才處理，剩下的留到下一次，所以分塊送沒有接縫；
//! 重取樣器的起始延遲直接裁掉，輸出與輸入時間對齊。

use rubato::audioadapter_buffers::direct::InterleavedSlice;
use rubato::{Fft, FixedSync, Indexing, Resampler as _};

pub const TARGET_RATE: u32 = 16_000;
const CHUNK_FRAMES: usize = 1024;

/// 任意取樣率／聲道 → 16 kHz 單聲道（串流式，無接縫）
pub struct Resampler {
    channels: usize,
    /// None = 輸入已是 16 kHz，直接通過
    inner: Option<Fft<f32>>,
    ratio: f64,
    pending: Vec<f32>,
    scratch_in: Vec<f32>,
    scratch_out: Vec<f32>,
    /// 還要丟掉幾個起始延遲樣本
    skip: usize,
    total_in: u64,
    total_out: u64,
}

impl Resampler {
    pub fn new(in_rate: u32, channels: u16) -> anyhow::Result<Self> {
        if in_rate == 0 {
            anyhow::bail!("取樣率不能是 0");
        }
        let channels = channels.max(1) as usize;
        let inner = if in_rate == TARGET_RATE {
            None
        } else {
            Some(
                Fft::<f32>::new(in_rate as usize, TARGET_RATE as usize, CHUNK_FRAMES, 1, FixedSync::Input)
                    .map_err(|e| anyhow::anyhow!("建立重取樣器失敗（{in_rate} Hz）：{e}"))?,
            )
        };
        let (skip, out_max, in_max) = inner
            .as_ref()
            .map(|r| (r.output_delay(), r.output_frames_max(), r.input_frames_max()))
            .unwrap_or((0, 0, 0));
        Ok(Self {
            channels,
            inner,
            ratio: TARGET_RATE as f64 / in_rate as f64,
            pending: Vec::with_capacity(in_max * 2),
            scratch_in: vec![0.0; in_max],
            scratch_out: vec![0.0; out_max],
            skip,
            total_in: 0,
            total_out: 0,
        })
    }

    pub fn process(&mut self, interleaved: &[f32], out: &mut Vec<f32>) {
        downmix_into(interleaved, self.channels, &mut self.pending);
        let Some(inner) = self.inner.as_mut() else {
            out.extend_from_slice(&self.pending);
            self.pending.clear();
            return;
        };
        let mut consumed = 0;
        loop {
            let need = inner.input_frames_next();
            if self.pending.len() - consumed < need {
                break;
            }
            let input = &self.pending[consumed..consumed + need];
            match run_chunk(inner, input, None, &mut self.scratch_out) {
                Ok((nin, nout)) => {
                    consumed += nin.max(1);
                    self.total_in += nin as u64;
                    emit(&self.scratch_out[..nout], &mut self.skip, &mut self.total_out, out, u64::MAX);
                }
                Err(e) => {
                    log::warn!("重取樣失敗，丟棄 {need} 個樣本：{e}");
                    consumed += need;
                }
            }
        }
        self.pending.drain(..consumed);
    }

    /// 把尾端（不足一個 chunk 的輸入與重取樣器延遲）推出來，然後回到初始狀態
    pub fn flush(&mut self, out: &mut Vec<f32>) {
        let Some(inner) = self.inner.as_mut() else {
            out.extend_from_slice(&self.pending);
            self.pending.clear();
            return;
        };
        self.total_in += self.pending.len() as u64;
        let expected = (self.total_in as f64 * self.ratio).round() as u64;
        let mut guard = 0;
        while self.total_out < expected && guard < 64 {
            guard += 1;
            let need = inner.input_frames_next();
            let take = self.pending.len().min(need);
            self.scratch_in.resize(need.max(self.scratch_in.len()), 0.0);
            let buf = &mut self.scratch_in[..need];
            buf.fill(0.0);
            buf[..take].copy_from_slice(&self.pending[..take]);
            self.pending.drain(..take);
            let input = &self.scratch_in[..need];
            match run_chunk(inner, input, Some(take), &mut self.scratch_out) {
                Ok((_, nout)) => {
                    emit(&self.scratch_out[..nout], &mut self.skip, &mut self.total_out, out, expected);
                }
                Err(e) => {
                    log::warn!("重取樣 flush 失敗：{e}");
                    break;
                }
            }
        }
        inner.reset();
        self.skip = inner.output_delay();
        self.pending.clear();
        self.total_in = 0;
        self.total_out = 0;
    }
}

fn run_chunk(
    inner: &mut Fft<f32>,
    input: &[f32],
    partial: Option<usize>,
    scratch_out: &mut [f32],
) -> anyhow::Result<(usize, usize)> {
    let frames_in = input.len();
    let frames_out = scratch_out.len();
    let a_in = InterleavedSlice::new(input, 1, frames_in).map_err(|e| anyhow::anyhow!("{e}"))?;
    let mut a_out = InterleavedSlice::new_mut(scratch_out, 1, frames_out).map_err(|e| anyhow::anyhow!("{e}"))?;
    let indexing = partial.map(|n| Indexing { partial_len: Some(n), ..Default::default() });
    inner
        .process_into_buffer(&a_in, &mut a_out, indexing.as_ref())
        .map_err(|e| anyhow::anyhow!("{e}"))
}

/// 丟掉起始延遲後追加到 out，總輸出最多 `limit` 個
fn emit(chunk: &[f32], skip: &mut usize, total_out: &mut u64, out: &mut Vec<f32>, limit: u64) {
    let drop = (*skip).min(chunk.len());
    *skip -= drop;
    let rest = &chunk[drop..];
    let room = limit.saturating_sub(*total_out).min(rest.len() as u64) as usize;
    out.extend_from_slice(&rest[..room]);
    *total_out += room as u64;
}

/// 交錯多聲道 → 單聲道平均（追加到 dst；不足一個 frame 的尾巴丟掉）
pub fn downmix_into(interleaved: &[f32], channels: usize, dst: &mut Vec<f32>) {
    if channels <= 1 {
        dst.extend_from_slice(interleaved);
        return;
    }
    let scale = 1.0 / channels as f32;
    dst.extend(
        interleaved
            .chunks_exact(channels)
            .map(|frame| frame.iter().sum::<f32>() * scale),
    );
}

pub fn to_mono_16k_whole(interleaved: &[f32], in_rate: u32, channels: u16) -> Vec<f32> {
    let mut mono = Vec::with_capacity(interleaved.len() / channels.max(1) as usize);
    downmix_into(interleaved, channels.max(1) as usize, &mut mono);
    if in_rate == TARGET_RATE || mono.is_empty() || in_rate == 0 {
        return mono;
    }
    let n = mono.len();
    let result = Fft::<f32>::new(in_rate as usize, TARGET_RATE as usize, CHUNK_FRAMES, 1, FixedSync::Input)
        .map_err(|e| e.to_string())
        .and_then(|mut r| {
            let input = InterleavedSlice::new(&mono[..], 1, n).map_err(|e| e.to_string())?;
            r.process_all(&input, n, None).map_err(|e| e.to_string())
        });
    match result {
        Ok(buf) => buf.take_data(),
        Err(e) => {
            log::warn!("整段重取樣失敗（{in_rate} Hz）：{e}");
            Vec::new()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine(rate: u32, freq: f32, secs: f32, amp: f32) -> Vec<f32> {
        let n = (rate as f32 * secs) as usize;
        (0..n)
            .map(|i| amp * (2.0 * std::f32::consts::PI * freq * i as f32 / rate as f32).sin())
            .collect()
    }

    fn rms(x: &[f32]) -> f32 {
        (x.iter().map(|v| v * v).sum::<f32>() / x.len() as f32).sqrt()
    }

    #[test]
    fn streaming_48k_stereo_matches_length_and_level() {
        let mono = sine(48_000, 440.0, 1.0, 0.5);
        let stereo: Vec<f32> = mono.iter().flat_map(|v| [*v, *v]).collect();
        let mut r = Resampler::new(48_000, 2).unwrap();
        let mut out = Vec::new();
        // 480 frames（10 ms）一包，驗證串流接縫
        for chunk in stereo.chunks(960) {
            r.process(chunk, &mut out);
        }
        r.flush(&mut out);
        assert_eq!(out.len(), 16_000);
        let level = rms(&out[1000..15_000]);
        assert!((level - 0.5 / 2f32.sqrt()).abs() < 0.01, "rms {level}");
    }

    #[test]
    fn output_is_time_aligned() {
        // 一個脈衝在 0.5 秒：輸出峰值也該在 8000 附近（延遲已裁掉）
        let mut input = vec![0.0f32; 48_000];
        for v in &mut input[24_000..24_048] {
            *v = 1.0;
        }
        let mut r = Resampler::new(48_000, 1).unwrap();
        let mut out = Vec::new();
        r.process(&input, &mut out);
        r.flush(&mut out);
        let peak = out
            .iter()
            .enumerate()
            .max_by(|a, b| a.1.abs().total_cmp(&b.1.abs()))
            .unwrap()
            .0;
        assert!((peak as i64 - 8008).abs() <= 8, "peak at {peak}");
    }

    #[test]
    fn filters_above_output_nyquist() {
        let input = sine(48_000, 12_000.0, 1.0, 0.5);
        let out = to_mono_16k_whole(&input, 48_000, 1);
        assert!((out.len() as i64 - 16_000).abs() <= 1, "len {}", out.len());
        assert!(rms(&out[1000..15_000]) < 0.01);
    }

    #[test]
    fn odd_rates_and_passthrough() {
        let out = to_mono_16k_whole(&sine(44_100, 300.0, 1.0, 0.5), 44_100, 1);
        assert!((out.len() as i64 - 16_000).abs() <= 1, "len {}", out.len());
        let mut r = Resampler::new(16_000, 2).unwrap();
        let mut o = Vec::new();
        r.process(&[1.0, 0.0, 0.5, 0.5], &mut o);
        r.flush(&mut o);
        assert_eq!(o, vec![0.5, 0.5]);
        assert!(Resampler::new(0, 1).is_err());
    }

    #[test]
    fn flush_resets_for_reuse() {
        let mut r = Resampler::new(48_000, 1).unwrap();
        let mut out = Vec::new();
        r.process(&sine(48_000, 440.0, 0.3, 0.5), &mut out);
        r.flush(&mut out);
        assert_eq!(out.len(), 4800);
        out.clear();
        r.process(&sine(48_000, 440.0, 0.3, 0.5), &mut out);
        r.flush(&mut out);
        assert_eq!(out.len(), 4800);
    }
}

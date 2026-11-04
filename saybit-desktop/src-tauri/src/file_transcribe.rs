#![allow(dead_code)]
// 由 lib.rs 以 `mod file_transcribe;` 引入。
// 命令：transcribe_file_sensevoice / cancel_file_transcription
// 事件：file-transcribe-progress { progress }、file-transcribe-segment { start, end, text }
//
// 音檔 / 影片 → 逐字稿（SenseVoice + VAD 切句，附時間戳），移植自原生版
// ../speakertpyer/Core/SpeechRecognition/Sherpa/SherpaFileTranscriber.swift。
// 原生版用 AVAssetReader；這裡用 symphonia 解碼後自己下混 + 重取樣成 16 kHz 單聲道，
// 邊解邊送 VAD，長檔不會整段載入記憶體。recognizer / VAD 是這次轉錄專用的獨立實例，
// 不影響即時聽寫的常駐模型。

use crate::sherpa_stt::{self, ERR_CANCELLED, SAMPLE_RATE, VAD_WINDOW};
use serde::Serialize;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{Decoder, DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::{FormatOptions, FormatReader};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;
use tauri::{AppHandle, Emitter};

/// 每次開始 / 取消遞增；轉錄迴圈發現不符就中止（新的轉錄也會讓舊的停下）
static FILE_GEN: AtomicU64 = AtomicU64::new(0);

#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Segment {
    pub start: f64,
    pub end: f64,
    pub text: String,
}

#[tauri::command]
pub async fn transcribe_file_sensevoice(
    app: AppHandle,
    path: String,
    language: String,
) -> Result<Vec<Segment>, String> {
    if !sherpa_stt::SUPPORTED {
        return Err(sherpa_stt::MSG_UNSUPPORTED.into());
    }
    let paths = sherpa_stt::model_paths(&app)?;
    let language = sherpa_stt::normalize_language(&language);
    let gen = FILE_GEN.fetch_add(1, Ordering::SeqCst) + 1;
    tauri::async_runtime::spawn_blocking(move || {
        run(&app, Path::new(&path), &paths, &language, gen)
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
pub fn cancel_file_transcription() {
    FILE_GEN.fetch_add(1, Ordering::SeqCst);
}

fn run(
    app: &AppHandle,
    path: &Path,
    paths: &sherpa_stt::ModelPaths,
    language: &str,
    gen: u64,
) -> Result<Vec<Segment>, String> {
    let segments = transcribe_path(
        path,
        paths,
        language,
        &|| FILE_GEN.load(Ordering::SeqCst) != gen,
        &mut |s| {
            let _ = app.emit("file-transcribe-segment", s);
        },
        &mut |p| {
            let _ = app.emit(
                "file-transcribe-progress",
                serde_json::json!({ "progress": p }),
            );
        },
    )?;
    let _ = app.emit(
        "file-transcribe-progress",
        serde_json::json!({ "progress": 1.0 }),
    );
    Ok(segments)
}

/// 解碼 → VAD 切句 → SenseVoice；進度回呼已做節流（每 0.5% 或 250 ms）
pub fn transcribe_path(
    path: &Path,
    paths: &sherpa_stt::ModelPaths,
    language: &str,
    cancelled: &dyn Fn() -> bool,
    on_segment: &mut dyn FnMut(&Segment),
    on_progress: &mut dyn FnMut(f64),
) -> Result<Vec<Segment>, String> {
    // 先開檔：格式錯誤不用等模型載入（~1 秒）
    let mut audio = AudioDecoder::open(path)?;
    let mut recognizer = sherpa_stt::new_recognizer(paths, language, 4)?;
    let mut vad = sherpa_stt::new_vad(paths, 0.6, 25.0)?;
    if cancelled() {
        return Err(ERR_CANCELLED.into());
    }

    let duration = audio.duration_secs();
    let rate = SAMPLE_RATE as f64;
    let mut pending: Vec<f32> = Vec::new();
    let mut fed = 0usize;
    let mut segments: Vec<Segment> = Vec::new();
    let mut last_progress = 0.0f64;
    let mut last_emit = Instant::now();

    let mut drain =
        |vad: &mut dyn sherpa_stt::SpeechVad, segments: &mut Vec<Segment>| -> Result<(), String> {
            for seg in vad.pop_segments() {
                if cancelled() {
                    return Err(ERR_CANCELLED.into());
                }
                let text = recognizer.decode(&seg.samples);
                if text.is_empty() {
                    continue;
                }
                let s = Segment {
                    start: seg.start as f64 / rate,
                    end: (seg.start + seg.samples.len()) as f64 / rate,
                    text,
                };
                if cancelled() {
                    return Err(ERR_CANCELLED.into());
                }
                on_segment(&s);
                segments.push(s);
            }
            Ok(())
        };

    loop {
        if cancelled() {
            return Err(ERR_CANCELLED.into());
        }
        let more = audio.next_chunk(&mut pending)?;
        let whole = pending.len() / VAD_WINDOW * VAD_WINDOW;
        if whole > 0 {
            vad.accept(&pending[..whole]);
            pending.drain(..whole);
            fed += whole;
        }
        drain(vad.as_mut(), &mut segments)?;
        if let Some(p) = progress(fed, duration) {
            if p - last_progress >= 0.005 || last_emit.elapsed() >= Duration::from_millis(250) {
                on_progress(p);
                last_progress = p;
                last_emit = Instant::now();
            }
        }
        if !more {
            break;
        }
    }

    if !pending.is_empty() {
        vad.accept(&pending);
    }
    vad.flush();
    drain(vad.as_mut(), &mut segments)?;
    Ok(segments)
}

/// 已送進 VAD 的秒數 / 總長，完成前最多 0.99；不知道總長就不回報
pub fn progress(fed_samples: usize, duration_secs: Option<f64>) -> Option<f64> {
    let d = duration_secs.filter(|d| *d > 0.0)?;
    Some((fed_samples as f64 / SAMPLE_RATE as f64 / d).clamp(0.0, 0.99))
}

// MARK: - 解碼（symphonia → 16 kHz mono f32）

pub struct AudioDecoder {
    format: Box<dyn FormatReader>,
    decoder: Box<dyn Decoder>,
    track_id: u32,
    duration: Option<f64>,
    resampler: Option<Resampler>,
    sample_buf: Option<SampleBuffer<f32>>,
    mono: Vec<f32>,
    finished: bool,
}

impl AudioDecoder {
    pub fn open(path: &Path) -> Result<Self, String> {
        let file = std::fs::File::open(path).map_err(|e| format!("讀取音訊失敗：{e}"))?;
        let mss = MediaSourceStream::new(Box::new(file), Default::default());
        let mut hint = Hint::new();
        if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
            hint.with_extension(ext);
        }
        let probed = symphonia::default::get_probe()
            .format(
                &hint,
                mss,
                &FormatOptions::default(),
                &MetadataOptions::default(),
            )
            .map_err(|e| format!("不支援的音訊格式：{e}"))?;
        let format = probed.format;

        // 影片檔會有視訊軌：挑第一條建得出 decoder 的音訊軌
        let codecs = symphonia::default::get_codecs();
        let mut chosen = None;
        for track in format.tracks() {
            if track.codec_params.codec == CODEC_TYPE_NULL {
                continue;
            }
            if let Ok(decoder) = codecs.make(&track.codec_params, &DecoderOptions::default()) {
                let params = &track.codec_params;
                let duration = match (params.n_frames, params.time_base, params.sample_rate) {
                    (Some(n), Some(tb), _) => {
                        let t = tb.calc_time(n);
                        Some(t.seconds as f64 + t.frac)
                    }
                    (Some(n), None, Some(sr)) if sr > 0 => Some(n as f64 / sr as f64),
                    _ => None,
                };
                chosen = Some((track.id, decoder, duration));
                break;
            }
        }
        let (track_id, decoder, duration) = chosen.ok_or("這個檔案沒有可辨識的音訊軌")?;
        Ok(Self {
            format,
            decoder,
            track_id,
            duration,
            resampler: None,
            sample_buf: None,
            mono: Vec::new(),
            finished: false,
        })
    }

    pub fn duration_secs(&self) -> Option<f64> {
        self.duration
    }

    /// 解下一個 packet，把 16 kHz mono 樣本追加到 `out`；回傳 false 表示已讀完（重取樣尾端也已補出）
    pub fn next_chunk(&mut self, out: &mut Vec<f32>) -> Result<bool, String> {
        if self.finished {
            return Ok(false);
        }
        loop {
            let packet = match self.format.next_packet() {
                Ok(p) => p,
                Err(SymphoniaError::IoError(e))
                    if e.kind() == std::io::ErrorKind::UnexpectedEof =>
                {
                    return Ok(self.finish(out));
                }
                // 串流參數中途改變（鏈接的 ogg 等）：檔案轉錄不處理，當作結束
                Err(SymphoniaError::ResetRequired) => return Ok(self.finish(out)),
                Err(e) => return Err(format!("讀取音訊失敗：{e}")),
            };
            if packet.track_id() != self.track_id {
                continue;
            }
            let decoded = match self.decoder.decode(&packet) {
                Ok(d) => d,
                // 壞掉的單一 packet 跳過即可
                Err(SymphoniaError::DecodeError(_)) => continue,
                Err(SymphoniaError::IoError(_)) => continue,
                Err(e) => return Err(format!("解碼音訊失敗：{e}")),
            };
            let spec = *decoded.spec();
            let channels = spec.channels.count().max(1);
            let frames = decoded.frames();
            if frames == 0 {
                continue;
            }
            let need_new = self
                .sample_buf
                .as_ref()
                .is_none_or(|b| b.capacity() < decoded.capacity() * channels);
            if need_new {
                self.sample_buf = Some(SampleBuffer::<f32>::new(decoded.capacity() as u64, spec));
            }
            let buf = self.sample_buf.as_mut().expect("sample buffer");
            buf.copy_interleaved_ref(decoded);
            downmix(buf.samples(), channels, &mut self.mono);

            if self.resampler.as_ref().map(|r| r.from_rate) != Some(spec.rate) {
                if let Some(old) = self.resampler.as_mut() {
                    old.flush(out);
                }
                self.resampler = Some(Resampler::new(spec.rate, SAMPLE_RATE as u32));
            }
            self.resampler
                .as_mut()
                .expect("resampler")
                .process(&self.mono, out);
            return Ok(true);
        }
    }

    fn finish(&mut self, out: &mut Vec<f32>) -> bool {
        if let Some(r) = self.resampler.as_mut() {
            r.flush(out);
        }
        self.finished = true;
        false
    }
}

/// 交錯多聲道 → 單聲道平均
pub fn downmix(interleaved: &[f32], channels: usize, mono: &mut Vec<f32>) {
    mono.clear();
    if channels <= 1 {
        mono.extend_from_slice(interleaved);
        return;
    }
    let scale = 1.0 / channels as f32;
    mono.extend(
        interleaved
            .chunks_exact(channels)
            .map(|frame| frame.iter().sum::<f32>() * scale),
    );
}

// MARK: - 串流重取樣（Blackman 窗 sinc，查表）

const KERNEL_PHASES: usize = 512;

pub struct Resampler {
    pub from_rate: u32,
    to_rate: u32,
    /// 每個輸出樣本前進多少輸入樣本
    step: f64,
    /// 下一個輸出樣本在 `buf` 中的位置（輸入樣本單位）
    pos: f64,
    half: usize,
    table: Vec<f32>,
    buf: Vec<f32>,
}

impl Resampler {
    pub fn new(from_rate: u32, to_rate: u32) -> Self {
        let from = from_rate.max(1);
        let ratio = to_rate as f64 / from as f64;
        // 降取樣時截止頻率跟著輸出 Nyquist 走，留 5% 過渡帶
        let cutoff = ratio.min(1.0) * 0.95;
        let half = (12.0 / cutoff).ceil() as usize;
        let table = (0..=half * KERNEL_PHASES)
            .map(|i| {
                let x = i as f64 / KERNEL_PHASES as f64;
                let t = x / half as f64;
                let window = 0.42
                    + 0.5 * (std::f64::consts::PI * t).cos()
                    + 0.08 * (2.0 * std::f64::consts::PI * t).cos();
                let y = cutoff * x;
                let sinc = if y.abs() < 1e-12 {
                    1.0
                } else {
                    (std::f64::consts::PI * y).sin() / (std::f64::consts::PI * y)
                };
                (cutoff * sinc * window) as f32
            })
            .collect();
        Self {
            from_rate,
            to_rate,
            step: from as f64 / to_rate as f64,
            pos: 0.0,
            half,
            table,
            buf: Vec::new(),
        }
    }

    fn passthrough(&self) -> bool {
        self.from_rate == self.to_rate
    }

    pub fn process(&mut self, input: &[f32], out: &mut Vec<f32>) {
        if self.passthrough() {
            out.extend_from_slice(input);
            return;
        }
        self.buf.extend_from_slice(input);
        self.run(out);
    }

    /// 補 `half` 個零把最後的樣本推出來
    pub fn flush(&mut self, out: &mut Vec<f32>) {
        if self.passthrough() {
            return;
        }
        let end = self.buf.len() as f64;
        self.buf.extend(std::iter::repeat_n(0.0, self.half + 1));
        while self.pos < end {
            match self.sample_at(self.pos) {
                Some(v) => out.push(v),
                None => break,
            }
            self.pos += self.step;
        }
        self.buf.clear();
        self.pos = 0.0;
    }

    fn run(&mut self, out: &mut Vec<f32>) {
        while let Some(v) = self.sample_at(self.pos) {
            out.push(v);
            self.pos += self.step;
        }
        // 丟掉已經用不到的前段，保留左側 half 個樣本當濾波器歷史
        let keep_from = (self.pos.floor() as usize).saturating_sub(self.half);
        if keep_from > 0 {
            self.buf.drain(..keep_from.min(self.buf.len()));
            self.pos -= keep_from as f64;
        }
    }

    /// 需要的右側樣本還沒到就回 None
    fn sample_at(&self, center: f64) -> Option<f32> {
        let i0 = center.floor() as isize;
        let half = self.half as isize;
        if i0 + half >= self.buf.len() as isize {
            return None;
        }
        let mut acc = 0.0f32;
        let mut wsum = 0.0f32;
        for j in (i0 - half + 1).max(0)..=(i0 + half) {
            let x = (center - j as f64).abs();
            let idx = (x * KERNEL_PHASES as f64).round() as usize;
            if let Some(&w) = self.table.get(idx) {
                acc += self.buf[j as usize] * w;
                wsum += w;
            }
        }
        Some(if wsum.abs() > 1e-6 { acc / wsum } else { 0.0 })
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
    fn resample_48k_to_16k_keeps_length_and_level() {
        let input = sine(48_000, 440.0, 1.0, 0.5);
        let mut r = Resampler::new(48_000, 16_000);
        let mut out = Vec::new();
        // 分小塊送，驗證串流接縫
        for chunk in input.chunks(1000) {
            r.process(chunk, &mut out);
        }
        r.flush(&mut out);
        assert!((out.len() as i64 - 16_000).abs() <= 2, "len {}", out.len());
        let level = rms(&out[1000..15_000]);
        assert!((level - 0.5 / 2f32.sqrt()).abs() < 0.01, "rms {level}");
    }

    #[test]
    fn resample_filters_above_output_nyquist() {
        // 12 kHz 在 16 kHz 輸出下會混疊，應被濾掉
        let input = sine(48_000, 12_000.0, 1.0, 0.5);
        let mut r = Resampler::new(48_000, 16_000);
        let mut out = Vec::new();
        r.process(&input, &mut out);
        r.flush(&mut out);
        assert!(rms(&out[1000..15_000]) < 0.01);
    }

    #[test]
    fn resample_upsample_and_passthrough() {
        let mut up = Resampler::new(8_000, 16_000);
        let mut out = Vec::new();
        up.process(&sine(8_000, 300.0, 0.5, 0.5), &mut out);
        up.flush(&mut out);
        assert!((out.len() as i64 - 8_000).abs() <= 2, "len {}", out.len());

        let mut same = Resampler::new(16_000, 16_000);
        let mut out2 = Vec::new();
        same.process(&[0.1, 0.2], &mut out2);
        same.flush(&mut out2);
        assert_eq!(out2, vec![0.1, 0.2]);
    }

    #[test]
    fn downmix_averages_channels() {
        let mut mono = Vec::new();
        downmix(&[1.0, 0.0, 0.5, 0.5], 2, &mut mono);
        assert_eq!(mono, vec![0.5, 0.5]);
    }

    #[test]
    fn progress_needs_duration() {
        assert_eq!(progress(16_000, None), None);
        assert_eq!(progress(16_000, Some(0.0)), None);
        assert_eq!(progress(16_000, Some(2.0)), Some(0.5));
        assert_eq!(progress(16_000 * 10, Some(2.0)), Some(0.99));
    }

    /// 44.1 kHz 立體聲 16-bit WAV → 16 kHz mono
    #[test]
    fn decodes_wav_to_16k_mono() {
        let rate = 44_100u32;
        let frames = rate as usize; // 1 秒
        let mut data = Vec::with_capacity(frames * 4);
        for i in 0..frames {
            let v = (0.3
                * (2.0 * std::f32::consts::PI * 440.0 * i as f32 / rate as f32).sin()
                * i16::MAX as f32) as i16;
            data.extend_from_slice(&v.to_le_bytes());
            data.extend_from_slice(&v.to_le_bytes());
        }
        let mut wav = Vec::new();
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&(36 + data.len() as u32).to_le_bytes());
        wav.extend_from_slice(b"WAVEfmt ");
        wav.extend_from_slice(&16u32.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes()); // PCM
        wav.extend_from_slice(&2u16.to_le_bytes()); // stereo
        wav.extend_from_slice(&rate.to_le_bytes());
        wav.extend_from_slice(&(rate * 4).to_le_bytes());
        wav.extend_from_slice(&4u16.to_le_bytes());
        wav.extend_from_slice(&16u16.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&(data.len() as u32).to_le_bytes());
        wav.extend_from_slice(&data);

        let path = std::env::temp_dir().join(format!("saybit-ft-test-{}.wav", std::process::id()));
        std::fs::write(&path, &wav).unwrap();
        let mut dec = AudioDecoder::open(&path).unwrap();
        let d = dec.duration_secs().unwrap();
        assert!((d - 1.0).abs() < 1e-6, "duration {d}");
        let mut out = Vec::new();
        while dec.next_chunk(&mut out).unwrap() {}
        std::fs::remove_file(&path).ok();
        assert!((out.len() as i64 - 16_000).abs() <= 3, "len {}", out.len());
        let level = rms(&out[1000..15_000]);
        assert!((level - 0.3 / 2f32.sqrt()).abs() < 0.01, "rms {level}");
    }

    #[test]
    fn rejects_non_audio() {
        let path = std::env::temp_dir().join(format!("saybit-ft-bad-{}.txt", std::process::id()));
        std::fs::write(&path, b"not audio at all").unwrap();
        assert!(AudioDecoder::open(&path).is_err());
        std::fs::remove_file(&path).ok();
    }

    /// 用真模型跑完整流程（不啟動 App）：
    /// SAYBIT_SHERPA_DIR=<模型目錄> SAYBIT_TEST_AUDIO=<音檔> cargo test real_model -- --ignored --nocapture
    #[test]
    #[ignore]
    fn real_model_transcribes_file() {
        let (Ok(dir), Ok(audio)) = (
            std::env::var("SAYBIT_SHERPA_DIR"),
            std::env::var("SAYBIT_TEST_AUDIO"),
        ) else {
            return;
        };
        let paths = sherpa_stt::ModelPaths {
            model: Path::new(&dir).join("model.int8.onnx"),
            tokens: Path::new(&dir).join("tokens.txt"),
            vad: Path::new(&dir).join("silero_vad.onnx"),
        };
        let t = Instant::now();
        let mut progress_calls = 0;
        let segs = transcribe_path(
            Path::new(&audio),
            &paths,
            "auto",
            &|| false,
            &mut |s| println!("[{:.2}-{:.2}] {}", s.start, s.end, s.text),
            &mut |_| progress_calls += 1,
        )
        .unwrap();
        println!(
            "{} segments, {progress_calls} progress, {:?}",
            segs.len(),
            t.elapsed()
        );
        assert!(!segs.is_empty());
    }

    /// 即時路徑：音檔切 100 ms 一包餵 LiveSession（同 sensevoice_push 的 worker 邏輯）
    #[test]
    #[ignore]
    fn real_model_live_session() {
        let (Ok(dir), Ok(audio)) = (
            std::env::var("SAYBIT_SHERPA_DIR"),
            std::env::var("SAYBIT_TEST_AUDIO"),
        ) else {
            return;
        };
        let paths = sherpa_stt::ModelPaths {
            model: Path::new(&dir).join("model.int8.onnx"),
            tokens: Path::new(&dir).join("tokens.txt"),
            vad: Path::new(&dir).join("silero_vad.onnx"),
        };
        let mut dec = AudioDecoder::open(Path::new(&audio)).unwrap();
        let mut pcm = Vec::new();
        while dec.next_chunk(&mut pcm).unwrap() {}
        let mut recognizer = sherpa_stt::new_recognizer(&paths, "auto", 2).unwrap();
        let mut vad = sherpa_stt::new_vad(&paths, 0.5, 20.0).unwrap();
        let mut session = sherpa_stt::LiveSession::default();
        for chunk in pcm.chunks(1600) {
            session.push(chunk);
            if let Some(p) = session.process(
                recognizer.as_mut(),
                vad.as_mut(),
                false,
                true,
                Instant::now(),
            ) {
                println!("partial: {p}");
            }
        }
        let text = session.finish(recognizer.as_mut(), vad.as_mut());
        println!("final: {text}");
        assert!(!text.is_empty());
    }
}

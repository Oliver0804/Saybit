//! 檔案轉錄（批次 C1；移植 SherpaFileTranscriber.swift / file_transcribe.rs）：symphonia 解碼 → 16k mono → 獨立 SenseVoice + VAD（0.6 / 25）
//!
//! 邊解邊送 VAD，長檔不會整段載入記憶體。recognizer / VAD 是這次轉錄專用的獨立實例，在呼叫端執行緒上建立與使用，
//! 不碰即時聽寫 worker 的常駐模型。輸出簡體會轉台灣繁體，除非 `language` 傳 "zh-CN"。

use crate::audio::resample::Resampler;
use crate::models::ERR_CANCELLED;
use crate::stt::sherpa::{self, SAMPLE_RATE, VAD_WINDOW};
use crate::stt::traditionalize;
use crate::types::*;
use std::path::Path;
use std::time::{Duration, Instant};
use symphonia::core::codecs::audio::{AudioDecoder as SymDecoder, AudioDecoderOptions};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::{FormatOptions, FormatReader};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;

/// `language`："auto" | "zh" | "en" | "ja" | "ko" | "yue"（也接受 zh-TW 等地區碼；"zh-CN" = 中文但保留簡體）。
/// 取消回 `Err("cancelled")`。
pub fn transcribe_file(
    path: &std::path::Path,
    language: &str,
    on_segment: &mut dyn FnMut(&TranscriptSegment),
    on_progress: &mut dyn FnMut(f32),
    cancel: &CancelToken,
) -> anyhow::Result<Vec<TranscriptSegment>> {
    if !sherpa::SUPPORTED {
        anyhow::bail!(sherpa::MSG_UNSUPPORTED);
    }
    let paths = sherpa::installed_paths()?;
    let segments = transcribe_with_model(path, &paths, language, on_segment, on_progress, cancel)?;
    on_progress(1.0);
    Ok(segments)
}

/// 指定模型位置的版本（測試用 / 自訂模型目錄）
pub fn transcribe_with_model(
    path: &Path,
    paths: &sherpa::ModelPaths,
    language: &str,
    on_segment: &mut dyn FnMut(&TranscriptSegment),
    on_progress: &mut dyn FnMut(f32),
    cancel: &CancelToken,
) -> anyhow::Result<Vec<TranscriptSegment>> {
    let traditional = sherpa::wants_traditional(language);
    let language = sherpa::normalize_language(language);
    // 先開檔：格式錯誤不用等模型載入（~1 秒）
    let mut audio = AudioDecoder::open(path)?;
    let mut recognizer = sherpa::new_recognizer(paths, &language, 4)?;
    let mut vad = sherpa::new_vad(paths, 0.6, 25.0)?;
    let cancelled = || cancel.is_cancelled();
    if cancelled() {
        anyhow::bail!(ERR_CANCELLED);
    }

    let duration = audio.duration_secs();
    let rate = SAMPLE_RATE as f64;
    let mut pending: Vec<f32> = Vec::new();
    let mut fed = 0usize;
    let mut segments: Vec<TranscriptSegment> = Vec::new();
    let mut last_progress = 0.0f32;
    let mut last_emit = Instant::now();

    let mut drain = |vad: &mut dyn sherpa::SpeechVad, segments: &mut Vec<TranscriptSegment>| -> anyhow::Result<()> {
        for seg in vad.pop_segments() {
            if cancelled() {
                anyhow::bail!(ERR_CANCELLED);
            }
            let text = recognizer.decode(&seg.samples);
            if text.is_empty() {
                continue;
            }
            let text = if traditional { traditionalize::to_traditional(&text) } else { text };
            let s = TranscriptSegment {
                start: seg.start as f64 / rate,
                end: (seg.start + seg.samples.len()) as f64 / rate,
                text,
            };
            if cancelled() {
                anyhow::bail!(ERR_CANCELLED);
            }
            on_segment(&s);
            segments.push(s);
        }
        Ok(())
    };

    loop {
        if cancelled() {
            anyhow::bail!(ERR_CANCELLED);
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
pub fn progress(fed_samples: usize, duration_secs: Option<f64>) -> Option<f32> {
    let d = duration_secs.filter(|d| *d > 0.0)?;
    Some((fed_samples as f64 / SAMPLE_RATE as f64 / d).clamp(0.0, 0.99) as f32)
}

/// 秒數 → "mm:ss"，一小時以上 "h:mm:ss"
pub fn format_timestamp(secs: f64) -> String {
    let s = if secs.is_finite() { secs.max(0.0).floor() as u64 } else { 0 };
    if s >= 3600 {
        format!("{}:{:02}:{:02}", s / 3600, (s / 60) % 60, s % 60)
    } else {
        format!("{:02}:{:02}", s / 60, s % 60)
    }
}

/// 有時間戳：每段一行「[mm:ss] 文字」；沒有：直接接起來（對齊原生 plainText）
pub fn segments_to_text(segments: &[TranscriptSegment], with_timestamps: bool) -> String {
    if with_timestamps {
        segments
            .iter()
            .map(|s| format!("[{}] {}", format_timestamp(s.start), s.text))
            .collect::<Vec<_>>()
            .join("\n")
    } else {
        segments.iter().map(|s| s.text.as_str()).collect()
    }
}

/// 整個檔案解成 16 kHz mono（給測試 / 批次引擎用；長檔請用 `AudioDecoder` 串流）
pub fn decode_to_16k_mono(path: &Path) -> anyhow::Result<Vec<f32>> {
    let mut dec = AudioDecoder::open(path)?;
    let mut out = Vec::new();
    while dec.next_chunk(&mut out)? {}
    Ok(out)
}

// MARK: - 解碼（symphonia → 16 kHz mono f32）

pub struct AudioDecoder {
    format: Box<dyn FormatReader>,
    decoder: Box<dyn SymDecoder>,
    track_id: u32,
    duration: Option<f64>,
    resampler: Option<(u32, usize, Resampler)>,
    interleaved: Vec<f32>,
    /// 還要丟掉的開頭 frame 數（編碼器延遲）
    skip_frames: u64,
    /// 還能輸出的有效 frame 數（None = 不知道，全部輸出）
    remaining_frames: Option<u64>,
    finished: bool,
}

impl AudioDecoder {
    pub fn open(path: &Path) -> anyhow::Result<Self> {
        let file = std::fs::File::open(path).map_err(|e| anyhow::anyhow!("讀取音訊失敗：{e}"))?;
        let mss = MediaSourceStream::new(Box::new(file), Default::default());
        let mut hint = Hint::new();
        if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
            hint.with_extension(ext);
        }
        let format = symphonia::default::get_probe()
            .probe(&hint, mss, FormatOptions::default(), MetadataOptions::default())
            .map_err(|e| anyhow::anyhow!("不支援的音訊格式：{e}"))?;

        // 影片檔會有視訊軌：挑第一條建得出 decoder 的音訊軌
        let codecs = symphonia::default::get_codecs();
        let mut chosen = None;
        for track in format.tracks() {
            let Some(params) = track.codec_params.as_ref().and_then(|p| p.audio()) else {
                continue;
            };
            if let Ok(decoder) = codecs.make_audio_decoder(params, &AudioDecoderOptions::default()) {
                let duration = match (track.duration, track.time_base) {
                    (Some(d), Some(tb)) => tb.calc_duration(d).map(|t| t.as_secs_f64()),
                    _ => None,
                }
                .or_else(|| match (track.num_frames, params.sample_rate) {
                    (Some(n), Some(sr)) if sr > 0 => Some(n as f64 / sr as f64),
                    _ => None,
                });
                // AAC / MP3 的編碼器延遲（priming）與尾端補零：解碼器不會自己裁，這裡裁掉，時間戳才對得上原始音訊
                let delay = track.delay.unwrap_or(0) as u64;
                let padding = track.padding.unwrap_or(0) as u64;
                // num_frames 已不含 delay / padding；兩者都不知道時不截尾（有些容器的 num_frames 不可靠）
                let valid = track.num_frames.filter(|n| *n > 0 && delay + padding > 0);
                let duration = match (valid, params.sample_rate) {
                    (Some(n), Some(sr)) if sr > 0 && delay + padding > 0 => Some(n as f64 / sr as f64),
                    _ => duration,
                };
                chosen = Some((track.id, decoder, duration, delay, valid));
                break;
            }
        }
        let (track_id, decoder, duration, skip_frames, remaining_frames) =
            chosen.ok_or_else(|| anyhow::anyhow!("這個檔案沒有可辨識的音訊軌"))?;
        Ok(Self {
            format,
            decoder,
            track_id,
            duration,
            resampler: None,
            interleaved: Vec::new(),
            skip_frames,
            remaining_frames,
            finished: false,
        })
    }

    pub fn duration_secs(&self) -> Option<f64> {
        self.duration
    }

    /// 解下一個 packet，把 16 kHz mono 樣本追加到 `out`；回傳 false 表示已讀完（重取樣尾端也已補出）
    pub fn next_chunk(&mut self, out: &mut Vec<f32>) -> anyhow::Result<bool> {
        if self.finished {
            return Ok(false);
        }
        loop {
            let packet = match self.format.next_packet() {
                Ok(Some(p)) => p,
                Ok(None) => return Ok(self.finish(out)),
                Err(SymphoniaError::IoError(e)) if e.kind() == std::io::ErrorKind::UnexpectedEof => {
                    return Ok(self.finish(out));
                }
                // 串流參數中途改變（鏈接的 ogg 等）：檔案轉錄不處理，當作結束
                Err(SymphoniaError::ResetRequired) => return Ok(self.finish(out)),
                Err(e) => anyhow::bail!("讀取音訊失敗：{e}"),
            };
            if packet.track_id != self.track_id {
                continue;
            }
            let decoded = match self.decoder.decode(&packet) {
                Ok(d) => d,
                // 壞掉的單一 packet 跳過即可
                Err(SymphoniaError::DecodeError(_)) | Err(SymphoniaError::IoError(_)) => continue,
                Err(e) => anyhow::bail!("解碼音訊失敗：{e}"),
            };
            if decoded.frames() == 0 {
                continue;
            }
            let rate = decoded.spec().rate();
            let channels = decoded.spec().channels().count().max(1);
            self.interleaved.resize(decoded.samples_interleaved(), 0.0);
            decoded.copy_to_slice_interleaved(&mut self.interleaved[..]);
            let frames = (self.interleaved.len() / channels) as u64;
            let skip = self.skip_frames.min(frames);
            self.skip_frames -= skip;
            let keep = match self.remaining_frames.as_mut() {
                Some(left) => {
                    let k = (frames - skip).min(*left);
                    *left -= k;
                    k
                }
                None => frames - skip,
            };
            let start = skip as usize * channels;
            self.interleaved.truncate(start + keep as usize * channels);
            self.interleaved.drain(..start);
            if self.interleaved.is_empty() {
                continue;
            }

            let same = self.resampler.as_ref().is_some_and(|(r, c, _)| *r == rate && *c == channels);
            if !same {
                if let Some((_, _, old)) = self.resampler.as_mut() {
                    old.flush(out);
                }
                self.resampler = Some((rate, channels, Resampler::new(rate, channels as u16)?));
            }
            let (_, _, r) = self.resampler.as_mut().expect("resampler");
            r.process(&self.interleaved, out);
            return Ok(true);
        }
    }

    fn finish(&mut self, out: &mut Vec<f32>) -> bool {
        if let Some((_, _, r)) = self.resampler.as_mut() {
            r.flush(out);
        }
        self.finished = true;
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rms(x: &[f32]) -> f32 {
        (x.iter().map(|v| v * v).sum::<f32>() / x.len() as f32).sqrt()
    }

    #[test]
    fn progress_needs_duration() {
        assert_eq!(progress(16_000, None), None);
        assert_eq!(progress(16_000, Some(0.0)), None);
        assert_eq!(progress(16_000, Some(2.0)), Some(0.5));
        assert_eq!(progress(16_000 * 10, Some(2.0)), Some(0.99));
    }

    #[test]
    fn timestamps_and_text() {
        assert_eq!(format_timestamp(0.0), "00:00");
        assert_eq!(format_timestamp(65.9), "01:05");
        assert_eq!(format_timestamp(3725.0), "1:02:05");
        assert_eq!(format_timestamp(-3.0), "00:00");
        assert_eq!(format_timestamp(f64::NAN), "00:00");
        let segs = vec![
            TranscriptSegment { start: 1.2, end: 2.0, text: "你好".into() },
            TranscriptSegment { start: 61.0, end: 62.0, text: "世界".into() },
        ];
        assert_eq!(segments_to_text(&segs, true), "[00:01] 你好\n[01:01] 世界");
        assert_eq!(segments_to_text(&segs, false), "你好世界");
        assert_eq!(segments_to_text(&[], true), "");
    }

    fn write_wav(path: &Path, rate: u32, frames: usize) {
        let mut data = Vec::with_capacity(frames * 4);
        for i in 0..frames {
            let v = (0.3 * (2.0 * std::f32::consts::PI * 440.0 * i as f32 / rate as f32).sin() * i16::MAX as f32) as i16;
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
        std::fs::write(path, &wav).unwrap();
    }

    /// 44.1 kHz 立體聲 16-bit WAV → 16 kHz mono
    #[test]
    fn decodes_wav_to_16k_mono() {
        let path = std::env::temp_dir().join(format!("saybit-ft-test-{}.wav", std::process::id()));
        write_wav(&path, 44_100, 44_100);
        let dec = AudioDecoder::open(&path).unwrap();
        let d = dec.duration_secs().unwrap();
        assert!((d - 1.0).abs() < 1e-6, "duration {d}");
        let out = decode_to_16k_mono(&path).unwrap();
        std::fs::remove_file(&path).ok();
        assert!((out.len() as i64 - 16_000).abs() <= 1, "len {}", out.len());
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
    /// SAYBIT_SHERPA_DIR=<模型目錄> SAYBIT_TEST_AUDIO=<音檔> cargo test -p saybit-core real_model -- --ignored --nocapture
    #[test]
    #[ignore]
    fn real_model_transcribes_file() {
        let (Ok(dir), Ok(audio)) = (std::env::var("SAYBIT_SHERPA_DIR"), std::env::var("SAYBIT_TEST_AUDIO")) else {
            eprintln!("略過：未設定 SAYBIT_SHERPA_DIR / SAYBIT_TEST_AUDIO");
            return;
        };
        let paths = sherpa::ModelPaths::in_dir(Path::new(&dir));
        let t = Instant::now();
        let mut progress_calls = 0;
        let segs = transcribe_with_model(
            Path::new(&audio),
            &paths,
            "auto",
            &mut |s| println!("[{:.2}-{:.2}] {}", s.start, s.end, s.text),
            &mut |_| progress_calls += 1,
            &CancelToken::new(),
        )
        .unwrap();
        println!("{} segments, {progress_calls} progress, {:?}", segs.len(), t.elapsed());
        assert!(!segs.is_empty());

        let cancel = CancelToken::new();
        cancel.cancel();
        let err = transcribe_with_model(Path::new(&audio), &paths, "auto", &mut |_| {}, &mut |_| {}, &cancel).unwrap_err();
        assert_eq!(err.to_string(), ERR_CANCELLED);
    }
}

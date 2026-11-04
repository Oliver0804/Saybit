//! 音訊擷取（批次 C1；移植 SharedAudioEngine / VoiceBandpassFilter / PreBufferRing / SilenceDetector / AudioLevelMonitor）。
//! cpal 擷取裝置原生格式 → 轉 16 kHz 單聲道 f32（rubato）→ 帶通 80Hz–8kHz（biquad Q=0.7071）→ 增益 → 寫 pre-buffer ring（1.5 秒）→ 丟給各 sink。
//! 擷取回呼內不配置記憶體；sink 在獨立執行緒呼叫（不是 cpal callback）。
//!
//! 執行緒模型：
//! - cpal callback：從預配置的 buffer pool 拿一塊、轉成 f32 memcpy 進去、丟進 channel。pool 用完就丟這包（記 overrun），
//!   送不出去就把 buffer 還回 pool —— callback 內不配置也不釋放記憶體。
//! - `audio-capture` 執行緒：建立並持有 cpal Stream（有些平台的 Stream 不是 Send），收 channel、
//!   重取樣 / 帶通 / 增益、算音量，攢滿 100 ms 一包後在 `inner` 鎖內寫 ring 並呼叫所有 sink。
//! - `add_sink(replay=true)` 在同一把鎖內先回放 ring 再註冊，所以每個樣本「不是已回放、就是之後即時送達」，不重複不遺漏。
//!   sink 在鎖內被呼叫，**sink 裡不能再呼叫 AudioEngine 的方法**（會死鎖）。
pub mod bandpass;
pub mod prebuffer;
pub mod resample;
pub mod silence;

use crate::types::*;
use bandpass::Bandpass;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, SizedSample};
use crossbeam_channel::{bounded, Receiver, RecvTimeoutError, Sender, TrySendError};
use parking_lot::Mutex;
use prebuffer::PreBufferRing;
use resample::{Resampler, TARGET_RATE};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

/// 送給 sink 的一包長度（100 ms @16k）
pub const PACKET_SAMPLES: usize = TARGET_RATE as usize / 10;
const POOL_BUFFERS: usize = 64;
/// 每塊 pool buffer 的容量（樣本數，含所有聲道）；超過的 callback 只保留前段
const POOL_BUFFER_CAPACITY: usize = 16_384;
/// 音量超過這麼久沒更新就視為 0（裝置停了 / 卡住）
const LEVEL_STALE: Duration = Duration::from_millis(300);
/// 原生 AudioUtils.normalizedLevel 的倍率
const LEVEL_MULTIPLIER: f32 = 5.0;

/// RMS → 0..1（同原生 AudioUtils.normalizedLevel，倍率 5）
pub fn normalized_level(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let sum: f32 = samples.iter().map(|v| v * v).sum();
    ((sum / samples.len() as f32).sqrt() * LEVEL_MULTIPLIER).clamp(0.0, 1.0)
}

struct SinkEntry {
    id: String,
    sink: AudioChunkSink,
}

struct Inner {
    ring: PreBufferRing,
    /// 尚未湊滿一包的 16 kHz 樣本
    packet: Vec<f32>,
    sinks: Vec<SinkEntry>,
}

impl Inner {
    /// 把已處理好的 16 kHz 樣本攢成 100 ms 一包送出
    fn push_processed(&mut self, samples: &[f32]) {
        let mut rest = samples;
        while !rest.is_empty() {
            let take = (PACKET_SAMPLES - self.packet.len()).min(rest.len());
            self.packet.extend_from_slice(&rest[..take]);
            rest = &rest[take..];
            if self.packet.len() >= PACKET_SAMPLES {
                self.ring.write(&self.packet);
                for entry in self.sinks.iter_mut() {
                    (entry.sink)(&self.packet);
                }
                self.packet.clear();
            }
        }
    }

    fn add_sink(&mut self, id: &str, mut sink: AudioChunkSink, replay: bool) {
        self.sinks.retain(|e| e.id != id);
        if replay {
            // ring 只存完整的包；尚未湊滿一包的尾巴之後會跟著那一包即時送達，不在這裡回放
            let past = self.ring.snapshot();
            for chunk in past.chunks(PACKET_SAMPLES) {
                sink(chunk);
            }
        }
        self.sinks.push(SinkEntry { id: id.to_string(), sink });
    }

    /// 移除前把還沒湊滿的尾巴交給它（停止錄音時最後 <100 ms 不會遺失）
    fn remove_sink(&mut self, id: &str) {
        if let Some(pos) = self.sinks.iter().position(|e| e.id == id) {
            let mut entry = self.sinks.remove(pos);
            if !self.packet.is_empty() {
                (entry.sink)(&self.packet);
            }
        }
    }
}

struct Shared {
    inner: Mutex<Inner>,
    running: AtomicBool,
    bandpass: AtomicBool,
    gain_bits: AtomicU32,
    level_bits: AtomicU32,
    /// 最後一次更新音量的時間（相對 epoch 的奈秒）
    level_at: AtomicU64,
    epoch: Instant,
    overruns: AtomicU64,
}

impl Shared {
    fn gain(&self) -> f32 {
        f32::from_bits(self.gain_bits.load(Ordering::Relaxed))
    }
    fn set_level(&self, level: f32) {
        self.level_bits.store(level.to_bits(), Ordering::Relaxed);
        self.level_at
            .store(self.epoch.elapsed().as_nanos() as u64, Ordering::Relaxed);
    }
}

struct Worker {
    stop: Arc<AtomicBool>,
    handle: JoinHandle<()>,
    device_id: Option<String>,
}

pub struct AudioEngine {
    shared: Arc<Shared>,
    worker: Mutex<Option<Worker>>,
}

impl AudioEngine {
    pub fn new() -> Self {
        Self {
            shared: Arc::new(Shared {
                inner: Mutex::new(Inner {
                    ring: PreBufferRing::new(prebuffer::REPLAY_SECONDS, TARGET_RATE),
                    packet: Vec::with_capacity(PACKET_SAMPLES),
                    sinks: Vec::new(),
                }),
                running: AtomicBool::new(false),
                bandpass: AtomicBool::new(true),
                gain_bits: AtomicU32::new(1.0f32.to_bits()),
                level_bits: AtomicU32::new(0),
                level_at: AtomicU64::new(0),
                epoch: Instant::now(),
                overruns: AtomicU64::new(0),
            }),
            worker: Mutex::new(None),
        }
    }

    pub fn list_input_devices() -> Vec<AudioDevice> {
        let host = cpal::default_host();
        let default_id = host
            .default_input_device()
            .and_then(|d| d.id().ok())
            .map(|id| id.to_string());
        let Ok(devices) = host.input_devices() else {
            return Vec::new();
        };
        devices
            .filter_map(|d| {
                let id = d.id().ok()?.to_string();
                let name = d
                    .description()
                    .map(|desc| desc.name().to_string())
                    .unwrap_or_else(|_| id.clone());
                Some(AudioDevice { is_default: Some(&id) == default_id.as_ref(), id, name })
            })
            .collect()
    }

    /// 已在跑且裝置相同時只更新帶通 / 增益；裝置不同就重啟。`device_id` 是 `list_input_devices` 的 id（也接受裝置名稱）
    pub fn start(&self, device_id: Option<&str>, bandpass: bool, gain: f32) -> anyhow::Result<()> {
        self.set_params(bandpass, gain);
        let wanted = device_id.filter(|s| !s.is_empty()).map(str::to_string);
        let mut worker = self.worker.lock();
        if let Some(w) = worker.as_ref() {
            if w.device_id == wanted && self.shared.running.load(Ordering::SeqCst) && !w.handle.is_finished() {
                return Ok(());
            }
        }
        if let Some(w) = worker.take() {
            Self::join(&self.shared, w);
        }

        let stop = Arc::new(AtomicBool::new(false));
        let (ready_tx, ready_rx) = std::sync::mpsc::channel::<Result<String, String>>();
        let shared = self.shared.clone();
        let stop2 = stop.clone();
        let dev = wanted.clone();
        let handle = std::thread::Builder::new()
            .name("audio-capture".into())
            .spawn(move || capture_thread(shared, dev, stop2, ready_tx))?;
        match ready_rx.recv_timeout(Duration::from_secs(8)) {
            Ok(Ok(desc)) => {
                log::info!("AudioEngine 啟動：{desc}");
                self.shared.running.store(true, Ordering::SeqCst);
                *worker = Some(Worker { stop, handle, device_id: wanted });
                Ok(())
            }
            Ok(Err(e)) => {
                stop.store(true, Ordering::SeqCst);
                let _ = handle.join();
                anyhow::bail!(e)
            }
            Err(_) => {
                stop.store(true, Ordering::SeqCst);
                anyhow::bail!("開啟麥克風逾時")
            }
        }
    }

    /// 錄音中改帶通 / 增益（下一包生效）
    pub fn set_params(&self, bandpass: bool, gain: f32) {
        let gain = if gain.is_finite() { gain.clamp(0.0, 8.0) } else { 1.0 };
        self.shared.bandpass.store(bandpass, Ordering::Relaxed);
        self.shared.gain_bits.store(gain.to_bits(), Ordering::Relaxed);
    }

    fn join(shared: &Shared, w: Worker) {
        w.stop.store(true, Ordering::SeqCst);
        let _ = w.handle.join();
        shared.running.store(false, Ordering::SeqCst);
        let mut inner = shared.inner.lock();
        inner.ring.clear();
        inner.packet.clear();
        shared.set_level(0.0);
    }

    pub fn stop(&self) {
        if let Some(w) = self.worker.lock().take() {
            Self::join(&self.shared, w);
            log::info!("AudioEngine 已停止");
        }
    }

    pub fn is_running(&self) -> bool {
        self.shared.running.load(Ordering::SeqCst)
    }

    /// replay_prebuffer=true：先把最近 1.5 秒回放給 sink，再開始即時供應（先回放再註冊，不交錯）
    pub fn add_sink(&self, id: &str, sink: AudioChunkSink, replay_prebuffer: bool) {
        self.shared.inner.lock().add_sink(id, sink, replay_prebuffer);
    }

    pub fn remove_sink(&self, id: &str) {
        self.shared.inner.lock().remove_sink(id);
    }

    /// 目前音量 0..1（已套增益），給膠囊波形
    pub fn level(&self) -> f32 {
        if !self.is_running() {
            return 0.0;
        }
        let at = Duration::from_nanos(self.shared.level_at.load(Ordering::Relaxed));
        if self.shared.epoch.elapsed().saturating_sub(at) > LEVEL_STALE {
            return 0.0;
        }
        f32::from_bits(self.shared.level_bits.load(Ordering::Relaxed))
    }

    /// cpal callback 因 buffer pool 用完而丟掉的包數（診斷用）
    pub fn overrun_count(&self) -> u64 {
        self.shared.overruns.load(Ordering::Relaxed)
    }
}

impl Default for AudioEngine {
    fn default() -> Self {
        Self::new()
    }
}

impl Drop for AudioEngine {
    fn drop(&mut self) {
        self.stop();
    }
}

fn find_device(host: &cpal::Host, id: Option<&str>) -> Option<cpal::Device> {
    if let Some(want) = id {
        if let Ok(devices) = host.input_devices() {
            for d in devices {
                let id_match = d.id().map(|i| i.to_string() == want).unwrap_or(false);
                let name_match = d.description().map(|n| n.name() == want).unwrap_or(false);
                if id_match || name_match {
                    return Some(d);
                }
            }
        }
        log::warn!("找不到輸入裝置 {want}，改用系統預設");
    }
    host.default_input_device()
}

fn build_stream<T>(
    device: &cpal::Device,
    config: cpal::StreamConfig,
    data_tx: Sender<Vec<f32>>,
    free_tx: Sender<Vec<f32>>,
    free_rx: Receiver<Vec<f32>>,
    shared: Arc<Shared>,
) -> Result<cpal::Stream, cpal::Error>
where
    T: SizedSample + Send + 'static,
    f32: FromSample<T>,
{
    device.build_input_stream::<T, _, _>(
        config,
        move |data: &[T], _: &cpal::InputCallbackInfo| {
            // 只做 memcpy + 型別轉換；buffer 來自預配置的 pool，送不出去就還回去
            let Ok(mut buf) = free_rx.try_recv() else {
                shared.overruns.fetch_add(1, Ordering::Relaxed);
                return;
            };
            buf.clear();
            let n = data.len().min(buf.capacity());
            buf.extend(data[..n].iter().map(|s| s.to_sample::<f32>()));
            if let Err(TrySendError::Full(b)) = data_tx.try_send(buf) {
                shared.overruns.fetch_add(1, Ordering::Relaxed);
                let _ = free_tx.try_send(b);
            }
        },
        |err: cpal::Error| log::warn!("音訊串流錯誤：{err}"),
        None,
    )
}

fn capture_thread(
    shared: Arc<Shared>,
    device_id: Option<String>,
    stop: Arc<AtomicBool>,
    ready: std::sync::mpsc::Sender<Result<String, String>>,
) {
    let host = cpal::default_host();
    let Some(device) = find_device(&host, device_id.as_deref()) else {
        let _ = ready.send(Err("找不到麥克風".into()));
        return;
    };
    let supported = match device.default_input_config() {
        Ok(c) => c,
        Err(e) => {
            let _ = ready.send(Err(format!("無法讀取麥克風格式：{e}")));
            return;
        }
    };
    let rate = supported.sample_rate();
    let channels = supported.channels();
    let format = supported.sample_format();
    let config = supported.config();

    let (data_tx, data_rx) = bounded::<Vec<f32>>(POOL_BUFFERS);
    let (free_tx, free_rx) = bounded::<Vec<f32>>(POOL_BUFFERS);
    for _ in 0..POOL_BUFFERS {
        let _ = free_tx.send(Vec::with_capacity(POOL_BUFFER_CAPACITY));
    }

    use cpal::SampleFormat as F;
    let (dt, ft, fr, sh) = (data_tx, free_tx.clone(), free_rx, shared.clone());
    let stream = match format {
        F::F32 => build_stream::<f32>(&device, config, dt, ft, fr, sh),
        F::I16 => build_stream::<i16>(&device, config, dt, ft, fr, sh),
        F::I32 => build_stream::<i32>(&device, config, dt, ft, fr, sh),
        F::U16 => build_stream::<u16>(&device, config, dt, ft, fr, sh),
        F::I8 => build_stream::<i8>(&device, config, dt, ft, fr, sh),
        F::U8 => build_stream::<u8>(&device, config, dt, ft, fr, sh),
        F::F64 => build_stream::<f64>(&device, config, dt, ft, fr, sh),
        other => {
            let _ = ready.send(Err(format!("不支援的麥克風取樣格式：{other}")));
            return;
        }
    };
    let stream = match stream {
        Ok(s) => s,
        Err(e) => {
            let _ = ready.send(Err(format!("開啟麥克風失敗：{e}")));
            return;
        }
    };
    if let Err(e) = stream.play() {
        let _ = ready.send(Err(format!("啟動麥克風失敗：{e}")));
        return;
    }
    let mut resampler = match Resampler::new(rate, channels) {
        Ok(r) => r,
        Err(e) => {
            let _ = ready.send(Err(e.to_string()));
            return;
        }
    };
    let name = device
        .description()
        .map(|d| d.name().to_string())
        .unwrap_or_default();
    let _ = ready.send(Ok(format!("{name}（{rate} Hz, {channels} ch, {format}）")));

    let mut filter = Bandpass::new(TARGET_RATE as f32);
    let mut filter_on = shared.bandpass.load(Ordering::Relaxed);
    let mut out: Vec<f32> = Vec::with_capacity(POOL_BUFFER_CAPACITY);
    while !stop.load(Ordering::SeqCst) {
        let buf = match data_rx.recv_timeout(Duration::from_millis(100)) {
            Ok(b) => b,
            Err(RecvTimeoutError::Timeout) => continue,
            Err(RecvTimeoutError::Disconnected) => break,
        };
        out.clear();
        resampler.process(&buf, &mut out);
        let _ = free_tx.try_send(buf);
        if out.is_empty() {
            continue;
        }
        let bp = shared.bandpass.load(Ordering::Relaxed);
        if bp != filter_on {
            filter.reset();
            filter_on = bp;
        }
        if bp {
            filter.process(&mut out);
        }
        let gain = shared.gain();
        if (gain - 1.0).abs() > f32::EPSILON {
            for s in out.iter_mut() {
                *s = (*s * gain).clamp(-1.0, 1.0);
            }
        }
        shared.set_level(normalized_level(&out));
        shared.inner.lock().push_processed(&out);
    }
    drop(stream);
    shared.running.store(false, Ordering::SeqCst);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn inner() -> Inner {
        Inner {
            ring: PreBufferRing::new(prebuffer::REPLAY_SECONDS, TARGET_RATE),
            packet: Vec::new(),
            sinks: Vec::new(),
        }
    }

    fn collector() -> (Arc<parking_lot::Mutex<Vec<f32>>>, AudioChunkSink) {
        let store = Arc::new(parking_lot::Mutex::new(Vec::new()));
        let s2 = store.clone();
        (store, Box::new(move |c: &[f32]| s2.lock().extend_from_slice(c)))
    }

    #[test]
    fn replay_then_live_without_gap_or_duplicate() {
        let mut inn = inner();
        // 樣本值 = 序號，方便檢查連續性
        let all: Vec<f32> = (0..40_000).map(|i| i as f32).collect();
        inn.push_processed(&all[..30_050]); // ring 留最後 1.5 秒（完整包），尾巴 1_250 個在 packet
        let (got, sink) = collector();
        inn.add_sink("rec", sink, true);
        inn.push_processed(&all[30_050..]);
        inn.remove_sink("rec"); // 交出未滿一包的尾巴
        let got = got.lock();
        // ring 只含完整的包（18 包 = 28_800），回放最後 24_000 個 → 從 4_800 開始，之後連續到最後一個樣本
        assert_eq!(got[0], 4_800.0);
        assert_eq!(*got.last().unwrap(), 39_999.0);
        for w in got.windows(2) {
            assert_eq!(w[1] - w[0], 1.0, "不連續於 {}", w[0]);
        }
    }

    #[test]
    fn no_replay_and_packets_are_100ms() {
        let mut inn = inner();
        inn.push_processed(&vec![0.5; 5_000]);
        let sizes = Arc::new(parking_lot::Mutex::new(Vec::new()));
        let s2 = sizes.clone();
        inn.add_sink("a", Box::new(move |c: &[f32]| s2.lock().push(c.len())), false);
        assert!(sizes.lock().is_empty());
        inn.push_processed(&vec![0.5; 3_300]);
        assert_eq!(*sizes.lock(), vec![PACKET_SAMPLES, PACKET_SAMPLES]);
        // 同 id 再加會取代舊的
        let (_g, sink) = collector();
        inn.add_sink("a", sink, false);
        assert_eq!(inn.sinks.len(), 1);
    }

    #[test]
    fn level_is_rms_times_five_clamped() {
        assert_eq!(normalized_level(&[]), 0.0);
        assert!((normalized_level(&[0.1, -0.1]) - 0.5).abs() < 1e-6);
        assert_eq!(normalized_level(&[0.9; 10]), 1.0);
    }

    #[test]
    fn engine_without_device_is_idle() {
        // 不開麥克風：只驗證未啟動時的狀態與 sink 管理
        let e = AudioEngine::new();
        assert!(!e.is_running());
        assert_eq!(e.level(), 0.0);
        let (_g, sink) = collector();
        e.add_sink("x", sink, true);
        e.remove_sink("x");
        e.stop();
    }
}

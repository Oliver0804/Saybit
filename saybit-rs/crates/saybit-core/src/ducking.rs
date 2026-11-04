//! 錄音時降低系統音量（批次 C3；移植 audio_duck.rs / SystemAudioDucker.swift）：原音量先寫 `data_dir()/pending-volume.json` 再降；啟動時還原殘留
//!
//! macOS：CoreAudio VirtualMainVolume；Windows：IAudioEndpointVolume；Linux：wpctl，退而求其次 pactl。

use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

const PENDING_FILE: &str = "pending-volume.json";
/// 原音量低於此值就不降（已經很小聲，降了也沒意義）
const MIN_VOLUME: f32 = 0.05;

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
struct Saved {
    /// 0..1
    volume: f32,
    /// macOS 的 AudioDeviceID；其他平台是預設輸出裝置，為 None
    device: Option<u32>,
}

static SAVED: Mutex<Option<Saved>> = Mutex::new(None);

fn pending_path() -> PathBuf {
    crate::paths::data_dir().join(PENDING_FILE)
}

fn write_pending(path: &Path, saved: &Saved) -> anyhow::Result<()> {
    let json = serde_json::to_vec(saved)?;
    std::fs::write(path, json).map_err(|e| anyhow::anyhow!("無法記錄原音量: {e}"))
}

fn read_pending(path: &Path) -> Option<Saved> {
    let bytes = std::fs::read(path).ok()?;
    serde_json::from_slice(&bytes).ok()
}

pub(crate) fn ducked_volume(current: f32, ratio: f32) -> f32 {
    (current * ratio).clamp(0.0, 1.0)
}

/// 降低前的判斷：比例無效回 Err；原音量太小回 None（不降）；否則回降低後的音量
pub(crate) fn plan_duck(current: f32, ratio: f32) -> anyhow::Result<Option<f32>> {
    anyhow::ensure!(ratio.is_finite(), "ratio 必須是數字");
    let ratio = ratio.clamp(0.0, 1.0);
    if current <= MIN_VOLUME {
        return Ok(None);
    }
    Ok(Some(ducked_volume(current, ratio)))
}

/// 把系統輸出音量降到原音量 × ratio（0..1）。已經降過就不再降（避免把降低後的音量當原音量）。
pub fn duck(ratio: f32) -> anyhow::Result<()> {
    let mut saved = SAVED.lock();
    if saved.is_some() {
        return Ok(());
    }
    let (device, current) = imp::current_volume()?;
    let Some(target) = plan_duck(current, ratio)? else { return Ok(()) };
    let path = pending_path();
    let s = Saved { volume: current, device };
    write_pending(&path, &s)?;
    if let Err(e) = imp::set_volume(device, target) {
        let _ = std::fs::remove_file(&path);
        return Err(e);
    }
    *saved = Some(s);
    Ok(())
}

fn restore_saved(saved: &mut Option<Saved>) -> anyhow::Result<()> {
    let Some(s) = saved.take() else { return Ok(()) };
    let result = imp::set_volume(s.device, s.volume);
    let _ = std::fs::remove_file(pending_path());
    result
}

pub fn restore() -> anyhow::Result<()> {
    restore_saved(&mut SAVED.lock())
}

/// App 啟動時呼叫：上次錄音中途結束沒還原的音量補還原
pub fn restore_pending_if_needed() {
    let mut saved = SAVED.lock();
    let result = if saved.is_some() {
        restore_saved(&mut saved)
    } else {
        let path = pending_path();
        match read_pending(&path) {
            Some(pending) => {
                let r = imp::set_volume(pending.device, pending.volume);
                // 裝置可能已不存在：不論成功與否都清掉，避免每次啟動都重試
                let _ = std::fs::remove_file(&path);
                r
            }
            None => {
                let _ = std::fs::remove_file(&path);
                Ok(())
            }
        }
    };
    if let Err(e) = result {
        log::warn!("還原殘留的系統音量失敗: {e}");
    }
}

// MARK: - macOS（CoreAudio）

#[cfg(target_os = "macos")]
mod imp {
    use std::ffi::c_void;

    type AudioObjectId = u32;
    type OsStatus = i32;

    #[repr(C)]
    struct PropertyAddress {
        selector: u32,
        scope: u32,
        element: u32,
    }

    const fn fourcc(s: &[u8; 4]) -> u32 {
        ((s[0] as u32) << 24) | ((s[1] as u32) << 16) | ((s[2] as u32) << 8) | (s[3] as u32)
    }

    const SYSTEM_OBJECT: AudioObjectId = 1;
    const DEFAULT_OUTPUT_DEVICE: u32 = fourcc(b"dOut");
    const SCOPE_GLOBAL: u32 = fourcc(b"glob");
    const SCOPE_OUTPUT: u32 = fourcc(b"outp");
    const ELEMENT_MAIN: u32 = 0;
    /// kAudioHardwareServiceDeviceProperty_VirtualMainVolume（原生版同一個屬性）
    const VIRTUAL_MAIN_VOLUME: u32 = fourcc(b"vmvc");

    // VirtualMainVolume 是 AudioHardwareService（AudioToolbox）提供的虛擬屬性，兩個 framework 都要連
    #[link(name = "AudioToolbox", kind = "framework")]
    extern "C" {}

    #[link(name = "CoreAudio", kind = "framework")]
    extern "C" {
        fn AudioObjectHasProperty(id: AudioObjectId, address: *const PropertyAddress) -> u8;
        fn AudioObjectIsPropertySettable(id: AudioObjectId, address: *const PropertyAddress, settable: *mut u8) -> OsStatus;
        fn AudioObjectGetPropertyData(
            id: AudioObjectId,
            address: *const PropertyAddress,
            qualifier_size: u32,
            qualifier: *const c_void,
            data_size: *mut u32,
            data: *mut c_void,
        ) -> OsStatus;
        fn AudioObjectSetPropertyData(
            id: AudioObjectId,
            address: *const PropertyAddress,
            qualifier_size: u32,
            qualifier: *const c_void,
            data_size: u32,
            data: *const c_void,
        ) -> OsStatus;
    }

    const VOLUME_ADDRESS: PropertyAddress =
        PropertyAddress { selector: VIRTUAL_MAIN_VOLUME, scope: SCOPE_OUTPUT, element: ELEMENT_MAIN };

    fn default_output_device() -> anyhow::Result<AudioObjectId> {
        let address = PropertyAddress { selector: DEFAULT_OUTPUT_DEVICE, scope: SCOPE_GLOBAL, element: ELEMENT_MAIN };
        let mut device: AudioObjectId = 0;
        let mut size = std::mem::size_of::<AudioObjectId>() as u32;
        // SAFETY: 位址與輸出緩衝都是有效的區域變數，大小與 AudioDeviceID 相符
        let status = unsafe {
            AudioObjectGetPropertyData(
                SYSTEM_OBJECT,
                &address,
                0,
                std::ptr::null(),
                &mut size,
                &mut device as *mut _ as *mut c_void,
            )
        };
        anyhow::ensure!(status == 0 && device != 0, "找不到預設輸出裝置 (OSStatus {status})");
        Ok(device)
    }

    pub fn current_volume() -> anyhow::Result<(Option<u32>, f32)> {
        let device = default_output_device()?;
        // SAFETY: 同上；先確認裝置有這個屬性
        unsafe {
            anyhow::ensure!(AudioObjectHasProperty(device, &VOLUME_ADDRESS) != 0, "輸出裝置不支援調整音量");
            let mut value: f32 = 0.0;
            let mut size = std::mem::size_of::<f32>() as u32;
            let status = AudioObjectGetPropertyData(
                device,
                &VOLUME_ADDRESS,
                0,
                std::ptr::null(),
                &mut size,
                &mut value as *mut _ as *mut c_void,
            );
            anyhow::ensure!(status == 0, "讀取音量失敗 (OSStatus {status})");
            Ok((Some(device), value))
        }
    }

    pub fn set_volume(device: Option<u32>, volume: f32) -> anyhow::Result<()> {
        let device = match device {
            Some(d) => d,
            None => default_output_device()?,
        };
        let value = volume.clamp(0.0, 1.0);
        // SAFETY: 位址與值都是有效的區域變數；先確認屬性存在且可寫
        unsafe {
            let mut settable: u8 = 0;
            anyhow::ensure!(
                AudioObjectHasProperty(device, &VOLUME_ADDRESS) != 0
                    && AudioObjectIsPropertySettable(device, &VOLUME_ADDRESS, &mut settable) == 0
                    && settable != 0,
                "輸出裝置不支援調整音量"
            );
            let status = AudioObjectSetPropertyData(
                device,
                &VOLUME_ADDRESS,
                0,
                std::ptr::null(),
                std::mem::size_of::<f32>() as u32,
                &value as *const _ as *const c_void,
            );
            anyhow::ensure!(status == 0, "設定音量失敗 (OSStatus {status})");
        }
        Ok(())
    }
}

// MARK: - Windows（IAudioEndpointVolume）

#[cfg(target_os = "windows")]
mod imp {
    use windows::Win32::Media::Audio::Endpoints::IAudioEndpointVolume;
    use windows::Win32::Media::Audio::{eConsole, eRender, IMMDeviceEnumerator, MMDeviceEnumerator};
    use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_ALL, COINIT_MULTITHREADED};

    fn default_endpoint() -> windows::core::Result<IAudioEndpointVolume> {
        // SAFETY: 呼叫端已在本執行緒初始化 COM
        unsafe {
            let enumerator: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)?;
            let device = enumerator.GetDefaultAudioEndpoint(eRender, eConsole)?;
            device.Activate(CLSCTX_ALL, None)
        }
    }

    /// 在獨立執行緒上做 COM：呼叫端執行緒的 apartment 狀態不可控
    fn with_endpoint<T: Send + 'static>(
        f: impl FnOnce(&IAudioEndpointVolume) -> windows::core::Result<T> + Send + 'static,
    ) -> anyhow::Result<T> {
        std::thread::spawn(move || {
            // SAFETY: 這條執行緒自己初始化 / 釋放 COM，介面在 CoUninitialize 前就 drop
            let init = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
            let result = default_endpoint().and_then(|ep| f(&ep));
            if init.is_ok() {
                unsafe { CoUninitialize() };
            }
            result.map_err(|e| anyhow::anyhow!("系統音量操作失敗: {e}"))
        })
        .join()
        .map_err(|_| anyhow::anyhow!("系統音量執行緒異常結束"))?
    }

    pub fn current_volume() -> anyhow::Result<(Option<u32>, f32)> {
        // SAFETY: 介面由 with_endpoint 保證有效
        with_endpoint(|ep| unsafe { ep.GetMasterVolumeLevelScalar() }).map(|v| (None, v))
    }

    pub fn set_volume(_device: Option<u32>, volume: f32) -> anyhow::Result<()> {
        let value = volume.clamp(0.0, 1.0);
        // SAFETY: 同上；event context 傳 null
        with_endpoint(move |ep| unsafe { ep.SetMasterVolumeLevelScalar(value, std::ptr::null()) })
    }
}

// MARK: - Linux（PipeWire wpctl / PulseAudio pactl）

#[cfg(target_os = "linux")]
mod imp {
    use std::process::Command;

    fn run(cmd: &str, args: &[&str]) -> anyhow::Result<String> {
        let out = Command::new(cmd).args(args).output().map_err(|e| anyhow::anyhow!("{cmd}: {e}"))?;
        anyhow::ensure!(out.status.success(), "{cmd} 失敗: {}", String::from_utf8_lossy(&out.stderr).trim());
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    }

    pub fn current_volume() -> anyhow::Result<(Option<u32>, f32)> {
        if let Ok(out) = run("wpctl", &["get-volume", "@DEFAULT_AUDIO_SINK@"]) {
            if let Some(v) = super::parse_wpctl_volume(&out) {
                return Ok((None, v));
            }
        }
        let out = run("pactl", &["get-sink-volume", "@DEFAULT_SINK@"])?;
        super::parse_pactl_volume(&out).map(|v| (None, v)).ok_or_else(|| anyhow::anyhow!("無法解析系統音量"))
    }

    pub fn set_volume(_device: Option<u32>, volume: f32) -> anyhow::Result<()> {
        let value = volume.clamp(0.0, 1.0);
        let wp = format!("{value:.3}");
        if run("wpctl", &["set-volume", "@DEFAULT_AUDIO_SINK@", &wp]).is_ok() {
            return Ok(());
        }
        let pa = format!("{}%", (value * 100.0).round() as u32);
        run("pactl", &["set-sink-volume", "@DEFAULT_SINK@", &pa]).map(|_| ())
    }
}

#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
mod imp {
    pub fn current_volume() -> anyhow::Result<(Option<u32>, f32)> {
        anyhow::bail!("unsupported")
    }
    pub fn set_volume(_device: Option<u32>, _volume: f32) -> anyhow::Result<()> {
        anyhow::bail!("unsupported")
    }
}

/// `wpctl get-volume` 輸出：`Volume: 0.40` 或 `Volume: 0.40 [MUTED]`
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub(crate) fn parse_wpctl_volume(out: &str) -> Option<f32> {
    let rest = out.trim().strip_prefix("Volume:")?;
    rest.split_whitespace().next()?.parse().ok()
}

/// `pactl get-sink-volume` 輸出：`Volume: front-left: 26214 /  40% / -23.88 dB, ...`，取第一個百分比
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub(crate) fn parse_pactl_volume(out: &str) -> Option<f32> {
    out.split_whitespace()
        .find_map(|tok| tok.strip_suffix('%')?.parse::<f32>().ok())
        .map(|p| p / 100.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_wpctl_and_pactl() {
        assert_eq!(parse_wpctl_volume("Volume: 0.40\n"), Some(0.40));
        assert_eq!(parse_wpctl_volume("Volume: 1.00 [MUTED]"), Some(1.0));
        assert_eq!(parse_wpctl_volume("garbage"), None);
        let pa = "Volume: front-left: 26214 /  40% / -23.88 dB,   front-right: 26214 /  40% / -23.88 dB\n        balance 0.00";
        assert_eq!(parse_pactl_volume(pa), Some(0.40));
        assert_eq!(parse_pactl_volume("nothing"), None);
    }

    #[test]
    fn pending_file_roundtrip() {
        let path = std::env::temp_dir().join(format!("saybit-duck-test-{}.json", std::process::id()));
        let s = Saved { volume: 0.75, device: Some(42) };
        write_pending(&path, &s).unwrap();
        // 檔案格式：{"volume":0.75,"device":42}
        let raw = std::fs::read_to_string(&path).unwrap();
        assert_eq!(raw, r#"{"volume":0.75,"device":42}"#);
        assert_eq!(read_pending(&path), Some(s));
        std::fs::write(&path, br#"{"volume":0.5,"device":null}"#).unwrap();
        assert_eq!(read_pending(&path), Some(Saved { volume: 0.5, device: None }));
        std::fs::write(&path, b"{broken").unwrap();
        assert_eq!(read_pending(&path), None);
        std::fs::remove_file(&path).ok();
        assert_eq!(read_pending(&path), None);
    }

    #[test]
    fn ducked_volume_is_clamped() {
        assert!((ducked_volume(0.5, 0.2) - 0.1).abs() < 1e-6);
        assert_eq!(ducked_volume(0.8, 2.0), 1.0);
    }

    #[test]
    fn plan_duck_rules() {
        assert!(plan_duck(0.5, f32::NAN).is_err());
        assert_eq!(plan_duck(0.04, 0.2).unwrap(), None); // 太小聲不降
        assert_eq!(plan_duck(0.05, 0.2).unwrap(), None);
        let v = plan_duck(0.5, 0.2).unwrap().unwrap();
        assert!((v - 0.1).abs() < 1e-6);
        // ratio 夾在 0..1：不會反而調大
        assert_eq!(plan_duck(0.5, 3.0).unwrap(), Some(0.5));
        assert_eq!(plan_duck(0.5, -1.0).unwrap(), Some(0.0));
    }

    /// 只讀取不改音量：cargo test -p saybit-core reads_current_volume -- --ignored --nocapture
    #[test]
    #[ignore]
    fn reads_current_volume() {
        let (device, volume) = imp::current_volume().unwrap();
        println!("device {device:?} volume {volume}");
        assert!((0.0..=1.0).contains(&volume));
    }
}

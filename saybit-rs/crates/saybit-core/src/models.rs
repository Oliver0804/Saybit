//! 模型下載（批次 C1）：SenseVoice（model.int8.onnx 237,115,547 + tokens.txt 315,894 + silero_vad.onnx 643,854，來源同 SherpaModelManager.swift）、
//! whisper ggml-large-v3-turbo-q5_0。存 `paths::models_dir()/<name>/`，大小相符才算 installed，.part 暫存。
//!
//! 下載狀態放在 process 全域表：多個 `ModelManager`（GUI、pipeline 各建一個）看到的進度一致，同一個模型同時只能有一個下載。

use crate::types::*;
use parking_lot::Mutex;
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

pub const ERR_CANCELLED: &str = "cancelled";

pub struct ModelFile {
    pub name: &'static str,
    pub url: &'static str,
    pub size: u64,
}

pub const SENSEVOICE_DIR: &str = "sense-voice-zh-en-ja-ko-yue-int8-2025-09-09";
pub const WHISPER_DIR: &str = "whisper-large-v3-turbo-q5_0";

pub const SENSEVOICE_FILES: &[ModelFile] = &[
    ModelFile {
        name: "model.int8.onnx",
        url: "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09/resolve/main/model.int8.onnx",
        size: 237_115_547,
    },
    ModelFile {
        name: "tokens.txt",
        url: "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09/resolve/main/tokens.txt",
        size: 315_894,
    },
    ModelFile {
        name: "silero_vad.onnx",
        url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx",
        size: 643_854,
    },
];

/// 大小取自實際下載的檔案（saybit-desktop 已在用的同一個檔）
pub const WHISPER_FILES: &[ModelFile] = &[ModelFile {
    name: "ggml-large-v3-turbo-q5_0.bin",
    url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin",
    size: 574_041_195,
}];

pub fn files(which: ModelKind) -> &'static [ModelFile] {
    match which {
        ModelKind::SenseVoice => SENSEVOICE_FILES,
        ModelKind::WhisperLocal => WHISPER_FILES,
    }
}

fn dir_name(which: ModelKind) -> &'static str {
    match which {
        ModelKind::SenseVoice => SENSEVOICE_DIR,
        ModelKind::WhisperLocal => WHISPER_DIR,
    }
}

fn file_size(path: &Path) -> Option<u64> {
    std::fs::metadata(path).ok().map(|m| m.len())
}

/// 目錄裡每個檔案大小完全相符才算安裝完成
pub fn is_installed_in(dir: &Path, which: ModelKind) -> bool {
    files(which).iter().all(|f| file_size(&dir.join(f.name)) == Some(f.size))
}

/// 進度 0..1：已完成檔案的位元組 + 目前檔案已寫入，除以總大小；完成前最多 0.999
pub fn download_progress(done_bytes: u64, written: u64, total: u64) -> f32 {
    if total == 0 {
        return 0.0;
    }
    ((done_bytes + written) as f64 / total as f64).clamp(0.0, 0.999) as f32
}

#[derive(Default)]
struct Status {
    downloading: HashMap<(PathBuf, ModelKind), f32>,
    failed: HashMap<(PathBuf, ModelKind), String>,
}

fn status() -> &'static Mutex<Status> {
    static S: std::sync::OnceLock<Mutex<Status>> = std::sync::OnceLock::new();
    S.get_or_init(Default::default)
}

pub struct ModelManager {
    root: PathBuf,
}

impl ModelManager {
    pub fn new() -> Self {
        Self { root: crate::paths::models_dir() }
    }

    /// 測試或自訂位置用
    pub fn with_root(root: PathBuf) -> Self {
        Self { root }
    }

    fn key(&self, which: ModelKind) -> (PathBuf, ModelKind) {
        (self.root.clone(), which)
    }

    pub fn state(&self, which: ModelKind) -> ModelState {
        if which == ModelKind::SenseVoice && !crate::stt::sherpa::SUPPORTED {
            return ModelState::Unsupported(crate::stt::sherpa::MSG_UNSUPPORTED.into());
        }
        let st = status().lock();
        if let Some(p) = st.downloading.get(&self.key(which)) {
            return ModelState::Downloading { progress: *p };
        }
        if is_installed_in(&self.dir(which), which) {
            return ModelState::Installed;
        }
        if let Some(e) = st.failed.get(&self.key(which)) {
            return ModelState::Failed(e.clone());
        }
        ModelState::NotInstalled
    }

    pub fn is_installed(&self, which: ModelKind) -> bool {
        is_installed_in(&self.dir(which), which)
    }

    /// 阻塞直到完成；進度回呼 0..1；cancel 置位則回 Err 且 state 回 NotInstalled
    pub fn download(&self, which: ModelKind, on_progress: &mut dyn FnMut(f32), cancel: &CancelToken) -> anyhow::Result<()> {
        let dir = self.dir(which);
        if is_installed_in(&dir, which) {
            on_progress(1.0);
            return Ok(());
        }
        let key = self.key(which);
        {
            let mut st = status().lock();
            if st.downloading.contains_key(&key) {
                anyhow::bail!("模型下載進行中");
            }
            st.failed.remove(&key);
            st.downloading.insert(key.clone(), 0.0);
        }
        let result = download_all(&dir, which, &key, on_progress, cancel);
        let mut st = status().lock();
        st.downloading.remove(&key);
        match &result {
            Ok(()) => {}
            Err(e) if e.to_string() == ERR_CANCELLED => {}
            Err(e) => {
                st.failed.insert(key, e.to_string());
            }
        }
        result
    }

    pub fn delete(&self, which: ModelKind) -> anyhow::Result<()> {
        // 先放掉記憶體中的模型（SenseVoice 約 250 MB、whisper 約 600 MB）
        match which {
            ModelKind::SenseVoice => crate::stt::sherpa::unload(),
            ModelKind::WhisperLocal => crate::stt::whisper_local::unload(),
        }
        let dir = self.dir(which);
        if dir.exists() {
            std::fs::remove_dir_all(&dir).map_err(|e| anyhow::anyhow!("刪除模型失敗：{e}"))?;
        }
        status().lock().failed.remove(&self.key(which));
        Ok(())
    }

    pub fn dir(&self, which: ModelKind) -> PathBuf {
        self.root.join(dir_name(which))
    }

    pub fn total_bytes(which: ModelKind) -> u64 {
        files(which).iter().map(|f| f.size).sum()
    }
}

impl Default for ModelManager {
    fn default() -> Self {
        Self::new()
    }
}

fn download_all(
    dir: &Path,
    which: ModelKind,
    key: &(PathBuf, ModelKind),
    on_progress: &mut dyn FnMut(f32),
    cancel: &CancelToken,
) -> anyhow::Result<()> {
    std::fs::create_dir_all(dir)?;
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .timeout_connect(Some(Duration::from_secs(15)))
        .timeout_recv_response(Some(Duration::from_secs(60)))
        .http_status_as_error(false)
        .build()
        .into();
    let total = ModelManager::total_bytes(which);
    let mut done = 0u64;
    let mut report = |p: f32| {
        if let Some(v) = status().lock().downloading.get_mut(key) {
            *v = p;
        }
        on_progress(p);
    };
    report(0.0);
    for file in files(which) {
        let dest = dir.join(file.name);
        if file_size(&dest) == Some(file.size) {
            done += file.size;
            continue;
        }
        fetch_file(&agent, file, &dest, done, total, cancel, &mut report)?;
        done += file.size;
    }
    if cancel.is_cancelled() {
        anyhow::bail!(ERR_CANCELLED);
    }
    if !is_installed_in(dir, which) {
        anyhow::bail!("模型檔案大小不符，請重新下載");
    }
    report(1.0);
    Ok(())
}

fn fetch_file(
    agent: &ureq::Agent,
    file: &ModelFile,
    dest: &Path,
    done: u64,
    total: u64,
    cancel: &CancelToken,
    report: &mut dyn FnMut(f32),
) -> anyhow::Result<()> {
    let part = dest.with_file_name(format!("{}.part", file.name));
    let result = (|| -> anyhow::Result<()> {
        if cancel.is_cancelled() {
            anyhow::bail!(ERR_CANCELLED);
        }
        let resp = agent
            .get(file.url)
            .call()
            .map_err(|e| anyhow::anyhow!("下載請求失敗：{e}"))?;
        if !resp.status().is_success() {
            anyhow::bail!("下載 {} 失敗 HTTP {}", file.name, resp.status().as_u16());
        }
        let mut reader = resp.into_body().into_reader();
        let mut out = std::io::BufWriter::new(std::fs::File::create(&part)?);
        let mut buf = vec![0u8; 256 * 1024];
        let mut written = 0u64;
        let mut last = std::time::Instant::now();
        loop {
            if cancel.is_cancelled() {
                anyhow::bail!(ERR_CANCELLED);
            }
            let n = reader.read(&mut buf).map_err(|e| anyhow::anyhow!("下載中斷：{e}"))?;
            if n == 0 {
                break;
            }
            out.write_all(&buf[..n])?;
            written += n as u64;
            if written > file.size {
                anyhow::bail!("{} 大小不符", file.name);
            }
            if last.elapsed() >= Duration::from_millis(200) {
                report(download_progress(done, written, total));
                last = std::time::Instant::now();
            }
        }
        out.flush()?;
        drop(out);
        if written != file.size {
            anyhow::bail!("{} 大小不符（{written} / {} bytes）", file.name, file.size);
        }
        if cancel.is_cancelled() {
            anyhow::bail!(ERR_CANCELLED);
        }
        Ok(())
    })();
    if let Err(e) = result {
        let _ = std::fs::remove_file(&part);
        return Err(e);
    }
    std::fs::rename(&part, dest)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_root(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("saybit-models-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn urls_and_sizes() {
        assert_eq!(ModelManager::total_bytes(ModelKind::SenseVoice), 237_115_547 + 315_894 + 643_854);
        assert_eq!(ModelManager::total_bytes(ModelKind::WhisperLocal), 574_041_195);
        for f in SENSEVOICE_FILES.iter().chain(WHISPER_FILES) {
            assert!(f.url.starts_with("https://"));
            assert!(f.url.ends_with(f.name), "{}", f.url);
        }
    }

    #[test]
    fn progress_is_capped_until_done() {
        assert_eq!(download_progress(0, 0, 0), 0.0);
        assert!((download_progress(50, 25, 100) - 0.75).abs() < 1e-6);
        assert_eq!(download_progress(100, 0, 100), 0.999);
    }

    #[test]
    fn installed_requires_exact_sizes_and_delete_cleans() {
        let root = temp_root("inst");
        let m = ModelManager::with_root(root.clone());
        let dir = m.dir(ModelKind::SenseVoice);
        assert!(dir.ends_with(SENSEVOICE_DIR));
        std::fs::create_dir_all(&dir).unwrap();
        assert!(!m.is_installed(ModelKind::SenseVoice));
        for f in SENSEVOICE_FILES {
            std::fs::File::create(dir.join(f.name)).unwrap().set_len(f.size).unwrap();
        }
        assert!(m.is_installed(ModelKind::SenseVoice));
        if crate::stt::sherpa::SUPPORTED {
            assert_eq!(m.state(ModelKind::SenseVoice), ModelState::Installed);
        }
        std::fs::File::create(dir.join("tokens.txt")).unwrap().set_len(10).unwrap();
        assert!(!m.is_installed(ModelKind::SenseVoice));
        m.delete(ModelKind::SenseVoice).unwrap();
        assert!(!dir.exists());
        assert_eq!(m.state(ModelKind::WhisperLocal), ModelState::NotInstalled);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn cancelled_before_start_leaves_no_part_file() {
        let root = temp_root("cancel");
        let m = ModelManager::with_root(root.clone());
        let cancel = CancelToken::new();
        cancel.cancel();
        let err = m.download(ModelKind::WhisperLocal, &mut |_| {}, &cancel).unwrap_err();
        assert_eq!(err.to_string(), ERR_CANCELLED);
        assert_eq!(m.state(ModelKind::WhisperLocal), ModelState::NotInstalled);
        let leftovers: Vec<_> = std::fs::read_dir(m.dir(ModelKind::WhisperLocal)).unwrap().collect();
        assert!(leftovers.is_empty());
        std::fs::remove_dir_all(&root).ok();
    }
}

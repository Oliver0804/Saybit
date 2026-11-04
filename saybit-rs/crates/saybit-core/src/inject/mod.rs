//! 文字注入（批次 C3；移植 TextInjector.swift + ClipboardBackup.swift + saybit-desktop injection.rs）。
//! enigo 0.6：paste（寫剪貼簿 → Cmd/Ctrl+V → 確認後還原，macOS 標 TransientType）、keypress（可取消、每 20 字比對前景、換行送 Return）、replace_selection。
//! macOS 的 enigo 必須在主執行緒呼叫（見 saybit-desktop/CLAUDE.md）：提供 `set_main_thread_runner` 讓 GUI 注入「在主執行緒跑閉包」的方法。

pub(crate) mod clipboard;

use crate::platform;
use crate::types::*;
use enigo::{Direction, Enigo, Key, Keyboard, Settings as EnigoSettings};
use parking_lot::{Mutex, RwLock};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::thread::ThreadId;
use std::time::{Duration, Instant};

#[derive(Debug, thiserror::Error)]
pub enum InjectError {
    #[error("foreground-changed")] ForegroundChanged,
    #[error("cancelled")] Cancelled,
    #[error("{0}")] Other(String),
}

#[cfg(target_os = "macos")]
pub(crate) const PASTE_MODIFIER: Key = Key::Meta;
#[cfg(not(target_os = "macos"))]
pub(crate) const PASTE_MODIFIER: Key = Key::Control;

/// 逐字輸入：每段最多幾個字元，也是「比對一次前景 App」的間隔
const KEYPRESS_CHUNK_CHARS: usize = 20;
/// 逐字輸入：每段之間的間隔（原生版 keystrokeInterval）
const KEYPRESS_INTERVAL: Duration = Duration::from_millis(20);
/// 貼上後至少等這麼久才還原剪貼簿（拿不到 AX 確認時原生版同樣退回 0.8 s）
const RESTORE_MIN_WAIT: Duration = Duration::from_millis(800);
/// 實際還原時間點；0.8–2 s 之間，給慢速 Electron App 一點餘裕
const RESTORE_AT: Duration = Duration::from_millis(1200);
const RESTORE_POLL: Duration = Duration::from_millis(100);
/// 主執行緒 runner 最多等多久
const MAIN_THREAD_TIMEOUT: Duration = Duration::from_secs(2);

// ───────────────────────────── 主執行緒 runner ─────────────────────────────

/// `Box<dyn Fn(Box<dyn FnOnce() + Send>) + Send + Sync>`
pub type Runner = Box<dyn Fn(Box<dyn FnOnce() + Send>) + Send + Sync>;

struct MainRunner {
    run: Runner,
    /// 設定 runner 的執行緒（視為主執行緒）：已在這條執行緒上就直接跑，避免自己等自己
    main_thread: ThreadId,
}

static RUNNER: RwLock<Option<MainRunner>> = RwLock::new(None);

/// GUI 啟動時（在主執行緒）設定：把閉包丟到主執行緒執行並等它完成（eframe 用 ctx.request_repaint + 佇列，或 winit EventLoopProxy）
pub fn set_main_thread_runner(runner: Runner) {
    *RUNNER.write() = Some(MainRunner { run: runner, main_thread: std::thread::current().id() });
}

fn on_main_thread_already(main_thread: ThreadId) -> bool {
    #[cfg(target_os = "macos")]
    {
        if objc2::MainThreadMarker::new().is_some() {
            return true;
        }
    }
    std::thread::current().id() == main_thread
}

/// 在主執行緒跑 `f` 並等結果（最多 `timeout`）。runner 未設定或已在主執行緒時直接在當前執行緒跑。
pub(crate) fn run_on_main<T, F>(timeout: Duration, f: F) -> Result<T, InjectError>
where
    T: Send + 'static,
    F: FnOnce() -> T + Send + 'static,
{
    let guard = RUNNER.read();
    match guard.as_ref() {
        Some(r) if !on_main_thread_already(r.main_thread) => {
            let (tx, rx) = mpsc::channel::<T>();
            (r.run)(Box::new(move || {
                let _ = tx.send(f());
            }));
            drop(guard);
            rx.recv_timeout(timeout)
                .map_err(|_| InjectError::Other("main-thread-timeout".into()))
        }
        _ => {
            drop(guard);
            Ok(f())
        }
    }
}

fn new_enigo() -> Result<Enigo, InjectError> {
    let settings = EnigoSettings {
        // 權限提示由 GUI 的 platform::request_accessibility 負責，別在送鍵時彈系統對話框
        open_prompt_to_get_permissions: false,
        ..EnigoSettings::default()
    };
    Enigo::new(&settings).map_err(|e| InjectError::Other(format!("enigo: {e}")))
}

/// 在主執行緒上建 Enigo 並執行 `f`
fn run_enigo<F>(f: F) -> Result<(), InjectError>
where
    F: FnOnce(&mut Enigo) + Send + 'static,
{
    run_on_main(MAIN_THREAD_TIMEOUT, move || -> Result<(), InjectError> {
        let mut enigo = new_enigo()?;
        f(&mut enigo);
        Ok(())
    })?
}

pub(crate) fn send_keys(keys: Vec<(Key, Direction)>) -> Result<(), InjectError> {
    run_enigo(move |enigo| {
        for (key, dir) in keys {
            if let Err(e) = enigo.key(key, dir) {
                log::warn!("enigo key {key:?} {dir:?}: {e}");
            }
        }
    })
}

/// Cmd/Ctrl + 字母
pub(crate) fn send_shortcut(letter: char) -> Result<(), InjectError> {
    send_keys(vec![
        (PASTE_MODIFIER, Direction::Press),
        (Key::Unicode(letter), Direction::Click),
        (PASTE_MODIFIER, Direction::Release),
    ])
}

// ───────────────────────────── 前景比對 ─────────────────────────────

fn ensure_foreground(expected: Option<&str>) -> Result<(), InjectError> {
    match expected {
        Some(exp) if !exp.trim().is_empty() => {
            if platform::foreground_matches(exp, &platform::foreground_app()) {
                Ok(())
            } else {
                Err(InjectError::ForegroundChanged)
            }
        }
        _ => Ok(()),
    }
}

// ───────────────────────────── 公開 API ─────────────────────────────

/// 逐字輸入的世代計數：每次新的 inject_text 或 cancel_typing 都 +1，迴圈每段前比對，不一致就停
static TYPING_GENERATION: AtomicU64 = AtomicU64::new(0);

/// 阻塞直到注入完成（keypress 模式會等打完）。expected_bundle_id 有給就先比對前景。
pub fn inject_text(
    text: &str,
    mode: InjectionMode,
    expected_bundle_id: Option<&str>,
    newline_with_shift: bool,
    cancel: &CancelToken,
) -> Result<(), InjectError> {
    // 新的注入一律讓進行中的逐字輸入作廢
    let generation = TYPING_GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
    if text.is_empty() {
        return Ok(());
    }
    if cancel.is_cancelled() {
        return Err(InjectError::Cancelled);
    }
    ensure_foreground(expected_bundle_id)?;
    match mode {
        InjectionMode::Paste => inject_via_paste(text),
        InjectionMode::Keypress => {
            inject_via_keypress(text, generation, expected_bundle_id, newline_with_shift, cancel)
        }
        InjectionMode::ReplaceSelection => {
            send_keys(vec![(Key::Backspace, Direction::Click)])?;
            std::thread::sleep(Duration::from_millis(50));
            if cancel.is_cancelled() {
                return Err(InjectError::Cancelled);
            }
            inject_via_paste(text)
        }
    }
}

/// 送 Enter（不帶修飾鍵）。expected_bundle_id 有給就先比對前景。
pub fn simulate_enter(expected_bundle_id: Option<&str>) -> Result<(), InjectError> {
    ensure_foreground(expected_bundle_id)?;
    send_keys(vec![(Key::Return, Direction::Click)])
}

/// 中止進行中的逐字輸入（剩下的段落不再送出）
pub fn cancel_typing() {
    TYPING_GENERATION.fetch_add(1, Ordering::SeqCst);
}

/// keypress：段數 × 0.02 + 0.15（照原生版 TextInjector.estimatedDuration，以送出事件數計）；其他 0.15
/// （Smart Send 等它打完再倒數）
pub fn estimated_duration_secs(text: &str, mode: InjectionMode) -> f32 {
    match mode {
        InjectionMode::Keypress => {
            keypress_chunks(text, KEYPRESS_CHUNK_CHARS).len() as f32 * KEYPRESS_INTERVAL.as_secs_f32()
                + 0.15
        }
        InjectionMode::Paste | InjectionMode::ReplaceSelection => 0.15,
    }
}

// ───────────────────────────── 貼上 ─────────────────────────────

/// 尚未還原的剪貼簿備份。連續兩次貼上時，第二次若重新備份，備份到的會是第一次注入的文字；
/// 所以還原前的新貼上直接沿用這份原始備份。
struct PendingRestore {
    generation: u64,
    backup: clipboard::Snapshot,
}
static PENDING_RESTORE: Mutex<Option<PendingRestore>> = Mutex::new(None);
static PASTE_GENERATION: AtomicU64 = AtomicU64::new(0);

/// 這次貼上要用的備份：還有未還原的就沿用，否則現在拍一份
fn take_or_snapshot(pending: &mut Option<PendingRestore>, generation: u64, fresh: impl FnOnce() -> clipboard::Snapshot) {
    let backup = match pending.take() {
        Some(prev) => prev.backup,
        None => fresh(),
    };
    *pending = Some(PendingRestore { generation, backup });
}

/// 還原執行緒要不要負責還原：只有自己仍是最新那次貼上才拿走備份
fn claim_backup(pending: &mut Option<PendingRestore>, generation: u64) -> Option<clipboard::Snapshot> {
    match pending.as_ref() {
        Some(p) if p.generation == generation => pending.take().map(|p| p.backup),
        _ => None,
    }
}

fn discard_pending(generation: u64) {
    let mut pending = PENDING_RESTORE.lock();
    if pending.as_ref().map(|p| p.generation) == Some(generation) {
        *pending = None;
    }
}

fn inject_via_paste(text: &str) -> Result<(), InjectError> {
    let generation = PASTE_GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
    take_or_snapshot(&mut PENDING_RESTORE.lock(), generation, clipboard::snapshot);

    let our_mark = match clipboard::write_transient(text) {
        Ok(m) => m,
        Err(e) => {
            discard_pending(generation);
            return Err(InjectError::Other(e));
        }
    };

    // 給剪貼簿寫入落地的時間，太快送 Cmd+V 會貼到舊內容
    std::thread::sleep(Duration::from_millis(50));
    send_shortcut('v')?;

    std::thread::spawn(move || {
        let start = Instant::now();
        while start.elapsed() < RESTORE_AT {
            std::thread::sleep(RESTORE_POLL);
            // 使用者（或別的程式）在這期間改了剪貼簿 → 不還原，也不再管這份備份
            if !clipboard::still_ours(&our_mark) {
                discard_pending(generation);
                return;
            }
        }
        debug_assert!(start.elapsed() >= RESTORE_MIN_WAIT);
        let Some(backup) = claim_backup(&mut PENDING_RESTORE.lock(), generation) else {
            return; // 更新的貼上接手了這份備份，由它還原
        };
        if clipboard::still_ours(&our_mark) {
            clipboard::restore(&backup);
        }
    });
    Ok(())
}

// ───────────────────────────── 逐字輸入 ─────────────────────────────

/// 逐字輸入的事件單位
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum KeypressChunk {
    /// 一段文字（≤ KEYPRESS_CHUNK_CHARS 個字元）
    Text(String),
    /// 換行：送真正的 Return 鍵。以字元送 "\n" 會被 Chromium 系 App 當 Enter 直接送出。
    Newline,
}

/// 換行獨立成 Return 鍵（"\r\n" 算一次），其餘每段最多 `max_chars` 個字元。
pub(crate) fn keypress_chunks(text: &str, max_chars: usize) -> Vec<KeypressChunk> {
    let max_chars = max_chars.max(1);
    let mut chunks = Vec::new();
    let mut buffer = String::new();
    let mut count = 0usize;
    let mut prev_cr = false;
    for c in text.chars() {
        if c == '\n' || c == '\r' {
            let is_crlf_tail = c == '\n' && prev_cr;
            prev_cr = c == '\r';
            if is_crlf_tail {
                continue;
            }
            if !buffer.is_empty() {
                chunks.push(KeypressChunk::Text(std::mem::take(&mut buffer)));
                count = 0;
            }
            chunks.push(KeypressChunk::Newline);
            continue;
        }
        prev_cr = false;
        if count == max_chars {
            chunks.push(KeypressChunk::Text(std::mem::take(&mut buffer)));
            count = 0;
        }
        buffer.push(c);
        count += 1;
    }
    if !buffer.is_empty() {
        chunks.push(KeypressChunk::Text(buffer));
    }
    chunks
}

fn inject_via_keypress(
    text: &str,
    generation: u64,
    expected: Option<&str>,
    newline_with_shift: bool,
    cancel: &CancelToken,
) -> Result<(), InjectError> {
    // 沒給 expected 時以開始輸入當下的前景 App 為準，中途換了一樣停
    let baseline = match expected {
        Some(e) if !e.trim().is_empty() => e.to_string(),
        _ => platform::foreground_app().bundle_id,
    };
    for (index, chunk) in keypress_chunks(text, KEYPRESS_CHUNK_CHARS).into_iter().enumerate() {
        if cancel.is_cancelled() || TYPING_GENERATION.load(Ordering::SeqCst) != generation {
            return Err(InjectError::Cancelled);
        }
        if index > 0 && !platform::foreground_matches(&baseline, &platform::foreground_app()) {
            return Err(InjectError::ForegroundChanged);
        }
        match chunk {
            KeypressChunk::Newline if newline_with_shift => send_keys(vec![
                (Key::Shift, Direction::Press),
                (Key::Return, Direction::Click),
                (Key::Shift, Direction::Release),
            ])?,
            KeypressChunk::Newline => send_keys(vec![(Key::Return, Direction::Click)])?,
            KeypressChunk::Text(s) => run_enigo(move |enigo| {
                if let Err(e) = enigo.text(&s) {
                    log::warn!("enigo text: {e}");
                }
            })?,
        }
        std::thread::sleep(KEYPRESS_INTERVAL);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use KeypressChunk::{Newline, Text};

    fn t(s: &str) -> KeypressChunk {
        Text(s.into())
    }

    #[test]
    fn keypress_chunks_split_by_length() {
        let s = "a".repeat(45);
        let chunks = keypress_chunks(&s, 20);
        assert_eq!(chunks, vec![t(&"a".repeat(20)), t(&"a".repeat(20)), t(&"a".repeat(5))]);
        assert_eq!(keypress_chunks("", 20), vec![]);
        assert_eq!(keypress_chunks(&"字".repeat(20), 20), vec![t(&"字".repeat(20))]);
    }

    #[test]
    fn keypress_chunks_newlines_become_return() {
        assert_eq!(keypress_chunks("ab\ncd", 20), vec![t("ab"), Newline, t("cd")]);
        assert_eq!(keypress_chunks("ab\r\ncd", 20), vec![t("ab"), Newline, t("cd")]);
        assert_eq!(keypress_chunks("\n\n", 20), vec![Newline, Newline]);
        assert_eq!(keypress_chunks("a\r\rb", 20), vec![t("a"), Newline, Newline, t("b")]);
    }

    #[test]
    fn keypress_chunks_do_not_split_emoji() {
        let chunks = keypress_chunks("👍🏽x", 1);
        assert_eq!(chunks, vec![t("👍"), t("🏽"), t("x")]);
    }

    #[test]
    fn estimated_duration() {
        assert!((estimated_duration_secs("hello", InjectionMode::Paste) - 0.15).abs() < 1e-6);
        assert!((estimated_duration_secs("hello", InjectionMode::ReplaceSelection) - 0.15).abs() < 1e-6);
        // 45 字 → 3 段
        let k = estimated_duration_secs(&"a".repeat(45), InjectionMode::Keypress);
        assert!((k - (3.0 * 0.02 + 0.15)).abs() < 1e-5, "{k}");
        // 換行算一段
        let k = estimated_duration_secs("ab\ncd", InjectionMode::Keypress);
        assert!((k - (3.0 * 0.02 + 0.15)).abs() < 1e-5, "{k}");
    }

    #[test]
    fn pending_backup_is_reused_across_quick_pastes() {
        let mut pending: Option<PendingRestore> = None;
        take_or_snapshot(&mut pending, 1, clipboard::Snapshot::default);
        // 第二次貼上不應重拍快照
        take_or_snapshot(&mut pending, 2, || panic!("should reuse previous backup"));
        assert_eq!(pending.as_ref().map(|p| p.generation), Some(2));
        // 舊的還原執行緒拿不到；最新的拿得到且只拿一次
        assert!(claim_backup(&mut pending, 1).is_none());
        assert!(claim_backup(&mut pending, 2).is_some());
        assert!(claim_backup(&mut pending, 2).is_none());
    }

    #[test]
    fn run_on_main_without_runner_runs_inline() {
        // 測試行程不設定 runner：直接在當前執行緒跑
        assert_eq!(run_on_main(Duration::from_millis(10), || 7).unwrap(), 7);
    }

    #[test]
    fn cancelled_token_short_circuits_without_keys() {
        let c = CancelToken::new();
        c.cancel();
        // 已取消：不碰剪貼簿、不送鍵
        assert!(matches!(
            inject_text("x", InjectionMode::Paste, None, false, &c),
            Err(InjectError::Cancelled)
        ));
        // 空字串直接成功
        assert!(inject_text("", InjectionMode::Keypress, None, false, &CancelToken::new()).is_ok());
    }
}

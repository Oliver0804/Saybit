// 文字注入：把精煉結果送進前景 App。對應原生版 Core/Accessibility/TextInjector.swift。
//
// 三種模式與原生版一致：
//   paste             — 寫剪貼簿 + Cmd/Ctrl+V（預設，最快也最可靠）
//   keypress          — 逐字模擬鍵盤輸入，給不吃貼上的 App（部分終端機、遊戲輸入框）
//   replace_selection — 先送 Backspace 清掉選取內容再貼上
//
// 貼上模式會備份並還原使用者原本的剪貼簿內容 —— 先前 Tauri 版只有備份、從來沒
// 還原，等於每次語音輸入都吃掉使用者的剪貼簿。

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc, Mutex};
use std::time::{Duration, Instant};
use tauri::AppHandle;

use enigo::{Direction, Enigo, Key, Keyboard, Settings};

use crate::platform::{ensure_foreground, foreground_matches, query_foreground};

#[cfg(target_os = "macos")]
const PASTE_MODIFIER: Key = Key::Meta;
#[cfg(not(target_os = "macos"))]
const PASTE_MODIFIER: Key = Key::Control;

/// 注入模式。與前端 settings.injectionMode 的字串值對應。
#[derive(serde::Deserialize, Debug, Clone, Copy, PartialEq, Default)]
#[serde(rename_all = "snake_case")]
pub enum InjectionMode {
    #[default]
    Paste,
    Keypress,
    ReplaceSelection,
}

/// 逐字輸入：每段最多幾個字元，也是「比對一次前景 App」的間隔
const KEYPRESS_CHUNK_CHARS: usize = 20;
/// 逐字輸入：每段之間的間隔（原生版 keystrokeInterval）
const KEYPRESS_INTERVAL: Duration = Duration::from_millis(20);
/// 貼上後至少等這麼久才還原剪貼簿。沒有 AX 可讀焦點元素的值，無法確認
/// 「真的貼上了」，只能固定等待（原生版在 AX 讀不到時同樣退回 0.8s）。
const RESTORE_MIN_WAIT: Duration = Duration::from_millis(800);
/// 實際還原時間點；介於 0.8–2s 之間，給慢速 Electron App 多一點餘裕。
const RESTORE_AT: Duration = Duration::from_millis(1200);
const RESTORE_POLL: Duration = Duration::from_millis(100);

/// 逐字輸入的世代計數：每次新的 inject_text 或 cancel_typing 都 +1，
/// 迴圈每段前比對，不一致就停止 —— 取代原本無法取消的單次 enigo.text()。
static TYPING_GENERATION: AtomicU64 = AtomicU64::new(0);

/// 尚未還原的剪貼簿備份。連續兩次貼上時，第二次若重新讀剪貼簿，備份到的會是
/// 第一次注入的文字；所以還原前的新貼上直接沿用這份原始備份。
struct PendingRestore {
    generation: u64,
    backup: Option<String>,
}
static PENDING_RESTORE: Mutex<Option<PendingRestore>> = Mutex::new(None);
static PASTE_GENERATION: AtomicU64 = AtomicU64::new(0);

// async：跑在 blocking thread pool，不卡主執行緒；逐字輸入期間 cancel_typing
// （同步命令，在主執行緒處理）才進得來。按鍵本身仍派回主執行緒送。
#[tauri::command(async)]
pub fn inject_text(
    app: AppHandle,
    text: String,
    mode: InjectionMode,
    expected_bundle_id: Option<String>,
    newline_with_shift: Option<bool>,
) -> Result<(), String> {
    // 新的注入一律讓進行中的逐字輸入作廢
    let generation = TYPING_GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
    if text.is_empty() {
        return Ok(());
    }
    let expected = expected_bundle_id.as_deref();
    ensure_foreground(&app, expected)?;
    match mode {
        InjectionMode::Paste => inject_via_paste(&app, &text),
        InjectionMode::Keypress => inject_via_keypress(
            &app,
            &text,
            generation,
            expected,
            newline_with_shift.unwrap_or(false),
        ),
        InjectionMode::ReplaceSelection => {
            send_keys(&app, vec![(Key::Backspace, Direction::Click)])?;
            std::thread::sleep(Duration::from_millis(50));
            inject_via_paste(&app, &text)
        }
    }
}

/// 中止進行中的逐字輸入（剩下的段落不再送出）。
#[tauri::command]
pub fn cancel_typing() {
    TYPING_GENERATION.fetch_add(1, Ordering::SeqCst);
}

fn inject_via_paste(app: &AppHandle, text: &str) -> Result<(), String> {
    let generation = PASTE_GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
    {
        let mut pending = PENDING_RESTORE.lock().unwrap_or_else(|e| e.into_inner());
        let backup = match pending.take() {
            Some(prev) => prev.backup,
            None => clip::read_text(app),
        };
        *pending = Some(PendingRestore { generation, backup });
    }

    let our_mark = clip::write_transient(app, text)?;

    // 給剪貼簿寫入落地的時間，太快送 Cmd+V 會貼到舊內容
    std::thread::sleep(Duration::from_millis(50));

    send_keys(
        app,
        vec![
            (PASTE_MODIFIER, Direction::Press),
            (Key::Unicode('v'), Direction::Click),
            (PASTE_MODIFIER, Direction::Release),
        ],
    )?;

    let app = app.clone();
    std::thread::spawn(move || {
        let start = Instant::now();
        while start.elapsed() < RESTORE_AT {
            std::thread::sleep(RESTORE_POLL);
            // 使用者（或別的程式）在這期間改了剪貼簿 → 不還原，也不再管這份備份
            if !clip::still_ours(&app, &our_mark) {
                discard_pending(generation);
                return;
            }
        }
        debug_assert!(start.elapsed() >= RESTORE_MIN_WAIT);
        let backup = {
            let mut pending = PENDING_RESTORE.lock().unwrap_or_else(|e| e.into_inner());
            match pending.as_ref() {
                // 已有更新的貼上接手這份備份，由它負責還原
                Some(p) if p.generation != generation => return,
                None => return,
                Some(_) => pending.take().and_then(|p| p.backup),
            }
        };
        if !clip::still_ours(&app, &our_mark) {
            return;
        }
        // 原本不是文字（圖片等）或是空的：無法以文字還原，保留注入內容（已標 transient）
        if let Some(backup) = backup {
            let _ = clip::write_transient(&app, &backup);
        }
    });

    Ok(())
}

fn discard_pending(generation: u64) {
    let mut pending = PENDING_RESTORE.lock().unwrap_or_else(|e| e.into_inner());
    if pending.as_ref().map(|p| p.generation) == Some(generation) {
        *pending = None;
    }
}

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
    app: &AppHandle,
    text: &str,
    generation: u64,
    expected: Option<&str>,
    newline_with_shift: bool,
) -> Result<(), String> {
    // 沒給 expected 時以開始輸入當下的前景 App 為準，中途換了一樣停
    let baseline = match expected {
        Some(e) if !e.trim().is_empty() => e.to_string(),
        _ => query_foreground(app).bundle_id,
    };
    for (index, chunk) in keypress_chunks(text, KEYPRESS_CHUNK_CHARS).into_iter().enumerate() {
        if TYPING_GENERATION.load(Ordering::SeqCst) != generation {
            return Err("cancelled".into());
        }
        if index > 0 && !foreground_matches(&baseline, &query_foreground(app)) {
            return Err("foreground-changed".into());
        }
        match chunk {
            KeypressChunk::Newline if newline_with_shift => send_keys(
                app,
                vec![
                    (Key::Shift, Direction::Press),
                    (Key::Return, Direction::Click),
                    (Key::Shift, Direction::Release),
                ],
            )?,
            KeypressChunk::Newline => send_keys(app, vec![(Key::Return, Direction::Click)])?,
            KeypressChunk::Text(s) => run_enigo_blocking(app, move |enigo| {
                let _ = enigo.text(&s);
            })?,
        }
        std::thread::sleep(KEYPRESS_INTERVAL);
    }
    Ok(())
}

fn send_keys(app: &AppHandle, keys: Vec<(Key, Direction)>) -> Result<(), String> {
    run_enigo_blocking(app, move |enigo| {
        for (key, dir) in keys {
            let _ = enigo.key(key, dir);
        }
    })
}

/// 在主執行緒上執行 enigo 操作並等它做完（最多 2s），確保段落依序送出。
fn run_enigo_blocking<F>(app: &AppHandle, f: F) -> Result<(), String>
where
    F: FnOnce(&mut Enigo) + Send + 'static,
{
    let (tx, rx) = mpsc::channel::<()>();
    app.run_on_main_thread(move || {
        if let Ok(mut enigo) = Enigo::new(&Settings::default()) {
            f(&mut enigo);
        }
        let _ = tx.send(());
    })
    .map_err(|e| e.to_string())?;
    rx.recv_timeout(Duration::from_secs(2))
        .map_err(|_| "key-simulation-timeout".to_string())
}

/// 剪貼簿存取。macOS 直接用 NSPasteboard，才能標 `org.nspasteboard.TransientType`
/// 並用 changeCount 判斷剪貼簿有沒有被別人動過；其他平台走 Tauri clipboard plugin
/// （Windows/Linux 沒有對應慣例，transient 標記略過），以內容比對代替 changeCount。
mod clip {
    use tauri::AppHandle;

    #[cfg(target_os = "macos")]
    pub(super) type Mark = isize;
    #[cfg(not(target_os = "macos"))]
    pub(super) type Mark = String;

    #[cfg(target_os = "macos")]
    mod mac {
        use objc2::rc::{autoreleasepool, Retained};
        use objc2::runtime::{AnyObject, Bool};
        use objc2::{class, msg_send};
        use objc2_foundation::NSString;

        const STRING_TYPE: &str = "public.utf8-plain-text";
        const TRANSIENT_TYPE: &str = "org.nspasteboard.TransientType";

        fn general() -> Option<Retained<AnyObject>> {
            unsafe { msg_send![class!(NSPasteboard), generalPasteboard] }
        }

        pub fn read_text() -> Option<String> {
            autoreleasepool(|_| {
                let pb = general()?;
                let ty = NSString::from_str(STRING_TYPE);
                let s: Option<Retained<NSString>> = unsafe { msg_send![&*pb, stringForType: &*ty] };
                s.map(|s| s.to_string())
            })
        }

        /// 清空並寫入文字＋TransientType，回傳寫入後的 changeCount。
        pub fn write_transient(text: &str) -> Result<isize, String> {
            autoreleasepool(|_| {
                let pb = general().ok_or("NSPasteboard unavailable")?;
                let value = NSString::from_str(text);
                let ty = NSString::from_str(STRING_TYPE);
                let transient = NSString::from_str(TRANSIENT_TYPE);
                let empty = NSString::from_str("");
                unsafe {
                    let _: isize = msg_send![&*pb, clearContents];
                    let ok: Bool = msg_send![&*pb, setString: &*value, forType: &*ty];
                    if !ok.as_bool() {
                        return Err("NSPasteboard setString failed".to_string());
                    }
                    let _: Bool = msg_send![&*pb, setString: &*empty, forType: &*transient];
                    Ok(msg_send![&*pb, changeCount])
                }
            })
        }

        pub fn change_count() -> isize {
            autoreleasepool(|_| match general() {
                Some(pb) => unsafe { msg_send![&*pb, changeCount] },
                None => -1,
            })
        }
    }

    pub(super) fn read_text(_app: &AppHandle) -> Option<String> {
        #[cfg(target_os = "macos")]
        {
            mac::read_text()
        }
        #[cfg(not(target_os = "macos"))]
        {
            use tauri_plugin_clipboard_manager::ClipboardExt;
            _app.clipboard().read_text().ok()
        }
    }

    pub(super) fn write_transient(_app: &AppHandle, text: &str) -> Result<Mark, String> {
        #[cfg(target_os = "macos")]
        {
            mac::write_transient(text)
        }
        #[cfg(not(target_os = "macos"))]
        {
            use tauri_plugin_clipboard_manager::ClipboardExt;
            _app.clipboard()
                .write_text(text.to_string())
                .map_err(|e| e.to_string())?;
            Ok(text.to_string())
        }
    }

    pub(super) fn still_ours(_app: &AppHandle, mark: &Mark) -> bool {
        #[cfg(target_os = "macos")]
        {
            mac::change_count() == *mark
        }
        #[cfg(not(target_os = "macos"))]
        {
            use tauri_plugin_clipboard_manager::ClipboardExt;
            _app.clipboard().read_text().map(|t| &t == mark).unwrap_or(false)
        }
    }
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
}

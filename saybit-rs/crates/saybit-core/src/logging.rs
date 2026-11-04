//! JSONL 日誌（批次 C2）：記憶體 ring（給日誌頁）＋ 每日檔案（logs/saybit-YYYY-MM-DD.jsonl，保留 7 天）。
//! sensitive 內容落盤與匯出都寫 `[內容已遮罩, N 字]`。同時當 `log` crate 的 logger。
use crate::types::*;
use parking_lot::Mutex;
use std::collections::VecDeque;
use std::fs::File;
use std::io::Write;
use std::path::PathBuf;
use std::sync::OnceLock;

const MAX_ENTRIES: usize = 500;
const RETENTION_DAYS: i64 = 7;

struct FileSink {
    dir: PathBuf,
    date: String,
    file: Option<File>,
}

struct Logger {
    entries: Mutex<VecDeque<LogEntry>>,
    /// None = 尚未 init（只進記憶體，測試也走這條）
    file: Mutex<Option<FileSink>>,
}

fn logger() -> &'static Logger {
    static L: OnceLock<Logger> = OnceLock::new();
    L.get_or_init(|| Logger { entries: Mutex::new(VecDeque::with_capacity(MAX_ENTRIES)), file: Mutex::new(None) })
}

/// 開檔案輸出（`paths::logs_dir()`）、清掉 7 天前的檔案、註冊成 `log` crate 的 logger。可重複呼叫。
pub fn init() {
    let dir = crate::paths::logs_dir();
    clean_old_logs(&dir, chrono::Local::now().date_naive());
    {
        let mut f = logger().file.lock();
        if f.is_none() {
            *f = Some(FileSink { dir, date: String::new(), file: None });
        }
    }
    // set_boxed_logger 需要 log 的 std feature（workspace 沒開），用 &'static 版本
    static BRIDGE: Bridge = Bridge;
    if log::set_logger(&BRIDGE).is_ok() {
        log::set_max_level(log::LevelFilter::Info);
    }
}

pub fn log(level: LogLevel, category: &str, message: impl Into<String>) {
    append(level, category, message.into(), false);
}

/// 含轉錄 / 選取文字 / LLM 結果 / 字典內容：完整內容只進記憶體，落盤與匯出寫 `[內容已遮罩, N 字]`
pub fn log_sensitive(level: LogLevel, category: &str, message: impl Into<String>) {
    append(level, category, message.into(), true);
}

/// 最近 `limit` 筆（時間由舊到新），記憶體版保留原文給日誌頁
pub fn recent(limit: usize) -> Vec<LogEntry> {
    let e = logger().entries.lock();
    let skip = e.len().saturating_sub(limit);
    e.iter().skip(skip).cloned().collect()
}

/// 遮罩後的純文字（給匯出）
pub fn export_text() -> String {
    logger().entries.lock().iter().map(format_line).collect::<Vec<_>>().join("\n")
}

pub fn clear() {
    logger().entries.lock().clear();
}

/// 落盤 / 匯出用的訊息
pub fn redacted_message(e: &LogEntry) -> String {
    if e.sensitive {
        format!("[內容已遮罩, {} 字]", e.message.chars().count())
    } else {
        e.message.clone()
    }
}

/// `[HH:MM:SS.mmm] [LEVEL] [category] message`（已遮罩，本地時間）
pub fn format_line(e: &LogEntry) -> String {
    format!(
        "[{}] [{}] [{}] {}",
        e.timestamp.with_timezone(&chrono::Local).format("%H:%M:%S%.3f"),
        level_str(e.level),
        e.category,
        redacted_message(e)
    )
}

fn level_str(l: LogLevel) -> &'static str {
    match l {
        LogLevel::Debug => "DEBUG",
        LogLevel::Info => "INFO",
        LogLevel::Warn => "WARN",
        LogLevel::Error => "ERROR",
    }
}

/// 寫進 JSONL 的一行：message 已遮罩，絕不落盤原文
fn jsonl_line(e: &LogEntry) -> String {
    let mut disk = e.clone();
    disk.message = redacted_message(e);
    serde_json::to_string(&disk).unwrap_or_default()
}

fn append(level: LogLevel, category: &str, message: String, sensitive: bool) {
    let entry = LogEntry { timestamp: chrono::Utc::now(), level, category: category.to_string(), message, sensitive };
    if cfg!(debug_assertions) {
        eprintln!("{}", format_line(&entry));
    }
    if let Some(sink) = logger().file.lock().as_mut() {
        write_to_disk(sink, &entry);
    }
    let mut e = logger().entries.lock();
    e.push_back(entry);
    while e.len() > MAX_ENTRIES {
        e.pop_front();
    }
}

fn write_to_disk(sink: &mut FileSink, entry: &LogEntry) {
    let today = chrono::Local::now().format("%Y-%m-%d").to_string();
    if sink.date != today {
        sink.file = None;
        sink.date = today.clone();
    }
    if sink.file.is_none() {
        let path = sink.dir.join(format!("saybit-{today}.jsonl"));
        sink.file = std::fs::OpenOptions::new().create(true).append(true).open(path).ok();
    }
    if let Some(f) = sink.file.as_mut() {
        let line = jsonl_line(entry);
        if writeln!(f, "{line}").is_err() {
            sink.file = None;
        }
    }
}

/// 依檔名（saybit-YYYY-MM-DD.jsonl）判斷日期，不靠建立時間
fn clean_old_logs(dir: &std::path::Path, today: chrono::NaiveDate) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    let cutoff = today - chrono::Duration::days(RETENTION_DAYS);
    for f in rd.flatten() {
        let name = f.file_name().to_string_lossy().to_string();
        let Some(date) = name.strip_prefix("saybit-").and_then(|s| s.strip_suffix(".jsonl")) else { continue };
        if let Ok(d) = chrono::NaiveDate::parse_from_str(date, "%Y-%m-%d") {
            if d < cutoff {
                let _ = std::fs::remove_file(f.path());
            }
        }
    }
}

/// 讓其他 crate 的 `log::info!` 也進同一份日誌；第三方雜訊（HTTP / GPU / 視窗）只收 WARN 以上
struct Bridge;

const NOISY: &[&str] = &["ureq", "rustls", "wgpu", "naga", "egui", "eframe", "winit", "tungstenite", "symphonia", "cpal", "zbus", "tracing"];

impl log::Log for Bridge {
    fn enabled(&self, m: &log::Metadata) -> bool {
        let noisy = NOISY.iter().any(|p| m.target().starts_with(p));
        if noisy { m.level() <= log::Level::Warn } else { m.level() <= log::Level::Info }
    }
    fn log(&self, r: &log::Record) {
        if !self.enabled(r.metadata()) {
            return;
        }
        let level = match r.level() {
            log::Level::Error => LogLevel::Error,
            log::Level::Warn => LogLevel::Warn,
            log::Level::Info => LogLevel::Info,
            _ => LogLevel::Debug,
        };
        let target = r.target();
        let category = target.rsplit("::").next().unwrap_or(target);
        append(level, category, r.args().to_string(), false);
    }
    fn flush(&self) {
        if let Some(sink) = logger().file.lock().as_mut() {
            if let Some(f) = sink.file.as_mut() {
                let _ = f.flush();
            }
        }
    }
}

#[macro_export]
macro_rules! info { ($cat:expr, $($arg:tt)*) => { $crate::logging::log($crate::types::LogLevel::Info, $cat, format!($($arg)*)) }; }
#[macro_export]
macro_rules! warn { ($cat:expr, $($arg:tt)*) => { $crate::logging::log($crate::types::LogLevel::Warn, $cat, format!($($arg)*)) }; }
#[macro_export]
macro_rules! error { ($cat:expr, $($arg:tt)*) => { $crate::logging::log($crate::types::LogLevel::Error, $cat, format!($($arg)*)) }; }
#[macro_export]
macro_rules! debug { ($cat:expr, $($arg:tt)*) => { $crate::logging::log($crate::types::LogLevel::Debug, $cat, format!($($arg)*)) }; }

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn logging_masks_sensitive_on_disk_and_export() {
        let marker = format!("秘密內容-{}", uuid::Uuid::new_v4());
        log_sensitive(LogLevel::Info, "LLM", marker.clone());
        log(LogLevel::Info, "Test", "plain-message-xyz");
        // 記憶體保留原文
        let rec = recent(MAX_ENTRIES);
        let e = rec.iter().find(|e| e.message == marker).expect("in memory");
        assert!(e.sensitive);
        // 匯出與 JSONL 都遮罩
        let export = export_text();
        assert!(!export.contains(&marker));
        assert!(export.contains(&format!("[內容已遮罩, {} 字]", marker.chars().count())));
        assert!(export.contains("plain-message-xyz"));
        let line = jsonl_line(e);
        assert!(!line.contains(&marker));
        assert!(line.contains("內容已遮罩"));
        assert!(line.contains("\"level\":\"INFO\""));
    }

    #[test]
    fn logging_disk_and_retention() {
        let dir = std::env::temp_dir().join(format!("saybit-log-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        for name in ["saybit-2026-01-01.jsonl", "saybit-2026-01-09.jsonl", "other.txt"] {
            std::fs::write(dir.join(name), "x").unwrap();
        }
        clean_old_logs(&dir, chrono::NaiveDate::from_ymd_opt(2026, 1, 10).unwrap());
        assert!(!dir.join("saybit-2026-01-01.jsonl").exists());
        assert!(dir.join("saybit-2026-01-09.jsonl").exists());
        assert!(dir.join("other.txt").exists());

        let mut sink = FileSink { dir: dir.clone(), date: String::new(), file: None };
        let entry = LogEntry {
            timestamp: chrono::Utc::now(),
            level: LogLevel::Warn,
            category: "c".into(),
            message: "使用者說的話".into(),
            sensitive: true,
        };
        write_to_disk(&mut sink, &entry);
        drop(sink);
        let today = chrono::Local::now().format("%Y-%m-%d").to_string();
        let content = std::fs::read_to_string(dir.join(format!("saybit-{today}.jsonl"))).unwrap();
        assert!(!content.contains("使用者說的話"));
        assert!(content.contains("[內容已遮罩, 6 字]"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn logging_recent_limit() {
        for i in 0..5 {
            log(LogLevel::Debug, "Limit", format!("n{i}"));
        }
        assert!(recent(2).len() <= 2);
    }
}

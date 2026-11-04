//! 行事曆與提醒事項建立 —— macOS 專屬（EventKit；移植 saybit-desktop/src-tauri/src/eventkit.rs）。
//! Windows / Linux 沒有等價的系統服務，回 Err。
//!
//! macOS 需要 Info.plist 的 NSCalendars(Full Access)UsageDescription / NSRemindersUsageDescription，
//! 否則要求授權時系統會直接終止程序 —— 所以 bundle 沒有這些 key 時（例如 `cargo run`）一律不執行。

use crate::types::PendingAction;
use chrono::{DateTime, Local, NaiveDate, NaiveDateTime, TimeZone, Utc};

/// 沒給結束時間時的預設行程長度
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
const DEFAULT_EVENT_MINUTES: i64 = 60;

/// LLM 給的時間字串 → UTC。接受 RFC 3339（含時區）、無時區的 `YYYY-MM-DD[T ]HH:MM[:SS]`
/// （視為本地時間）與純日期（本地 09:00）。
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) fn parse_when(text: &str) -> Option<DateTime<Utc>> {
    parse_when_in(text, &Local)
}

pub(crate) fn parse_when_in<Tz: TimeZone>(text: &str, tz: &Tz) -> Option<DateTime<Utc>> {
    let s = text.trim();
    if s.is_empty() {
        return None;
    }
    if let Ok(dt) = DateTime::parse_from_rfc3339(s) {
        return Some(dt.with_timezone(&Utc));
    }
    const NAIVE: [&str; 4] = ["%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M"];
    let naive = NAIVE
        .iter()
        .find_map(|f| NaiveDateTime::parse_from_str(s, f).ok())
        .or_else(|| NaiveDate::parse_from_str(s, "%Y-%m-%d").ok().and_then(|d| d.and_hms_opt(9, 0, 0)))?;
    tz.from_local_datetime(&naive).earliest().map(|d| d.with_timezone(&Utc))
}

/// 給使用者看的確認文字
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) fn confirmation_text(action: &PendingAction, start_local: Option<String>) -> String {
    match action {
        PendingAction::CalendarEvent { title, .. } => match start_local {
            Some(when) => format!("已建立行程「{title}」（{when}）"),
            None => format!("已建立行程「{title}」"),
        },
        PendingAction::Reminder { title, .. } => match start_local {
            Some(when) => format!("已建立提醒「{title}」（{when}）"),
            None => format!("已建立提醒「{title}」"),
        },
    }
}

#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn local_label(dt: DateTime<Utc>) -> String {
    dt.with_timezone(&Local).format("%-m/%-d %H:%M").to_string()
}

#[cfg(target_os = "macos")]
mod imp {
    use super::*;
    use block2::RcBlock;
    use objc2::rc::Retained;
    use objc2::runtime::Bool;
    use objc2_event_kit::{EKEntityType, EKEvent, EKEventStore, EKReminder, EKSpan};
    use objc2_foundation::{NSBundle, NSCalendar, NSCalendarUnit, NSDate, NSError, NSString};
    use std::sync::mpsc;
    use std::time::Duration;

    fn has_info_key(keys: &[&str]) -> bool {
        let bundle = NSBundle::mainBundle();
        keys.iter().any(|k| bundle.objectForInfoDictionaryKey(&NSString::from_str(k)).is_some())
    }

    const CALENDAR_KEYS: [&str; 2] = ["NSCalendarsFullAccessUsageDescription", "NSCalendarsUsageDescription"];
    const REMINDER_KEYS: [&str; 2] = ["NSRemindersFullAccessUsageDescription", "NSRemindersUsageDescription"];

    pub fn supports_actions() -> bool {
        has_info_key(&CALENDAR_KEYS) && has_info_key(&REMINDER_KEYS)
    }

    /// 要求授權並等使用者回應（最多 60 秒）
    fn request_access(store: &EKEventStore, entity: EKEntityType) -> anyhow::Result<()> {
        let (tx, rx) = mpsc::channel::<bool>();
        let block = RcBlock::new(move |granted: Bool, _err: *mut NSError| {
            let _ = tx.send(granted.as_bool());
        });
        // binding 收裸指標；RcBlock 留在本 scope，下面的 recv_timeout 擋到 completion 回來（或逾時）
        let block_ptr: *mut block2::Block<dyn Fn(Bool, *mut NSError)> = &*block as *const _ as *mut _;
        // 刻意用 requestAccessToEntityType:completion: 而非 macOS 14 才有的 requestFullAccessToEventsWithCompletion:，
        // 後者在 13 以下是 unrecognized selector
        #[allow(deprecated)]
        // SAFETY: block 在 completion 前保持存活（見上）
        unsafe {
            store.requestAccessToEntityType_completion(entity, block_ptr);
        }
        let result = rx.recv_timeout(Duration::from_secs(60));
        // completion 可能在逾時之後才呼叫：讓 block 跟著程序活下去，避免 use-after-free
        std::mem::forget(block);
        match result {
            Ok(true) => Ok(()),
            Ok(false) => anyhow::bail!("使用者未授權存取行事曆／提醒事項"),
            Err(_) => anyhow::bail!("等待授權逾時"),
        }
    }

    fn ns_date(dt: DateTime<Utc>) -> Retained<NSDate> {
        NSDate::dateWithTimeIntervalSince1970(dt.timestamp_millis() as f64 / 1000.0)
    }

    pub fn execute(action: &PendingAction) -> anyhow::Result<String> {
        anyhow::ensure!(supports_actions(), "這個 build 沒有行事曆／提醒事項的使用說明（Info.plist），無法建立");
        match action {
            PendingAction::CalendarEvent { title, start, end, notes } => {
                let start_dt = parse_when(start).ok_or_else(|| anyhow::anyhow!("無法解析開始時間：{start}"))?;
                let end_dt = end
                    .as_deref()
                    .and_then(parse_when)
                    .filter(|e| *e > start_dt)
                    .unwrap_or(start_dt + chrono::Duration::minutes(DEFAULT_EVENT_MINUTES));

                // SAFETY: EventKit 標準建構；以下 setter 參數型別與宣告一致
                let store = unsafe { EKEventStore::new() };
                request_access(&store, EKEntityType::Event)?;
                unsafe {
                    let event = EKEvent::eventWithEventStore(&store);
                    event.setTitle(Some(&NSString::from_str(title)));
                    event.setStartDate(Some(&ns_date(start_dt)));
                    event.setEndDate(Some(&ns_date(end_dt)));
                    if let Some(n) = notes.as_deref().filter(|s| !s.is_empty()) {
                        event.setNotes(Some(&NSString::from_str(n)));
                    }
                    let calendar = store
                        .defaultCalendarForNewEvents()
                        .ok_or_else(|| anyhow::anyhow!("找不到預設行事曆"))?;
                    event.setCalendar(Some(&calendar));
                    store
                        .saveEvent_span_error(&event, EKSpan::ThisEvent)
                        .map_err(|e| anyhow::anyhow!("儲存行程失敗：{}", e.localizedDescription()))?;
                }
                Ok(confirmation_text(action, Some(local_label(start_dt))))
            }
            PendingAction::Reminder { title, due, notes } => {
                let due_dt = due.as_deref().and_then(parse_when);
                // SAFETY: 同上
                let store = unsafe { EKEventStore::new() };
                request_access(&store, EKEntityType::Reminder)?;
                unsafe {
                    let reminder = EKReminder::reminderWithEventStore(&store);
                    reminder.setTitle(Some(&NSString::from_str(title)));
                    if let Some(n) = notes.as_deref().filter(|s| !s.is_empty()) {
                        reminder.setNotes(Some(&NSString::from_str(n)));
                    }
                    if let Some(dt) = due_dt {
                        let calendar = NSCalendar::currentCalendar();
                        let units = NSCalendarUnit::Year
                            | NSCalendarUnit::Month
                            | NSCalendarUnit::Day
                            | NSCalendarUnit::Hour
                            | NSCalendarUnit::Minute;
                        let components = calendar.components_fromDate(units, &ns_date(dt));
                        reminder.setDueDateComponents(Some(&components));
                    }
                    let calendar = store
                        .defaultCalendarForNewReminders()
                        .ok_or_else(|| anyhow::anyhow!("找不到預設提醒事項清單"))?;
                    reminder.setCalendar(Some(&calendar));
                    store
                        .saveReminder_commit_error(&reminder, true)
                        .map_err(|e| anyhow::anyhow!("儲存提醒失敗：{}", e.localizedDescription()))?;
                }
                Ok(confirmation_text(action, due_dt.map(local_label)))
            }
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use super::*;

    pub fn supports_actions() -> bool {
        false
    }

    pub fn execute(_action: &PendingAction) -> anyhow::Result<String> {
        anyhow::bail!("此平台不支援")
    }
}

pub(crate) fn execute_action(action: &PendingAction) -> anyhow::Result<String> {
    imp::execute(action)
}

pub(crate) fn supports_actions() -> bool {
    imp::supports_actions()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::FixedOffset;

    #[test]
    fn parses_rfc3339_and_naive() {
        let tz = FixedOffset::east_opt(8 * 3600).unwrap();
        let want = Utc.with_ymd_and_hms(2026, 1, 29, 7, 0, 0).unwrap();
        assert_eq!(parse_when_in("2026-01-29T15:00:00+08:00", &tz), Some(want));
        assert_eq!(parse_when_in("2026-01-29T07:00:00Z", &tz), Some(want));
        assert_eq!(parse_when_in("2026-01-29T15:00:00", &tz), Some(want));
        assert_eq!(parse_when_in("2026-01-29T15:00", &tz), Some(want));
        assert_eq!(parse_when_in("2026-01-29 15:00", &tz), Some(want));
        assert_eq!(
            parse_when_in("2026-01-29", &tz),
            Some(Utc.with_ymd_and_hms(2026, 1, 29, 1, 0, 0).unwrap())
        );
        assert_eq!(parse_when_in("明天下午三點", &tz), None);
        assert_eq!(parse_when_in("  ", &tz), None);
    }

    #[test]
    fn confirmation_texts() {
        let ev = PendingAction::CalendarEvent { title: "開會".into(), start: "x".into(), end: None, notes: None };
        assert_eq!(confirmation_text(&ev, Some("1/29 15:00".into())), "已建立行程「開會」（1/29 15:00）");
        let r = PendingAction::Reminder { title: "買牛奶".into(), due: None, notes: None };
        assert_eq!(confirmation_text(&r, None), "已建立提醒「買牛奶」");
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn unsupported_off_macos() {
        assert!(!supports_actions());
        let r = PendingAction::Reminder { title: "x".into(), due: None, notes: None };
        assert!(execute_action(&r).is_err());
    }
}

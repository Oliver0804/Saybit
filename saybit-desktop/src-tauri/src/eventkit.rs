// 行事曆與提醒事項建立 —— macOS 專屬（EventKit）。
//
// 對應原生版 Core/EventKit/EventKitManager.swift。Windows / Linux 沒有等價的系統
// 服務，該平台的 command 直接回錯誤，前端收到後會降級成一般語音聽寫。
//
// macOS 需要 Info.plist 的 NSCalendarsUsageDescription / NSRemindersUsageDescription，
// 否則要求授權時會直接被系統終止程序。

#[cfg(target_os = "macos")]
mod imp {
    use block2::RcBlock;
    use objc2::rc::Retained;
    use objc2::runtime::Bool;
    use objc2_event_kit::{EKEntityType, EKEvent, EKEventStore, EKReminder, EKSpan};
    use objc2_foundation::{
        NSCalendar, NSCalendarUnit, NSDate, NSISO8601DateFormatter,
        NSISO8601DateFormatOptions, NSString,
    };
    use std::sync::mpsc;
    use std::time::Duration;

    /// 要求授權並等待使用者回應（最多 60 秒，涵蓋使用者慢慢看對話框的情況）。
    fn request_access(store: &EKEventStore, entity: EKEntityType) -> Result<(), String> {
        let (tx, rx) = mpsc::channel::<bool>();
        let block = RcBlock::new(move |granted: Bool, _err: *mut objc2_foundation::NSError| {
            let _ = tx.send(granted.as_bool());
        });

        // 這支 API 的 binding 收的是裸指標，RcBlock 的所有權留在本函式的 scope 內，
        // 而下面的 recv_timeout 會擋到 completion 回來為止，所以指標在使用期間有效。
        let block_ptr: *mut block2::Block<dyn Fn(Bool, *mut objc2_foundation::NSError)> =
            &*block as *const _ as *mut _;

        // 刻意用 requestAccessToEntityType:completion: 而非 macOS 14 才有的
        // requestFullAccessToEventsWithCompletion:。後者在 13 以下是 unrecognized
        // selector，會直接讓 app 崩潰；舊 API 則在所有支援版本上都可用。
        #[allow(deprecated)]
        unsafe {
            store.requestAccessToEntityType_completion(entity, block_ptr);
        }

        match rx.recv_timeout(Duration::from_secs(60)) {
            Ok(true) => Ok(()),
            Ok(false) => Err("使用者未授權存取行事曆／提醒事項".into()),
            Err(_) => Err("等待授權逾時".into()),
        }
    }

    /// 解析帶時區位移的 ISO 8601 字串（例如 2026-01-29T15:00:00+08:00）。
    fn parse_iso8601(text: &str) -> Option<Retained<NSDate>> {
        let formatter = NSISO8601DateFormatter::new();
        formatter.setFormatOptions(NSISO8601DateFormatOptions::WithInternetDateTime);
        let ns = NSString::from_str(text);
        formatter.dateFromString(&ns)
    }

    pub fn create_event(
        title: &str,
        start_iso: &str,
        duration_minutes: i64,
        location: Option<&str>,
        notes: Option<&str>,
    ) -> Result<(), String> {
        let store = unsafe { EKEventStore::new() };
        request_access(&store, EKEntityType::Event)?;

        let start = parse_iso8601(start_iso)
            .ok_or_else(|| format!("無法解析開始時間：{start_iso}"))?;
        let end =
            NSDate::dateWithTimeInterval_sinceDate((duration_minutes.max(1) * 60) as f64, &start);

        let event = unsafe { EKEvent::eventWithEventStore(&store) };
        unsafe {
            event.setTitle(Some(&NSString::from_str(title)));
            event.setStartDate(Some(&start));
            event.setEndDate(Some(&end));
            if let Some(loc) = location.filter(|s| !s.is_empty()) {
                event.setLocation(Some(&NSString::from_str(loc)));
            }
            if let Some(n) = notes.filter(|s| !s.is_empty()) {
                event.setNotes(Some(&NSString::from_str(n)));
            }
            let calendar = store
                .defaultCalendarForNewEvents()
                .ok_or("找不到預設行事曆")?;
            event.setCalendar(Some(&calendar));

            store
                .saveEvent_span_error(&event, EKSpan::ThisEvent)
                .map_err(|e| format!("儲存行程失敗：{e:?}"))
        }
    }

    pub fn create_reminder(
        title: &str,
        due_iso: Option<&str>,
        notes: Option<&str>,
    ) -> Result<(), String> {
        let store = unsafe { EKEventStore::new() };
        request_access(&store, EKEntityType::Reminder)?;

        let reminder = unsafe { EKReminder::reminderWithEventStore(&store) };
        unsafe {
            reminder.setTitle(Some(&NSString::from_str(title)));
            if let Some(n) = notes.filter(|s| !s.is_empty()) {
                reminder.setNotes(Some(&NSString::from_str(n)));
            }

            if let Some(due) = due_iso.filter(|s| !s.is_empty()) {
                if let Some(date) = parse_iso8601(due) {
                    let calendar = NSCalendar::currentCalendar();
                    let units = NSCalendarUnit::Year
                        | NSCalendarUnit::Month
                        | NSCalendarUnit::Day
                        | NSCalendarUnit::Hour
                        | NSCalendarUnit::Minute;
                    let components = calendar.components_fromDate(units, &date);
                    reminder.setDueDateComponents(Some(&components));
                }
            }

            let calendar = store
                .defaultCalendarForNewReminders()
                .ok_or("找不到預設提醒事項清單")?;
            reminder.setCalendar(Some(&calendar));

            store
                .saveReminder_commit_error(&reminder, true)
                .map_err(|e| format!("儲存提醒失敗：{e:?}"))
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    const UNSUPPORTED: &str = "此平台不支援建立行事曆／提醒事項";

    pub fn create_event(
        _title: &str,
        _start_iso: &str,
        _duration_minutes: i64,
        _location: Option<&str>,
        _notes: Option<&str>,
    ) -> Result<(), String> {
        Err(UNSUPPORTED.into())
    }

    pub fn create_reminder(
        _title: &str,
        _due_iso: Option<&str>,
        _notes: Option<&str>,
    ) -> Result<(), String> {
        Err(UNSUPPORTED.into())
    }
}

/// 這個平台是否支援行事曆／提醒事項意圖。前端拿它決定要不要顯示相關設定。
#[tauri::command]
pub fn action_intents_supported() -> bool {
    cfg!(target_os = "macos")
}

#[tauri::command]
pub fn create_calendar_event(
    title: String,
    start_iso: String,
    duration_minutes: Option<i64>,
    location: Option<String>,
    notes: Option<String>,
) -> Result<(), String> {
    imp::create_event(
        &title,
        &start_iso,
        duration_minutes.unwrap_or(60),
        location.as_deref(),
        notes.as_deref(),
    )
}

#[tauri::command]
pub fn create_reminder(
    title: String,
    due_iso: Option<String>,
    notes: Option<String>,
) -> Result<(), String> {
    imp::create_reminder(&title, due_iso.as_deref(), notes.as_deref())
}

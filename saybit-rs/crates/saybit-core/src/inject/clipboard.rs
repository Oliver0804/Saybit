//! 剪貼簿存取（注入與選取文字 fallback 共用）。
//!
//! macOS 直接用 NSPasteboard：才能標 `org.nspasteboard.TransientType`、用 changeCount 判斷
//! 剪貼簿有沒有被別人動過，並完整備份所有 item 的所有型別（移植 ClipboardBackup.swift）。
//! Windows / Linux 走 arboard：備份文字（沒有文字時備份圖片），以內容比對代替 changeCount，
//! 寫入時標 exclude_from_history（Windows Win+V 歷史 / Linux 剪貼簿管理器）。

/// 檔案承諾（promise）類型：讀取會要求來源 App 同步產生檔案，可能卡住或產生大檔，不備份。
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
const SKIPPED_TYPES: [&str; 6] = [
    "com.apple.NSFilePromiseItemMetaData",
    "com.apple.pasteboard.promised-file-url",
    "com.apple.pasteboard.promised-file-content-type",
    "com.apple.pasteboard.promised-suggested-file-name",
    "NSPromiseContentsPboardType",
    "Apple files promise pasteboard type",
];

/// 快照總大小上限
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
const MAX_SNAPSHOT_BYTES: usize = 32 * 1024 * 1024;

#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) fn should_backup_type(ty: &str) -> bool {
    !SKIPPED_TYPES.contains(&ty)
}

/// 已備份 `total` bytes 時，這份 `len` bytes 的資料還能不能放進快照
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) fn fits_snapshot(total: usize, len: usize) -> bool {
    total.saturating_add(len) <= MAX_SNAPSHOT_BYTES
}

#[cfg(target_os = "macos")]
mod imp {
    use objc2::rc::{autoreleasepool, Retained};
    use objc2::runtime::ProtocolObject;
    use objc2_app_kit::{NSPasteboard, NSPasteboardItem, NSPasteboardWriting};
    use objc2_foundation::{NSArray, NSData, NSString};

    const STRING_TYPE: &str = "public.utf8-plain-text";
    const TRANSIENT_TYPE: &str = "org.nspasteboard.TransientType";

    /// changeCount
    pub type Mark = isize;

    /// 每個 item 一組 (型別, 資料)
    #[derive(Debug, Clone, Default)]
    pub struct Snapshot(Vec<Vec<(String, Vec<u8>)>>);

    fn general() -> Retained<NSPasteboard> {
        NSPasteboard::generalPasteboard()
    }

    pub fn read_text() -> Option<String> {
        autoreleasepool(|_| {
            let ty = NSString::from_str(STRING_TYPE);
            general().stringForType(&ty).map(|s| s.to_string())
        })
    }

    pub fn change_count() -> Mark {
        general().changeCount()
    }

    pub fn snapshot() -> Snapshot {
        autoreleasepool(|_| {
            let pb = general();
            let mut total = 0usize;
            let mut out = Vec::new();
            let Some(items) = pb.pasteboardItems() else { return Snapshot::default() };
            for item in items.iter() {
                let mut entries = Vec::new();
                for ty in item.types().iter() {
                    let name = ty.to_string();
                    if !super::should_backup_type(&name) {
                        continue;
                    }
                    if total >= super::MAX_SNAPSHOT_BYTES {
                        break;
                    }
                    if let Some(data) = item.dataForType(&ty) {
                        let bytes = data.to_vec();
                        if !super::fits_snapshot(total, bytes.len()) {
                            continue;
                        }
                        total += bytes.len();
                        entries.push((name, bytes));
                    }
                }
                out.push(entries);
            }
            Snapshot(out)
        })
    }

    /// 清空後寫回快照（標 TransientType）；快照為空就只清空。
    pub fn restore(snapshot: &Snapshot) {
        autoreleasepool(|_| {
            let pb = general();
            pb.clearContents();
            let transient = NSString::from_str(TRANSIENT_TYPE);
            let empty = NSData::new();
            let items: Vec<Retained<ProtocolObject<dyn NSPasteboardWriting>>> = snapshot
                .0
                .iter()
                .filter(|entries| !entries.is_empty())
                .map(|entries| {
                    let item = NSPasteboardItem::new();
                    for (ty, bytes) in entries {
                        let ty = NSString::from_str(ty);
                        let data = NSData::with_bytes(bytes);
                        item.setData_forType(&data, &ty);
                    }
                    item.setData_forType(&empty, &transient);
                    ProtocolObject::from_retained(item)
                })
                .collect();
            if items.is_empty() {
                return;
            }
            let array = NSArray::from_retained_slice(&items);
            pb.writeObjects(&array);
        })
    }

    /// 清空並寫入文字＋TransientType，回傳寫入後的 changeCount。
    pub fn write_transient(text: &str) -> Result<Mark, String> {
        autoreleasepool(|_| {
            let pb = general();
            let value = NSString::from_str(text);
            let ty = NSString::from_str(STRING_TYPE);
            let transient = NSString::from_str(TRANSIENT_TYPE);
            pb.clearContents();
            if !pb.setString_forType(&value, &ty) {
                return Err("NSPasteboard setString failed".to_string());
            }
            pb.setData_forType(Some(&NSData::new()), &transient);
            Ok(pb.changeCount())
        })
    }

    pub fn still_ours(mark: &Mark) -> bool {
        change_count() == *mark
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use parking_lot::Mutex;

    /// 寫入的內容本身（以內容比對判斷剪貼簿是否還是我們的）
    pub type Mark = String;

    #[derive(Debug, Clone, Default)]
    pub enum Snapshot {
        Text(String),
        Image(arboard::ImageData<'static>),
        #[default]
        Empty,
    }

    // Linux 的 X11 / Wayland 剪貼簿由「擁有者程序」提供內容，Clipboard 物件 drop 後內容就消失，
    // 所以整個程序共用一個長壽的實例。
    static CLIPBOARD: Mutex<Option<arboard::Clipboard>> = Mutex::new(None);

    fn with<T>(f: impl FnOnce(&mut arboard::Clipboard) -> Result<T, arboard::Error>) -> Result<T, String> {
        let mut guard = CLIPBOARD.lock();
        if guard.is_none() {
            *guard = Some(arboard::Clipboard::new().map_err(|e| e.to_string())?);
        }
        let cb = guard.as_mut().expect("clipboard initialised above");
        f(cb).map_err(|e| e.to_string())
    }

    pub fn read_text() -> Option<String> {
        with(|cb| cb.get_text()).ok()
    }

    pub fn snapshot() -> Snapshot {
        if let Some(t) = read_text() {
            return Snapshot::Text(t);
        }
        match with(|cb| cb.get_image()) {
            Ok(img) => Snapshot::Image(img.to_owned_img()),
            Err(_) => Snapshot::Empty,
        }
    }

    fn set_text_excluded(text: &str) -> Result<(), String> {
        with(|cb| {
            let set = cb.set();
            #[cfg(target_os = "windows")]
            let set = {
                use arboard::SetExtWindows;
                set.exclude_from_history().exclude_from_cloud()
            };
            #[cfg(target_os = "linux")]
            let set = {
                use arboard::SetExtLinux;
                set.exclude_from_history()
            };
            set.text(text.to_string())
        })
    }

    pub fn restore(snapshot: &Snapshot) {
        let _ = match snapshot {
            Snapshot::Text(t) => set_text_excluded(t),
            Snapshot::Image(img) => with(|cb| cb.set_image(img.clone())),
            Snapshot::Empty => with(|cb| cb.clear()),
        };
    }

    pub fn write_transient(text: &str) -> Result<Mark, String> {
        set_text_excluded(text)?;
        Ok(text.to_string())
    }

    pub fn still_ours(mark: &Mark) -> bool {
        read_text().map(|t| &t == mark).unwrap_or(false)
    }
}

pub(crate) use imp::*;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn skips_file_promise_types() {
        assert!(should_backup_type("public.utf8-plain-text"));
        assert!(should_backup_type("public.png"));
        assert!(!should_backup_type("com.apple.pasteboard.promised-file-url"));
        assert!(!should_backup_type("NSPromiseContentsPboardType"));
    }

    #[test]
    fn snapshot_size_cap() {
        assert!(fits_snapshot(0, 10));
        assert!(fits_snapshot(MAX_SNAPSHOT_BYTES - 10, 10));
        assert!(!fits_snapshot(MAX_SNAPSHOT_BYTES - 10, 11));
        assert!(!fits_snapshot(usize::MAX, 1));
    }
}

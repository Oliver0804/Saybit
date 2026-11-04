//! saybit:// 註冊與單一實例（批次 C3）。
//! 註冊：Windows HKCU\Software\Classes\saybit；Linux ~/.local/share/applications/saybit.desktop 的 MimeType=x-scheme-handler/saybit + update-desktop-database；macOS 由 bundle Info.plist CFBundleURLTypes（打包時）。
//! 單一實例：本機 socket / named pipe；第二個實例把 argv 裡的 URL 轉給主實例後結束。

use crate::types::*;
use parking_lot::Mutex;
use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

const URL_COMMANDS: [&str; 5] = ["toggle", "start", "stop", "cancel", "settings"];
const URL_DEDUP_WINDOW: Duration = Duration::from_secs(1);
/// 單一實例 socket 一次最多收多少 bytes（防本機其他程序塞爆）
const MAX_MESSAGE_BYTES: u64 = 64 * 1024;

/// `saybit://toggle|start|stop|cancel|settings[?mode=Name][&tab=…]`，
/// 指令放 host 或 path 都接受（`saybit:toggle`、`saybit:///toggle`）。不認得的指令回 None。
pub fn parse(url: &str) -> Option<UrlCommand> {
    let url = url::Url::parse(url.trim()).ok()?;
    if !url.scheme().eq_ignore_ascii_case("saybit") {
        return None;
    }
    let host = url.host_str().unwrap_or("");
    let command = if host.is_empty() {
        url.path().trim_matches('/').split('/').next().unwrap_or("").to_string()
    } else {
        host.to_string()
    }
    .to_ascii_lowercase();
    if !URL_COMMANDS.contains(&command.as_str()) {
        return None;
    }
    let query = |name: &str| {
        url.query_pairs()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.trim().to_string())
            .filter(|v| !v.is_empty())
    };
    Some(UrlCommand { command, mode: query("mode"), tab: query("tab") })
}

/// 同一 URL 在 1 秒內重複就丟棄（launcher 重送、冷啟動 argv 與 socket 各送一次）。以最後一次「接受」為準。
#[derive(Default)]
pub struct UrlDeduper {
    last: HashMap<String, Instant>,
}

impl UrlDeduper {
    pub fn accept(&mut self, raw_url: &str, now: Instant) -> bool {
        let key = raw_url.trim().to_ascii_lowercase();
        self.last.retain(|_, t| now.saturating_duration_since(*t) < Duration::from_secs(10));
        if let Some(t) = self.last.get(&key) {
            if now.saturating_duration_since(*t) < URL_DEDUP_WINDOW {
                return false;
            }
        }
        self.last.insert(key, now);
        true
    }
}

/// 全域去重：GUI 收到 URL（argv、socket、macOS open URL 事件）時先問這個，false 就丟棄
pub fn accept_url(raw_url: &str) -> bool {
    static D: OnceLock<Mutex<UrlDeduper>> = OnceLock::new();
    D.get_or_init(|| Mutex::new(UrlDeduper::default())).lock().accept(raw_url, Instant::now())
}

// ───────────────────────────── 註冊 scheme ─────────────────────────────

/// Linux `.desktop`（scheme handler）
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub(crate) fn scheme_desktop_entry(exe: &str) -> String {
    format!(
        "[Desktop Entry]\nType=Application\nName=Saybit\nExec={} %u\nTerminal=false\nMimeType=x-scheme-handler/saybit;\nCategories=Utility;\n",
        crate::platform::desktop_exec_quote(exe)
    )
}

/// Windows `HKCU\Software\Classes\saybit\shell\open\command` 的值
#[cfg_attr(not(target_os = "windows"), allow(dead_code))]
pub(crate) fn windows_open_command(exe: &str) -> String {
    format!("\"{exe}\" \"%1\"")
}

pub fn register_scheme() -> anyhow::Result<()> {
    #[cfg(target_os = "macos")]
    {
        log::info!("saybit:// 在 macOS 由 bundle Info.plist（CFBundleURLTypes）註冊，略過");
        Ok(())
    }
    #[cfg(target_os = "windows")]
    {
        win::register(&std::env::current_exe()?.to_string_lossy())
    }
    #[cfg(target_os = "linux")]
    {
        linux_register()
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
    {
        anyhow::bail!("此平台不支援註冊 URL scheme")
    }
}

#[cfg(target_os = "linux")]
fn linux_register() -> anyhow::Result<()> {
    use std::process::{Command, Stdio};
    let exe = std::env::current_exe()?;
    let base = std::env::var_os("XDG_DATA_HOME")
        .map(std::path::PathBuf::from)
        .filter(|p| p.is_absolute())
        .or_else(|| std::env::var_os("HOME").map(|h| std::path::PathBuf::from(h).join(".local/share")))
        .ok_or_else(|| anyhow::anyhow!("找不到 HOME"))?;
    let dir = base.join("applications");
    std::fs::create_dir_all(&dir)?;
    std::fs::write(dir.join("saybit.desktop"), scheme_desktop_entry(&exe.to_string_lossy()))?;
    // 兩個工具都是盡力而為：沒裝也不算失敗
    let _ = Command::new("xdg-mime")
        .args(["default", "saybit.desktop", "x-scheme-handler/saybit"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    let _ = Command::new("update-desktop-database").arg(&dir).stdout(Stdio::null()).stderr(Stdio::null()).status();
    Ok(())
}

#[cfg(target_os = "windows")]
mod win {
    use windows::core::HSTRING;
    use windows::Win32::System::Registry::{
        RegCloseKey, RegCreateKeyExW, RegSetValueExW, HKEY, HKEY_CURRENT_USER, KEY_WRITE, REG_OPTION_NON_VOLATILE,
        REG_SZ,
    };

    fn set_string(key: HKEY, name: Option<&str>, value: &str) -> anyhow::Result<()> {
        let wide: Vec<u16> = value.encode_utf16().chain(std::iter::once(0)).collect();
        // SAFETY: REG_SZ 資料是含結尾 NUL 的 UTF-16 bytes
        let bytes = unsafe { std::slice::from_raw_parts(wide.as_ptr() as *const u8, wide.len() * 2) };
        let name = name.map(HSTRING::from).unwrap_or_default();
        // SAFETY: key 有效；name / bytes 在呼叫期間存活
        let status = unsafe { RegSetValueExW(key, &name, Some(0), REG_SZ, Some(bytes)) };
        anyhow::ensure!(status.is_ok(), "RegSetValueExW 失敗 ({status:?})");
        Ok(())
    }

    fn with_key(path: &str, f: impl FnOnce(HKEY) -> anyhow::Result<()>) -> anyhow::Result<()> {
        let mut key = HKEY::default();
        // SAFETY: key 是區域變數，用完 RegCloseKey
        let status = unsafe {
            RegCreateKeyExW(
                HKEY_CURRENT_USER,
                &HSTRING::from(path),
                Some(0),
                None,
                REG_OPTION_NON_VOLATILE,
                KEY_WRITE,
                None,
                &mut key,
                None,
            )
        };
        anyhow::ensure!(status.is_ok(), "RegCreateKeyExW {path} 失敗 ({status:?})");
        let result = f(key);
        // SAFETY: 同上
        unsafe {
            let _ = RegCloseKey(key);
        }
        result
    }

    pub fn register(exe: &str) -> anyhow::Result<()> {
        with_key(r"Software\Classes\saybit", |k| {
            set_string(k, None, "URL:Saybit Protocol")?;
            set_string(k, Some("URL Protocol"), "")
        })?;
        with_key(r"Software\Classes\saybit\shell\open\command", |k| {
            set_string(k, None, &super::windows_open_command(exe))
        })
    }
}

// ───────────────────────────── 單一實例 ─────────────────────────────

pub enum InstanceRole {
    /// 我是主實例；之後的 URL 透過 on_url 進來
    Primary,
    /// 已有主實例，argv 已轉送，呼叫端應結束程式
    Secondary,
}

/// socket 名稱含使用者名（同一台機器不同使用者各自一個實例），只留安全字元
pub(crate) fn socket_name_for(user: &str) -> String {
    let user: String = user
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '_' })
        .take(64)
        .collect();
    let user = if user.is_empty() { "default".to_string() } else { user };
    format!("com.bashcat.saybit.{user}.sock")
}

fn current_user() -> String {
    std::env::var("USER").or_else(|_| std::env::var("USERNAME")).unwrap_or_default()
}

/// 主實例收到的訊息：一行一個 URL，只轉送 `parse` 認得的
pub(crate) fn urls_from_message(msg: &str) -> Vec<String> {
    msg.lines().map(str::trim).filter(|l| parse(l).is_some()).map(str::to_string).collect()
}

fn make_name(raw: &str) -> std::io::Result<interprocess::local_socket::Name<'static>> {
    use interprocess::local_socket::{GenericFilePath, GenericNamespaced, NameType, ToFsName, ToNsName};
    if GenericNamespaced::is_supported() {
        raw.to_string().to_ns_name::<GenericNamespaced>()
    } else {
        // macOS 沒有 abstract namespace：放在使用者自己的 $TMPDIR
        std::env::temp_dir().join(raw).to_fs_name::<GenericFilePath>()
    }
}

/// 取得單一實例身分。Primary：之後（以及 argv 裡）的 saybit:// URL 都會在背景執行緒呼叫 `on_url`
/// （GUI 應把它丟進自己的佇列並 repaint，並先用 `accept_url` 去重）。Secondary：argv URL 已轉給主實例。
pub fn acquire_single_instance(argv_urls: Vec<String>, on_url: Box<dyn Fn(String) + Send + Sync>) -> InstanceRole {
    acquire_with_name(&socket_name_for(&current_user()), argv_urls, on_url)
}

fn send_to_primary(name: &str, urls: &[String]) -> std::io::Result<()> {
    use interprocess::local_socket::{traits::Stream as _, Stream};
    let mut conn = Stream::connect(make_name(name)?)?;
    let mut msg = String::new();
    for u in urls {
        msg.push_str(u.trim());
        msg.push('\n');
    }
    conn.write_all(msg.as_bytes())?;
    conn.flush()
}

pub(crate) fn acquire_with_name(
    name: &str,
    argv_urls: Vec<String>,
    on_url: Box<dyn Fn(String) + Send + Sync>,
) -> InstanceRole {
    use interprocess::local_socket::{traits::ListenerExt as _, ListenerOptions};

    // 1. 先試著連既有的主實例
    if send_to_primary(name, &argv_urls).is_ok() {
        log::info!("已有 Saybit 在執行，轉送 {} 個 URL 後結束", argv_urls.len());
        return InstanceRole::Secondary;
    }

    // 2. 連不上：自己當主實例。Unix 上殘留的 socket 檔（上次當掉）由 try_overwrite 清掉
    let listener = make_name(name).and_then(|n| {
        ListenerOptions::new()
            .name(n)
            .try_overwrite(true)
            .max_spin_time(Duration::from_millis(500))
            .create_sync()
    });
    let listener = match listener {
        Ok(l) => Some(l),
        Err(e) if e.kind() == std::io::ErrorKind::AddrInUse => {
            // 同時啟動的另一個程序剛搶到（Windows named pipe）：再試一次轉送
            if send_to_primary(name, &argv_urls).is_ok() {
                return InstanceRole::Secondary;
            }
            log::warn!("單一實例 socket 被占用且連不上: {e}");
            None
        }
        Err(e) => {
            log::warn!("無法建立單一實例 socket，之後的 URL 收不到: {e}");
            None
        }
    };

    let on_url: std::sync::Arc<dyn Fn(String) + Send + Sync> = std::sync::Arc::from(on_url);
    set_url_sink(on_url.clone());
    let first = on_url.clone();
    let argv: Vec<String> = argv_urls.into_iter().map(|u| u.trim().to_string()).filter(|u| parse(u).is_some()).collect();
    std::thread::Builder::new()
        .name("saybit-single-instance".into())
        .spawn(move || {
            for u in argv {
                first(u);
            }
            let Some(listener) = listener else { return };
            for conn in listener.incoming() {
                let Ok(conn) = conn else { continue };
                let on_url = on_url.clone();
                // 每條連線自己的執行緒：卡住不送 EOF 的連線不會擋住後面的
                let _ = std::thread::Builder::new().name("saybit-single-instance-conn".into()).spawn(move || {
                    let mut msg = String::new();
                    if conn.take(MAX_MESSAGE_BYTES).read_to_string(&mut msg).is_ok() {
                        for u in urls_from_message(&msg) {
                            on_url(u);
                        }
                    }
                });
            }
        })
        .ok();
    InstanceRole::Primary
}

// ───────────────────────────── macOS Apple Event（kAEGetURL） ─────────────────────────────

type UrlSink = std::sync::Arc<dyn Fn(String) + Send + Sync>;

/// Primary 登記的 on_url；登記前收到的 URL（Apple Event 可能比較早到）先排隊，登記時一次送出
#[derive(Default)]
struct UrlRouter {
    sink: Option<UrlSink>,
    pending: Vec<String>,
}

static URL_ROUTER: Mutex<UrlRouter> = Mutex::new(UrlRouter { sink: None, pending: Vec::new() });

fn set_url_sink(sink: UrlSink) {
    let pending = {
        let mut r = URL_ROUTER.lock();
        r.sink = Some(sink.clone());
        std::mem::take(&mut r.pending)
    };
    for u in pending {
        sink(u);
    }
}

/// 外部來源（macOS Apple Event）收到的 URL：只轉送 `parse` 認得的；還沒有 on_url 就排隊（最多 16 筆）
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) fn route_url(raw: &str) {
    let raw = raw.trim();
    if parse(raw).is_none() {
        log::info!("deep link: 不支援的 URL，忽略");
        return;
    }
    let sink = {
        let mut r = URL_ROUTER.lock();
        match r.sink.clone() {
            Some(s) => s,
            None => {
                if r.pending.len() < 16 {
                    r.pending.push(raw.to_string());
                }
                return;
            }
        }
    };
    sink(raw.to_string());
}

/// macOS：App 已在執行時 LaunchServices 用 Apple Event（kInternetEventClass / kAEGetURL）交付 `saybit://`，
/// 不會開新程序，所以 socket 收不到。這裡向 NSAppleEventManager 登記 handler，把 URL 轉給
/// `acquire_single_instance` 登記的 `on_url`（之前收到的會排隊）。
///
/// 必須在**主執行緒**呼叫，且只呼叫一次；越早越好（NSApplication 開始跑事件迴圈前最好，
/// 否則冷啟動那一次的 URL 事件可能在 handler 登記前就被 AppKit 丟掉）。其他平台 no-op。
pub fn install_apple_event_handler() {
    #[cfg(target_os = "macos")]
    apple_event::install();
}

#[cfg(target_os = "macos")]
mod apple_event {
    use objc2::rc::Retained;
    use objc2::runtime::{AnyObject, NSObject};
    use objc2::{class, define_class, msg_send, sel, AllocAnyThread};

    const fn fourcc(s: &[u8; 4]) -> u32 {
        ((s[0] as u32) << 24) | ((s[1] as u32) << 16) | ((s[2] as u32) << 8) | (s[3] as u32)
    }
    /// kInternetEventClass / kAEGetURL 都是 'GURL'
    const K_INTERNET_EVENT_CLASS: u32 = fourcc(b"GURL");
    const K_AE_GET_URL: u32 = fourcc(b"GURL");
    /// keyDirectObject
    const KEY_DIRECT_OBJECT: u32 = fourcc(b"----");

    define_class!(
        // SAFETY: NSObject 沒有子類別要求；沒有實作 Drop
        #[unsafe(super(NSObject))]
        #[name = "SaybitURLEventHandler"]
        struct UrlEventHandler;

        impl UrlEventHandler {
            // SAFETY: 簽章符合 NSAppleEventManager 的 handler 慣例（event, replyEvent 皆為 NSAppleEventDescriptor）
            #[unsafe(method(handleGetURLEvent:withReplyEvent:))]
            fn handle_get_url(&self, event: &AnyObject, _reply: &AnyObject) {
                // SAFETY: NSAppleEventDescriptor 的標準 API
                let url: Option<String> = unsafe {
                    let param: Option<Retained<AnyObject>> =
                        msg_send![event, paramDescriptorForKeyword: KEY_DIRECT_OBJECT];
                    param.and_then(|p| {
                        let s: Option<Retained<objc2_foundation::NSString>> = msg_send![&*p, stringValue];
                        s.map(|s| s.to_string())
                    })
                };
                match url {
                    Some(u) => super::route_url(&u),
                    None => log::info!("kAEGetURL 事件沒有 URL 字串"),
                }
            }
        }
    );

    pub fn install() {
        if objc2::MainThreadMarker::new().is_none() {
            log::warn!("install_apple_event_handler 必須在主執行緒呼叫，略過");
            return;
        }
        // SAFETY: init 是 NSObject 的標準初始化
        let handler: Retained<UrlEventHandler> = unsafe { msg_send![UrlEventHandler::alloc(), init] };
        // SAFETY: setEventHandler:andSelector:forEventClass:andEventID: 參數型別與 Foundation 宣告一致
        unsafe {
            let manager: Retained<AnyObject> = msg_send![class!(NSAppleEventManager), sharedAppleEventManager];
            let _: () = msg_send![
                &*manager,
                setEventHandler: &*handler,
                andSelector: sel!(handleGetURLEvent:withReplyEvent:),
                forEventClass: K_INTERNET_EVENT_CLASS,
                andEventID: K_AE_GET_URL
            ];
        }
        // NSAppleEventManager 不 retain handler：讓它跟程序活一樣久
        std::mem::forget(handler);
        log::info!("已登記 saybit:// Apple Event handler");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cmd(command: &str, mode: Option<&str>, tab: Option<&str>) -> Option<UrlCommand> {
        Some(UrlCommand { command: command.into(), mode: mode.map(Into::into), tab: tab.map(Into::into) })
    }

    #[test]
    fn url_parse_host_and_path_forms() {
        assert_eq!(parse("saybit://toggle"), cmd("toggle", None, None));
        assert_eq!(parse("SAYBIT://Start"), cmd("start", None, None));
        assert_eq!(parse("saybit:stop"), cmd("stop", None, None));
        assert_eq!(parse("saybit:///cancel"), cmd("cancel", None, None));
        assert_eq!(parse("saybit://toggle/"), cmd("toggle", None, None));
        assert_eq!(parse("  saybit://settings  "), cmd("settings", None, None));
    }

    #[test]
    fn url_parse_query() {
        assert_eq!(parse("saybit://start?mode=Email"), cmd("start", Some("Email"), None));
        assert_eq!(
            parse("saybit://toggle?mode=%E7%BF%BB%E8%AD%AF%E6%88%90%E8%8B%B1%E6%96%87"),
            cmd("toggle", Some("翻譯成英文"), None)
        );
        assert_eq!(parse("saybit://settings?tab=hotkeys&mode="), cmd("settings", None, Some("hotkeys")));
        assert_eq!(parse("saybit:start?mode=Email"), cmd("start", Some("Email"), None));
    }

    #[test]
    fn url_parse_rejects_unknown() {
        assert_eq!(parse("saybit://rm-rf"), None);
        assert_eq!(parse("https://toggle"), None);
        assert_eq!(parse("not a url"), None);
        assert_eq!(parse("saybit://"), None);
    }

    #[test]
    fn url_dedup_within_one_second() {
        let mut d = UrlDeduper::default();
        let t0 = Instant::now();
        assert!(d.accept("saybit://toggle", t0));
        assert!(!d.accept("saybit://toggle", t0 + Duration::from_millis(900)));
        assert!(!d.accept("SAYBIT://TOGGLE", t0 + Duration::from_millis(950)));
        assert!(d.accept("saybit://stop", t0 + Duration::from_millis(900)));
        // 視窗以最後一次「接受」為準
        assert!(d.accept("saybit://toggle", t0 + Duration::from_millis(1100)));
    }

    #[test]
    fn global_accept_url_drops_repeat_within_one_second() {
        let u = format!("saybit://toggle?mode=accept-test-{}", std::process::id());
        assert!(accept_url(&u));
        assert!(!accept_url(&u));
        assert!(!accept_url(&u.to_ascii_uppercase()));
        assert!(accept_url("saybit://stop?mode=accept-test-other"));
    }

    #[test]
    fn route_url_filters_unknown() {
        // 不認得的 URL 不會排隊也不會轉送
        route_url("https://evil.example");
        route_url("saybit://rm-rf");
        assert!(URL_ROUTER.lock().pending.iter().all(|u| parse(u).is_some()));
    }

    #[test]
    fn socket_name_sanitizes_user() {
        assert_eq!(socket_name_for("oliver"), "com.bashcat.saybit.oliver.sock");
        assert_eq!(socket_name_for("DOMAIN\\Jane Doe"), "com.bashcat.saybit.DOMAIN_Jane_Doe.sock");
        assert_eq!(socket_name_for(""), "com.bashcat.saybit.default.sock");
        assert_eq!(socket_name_for("../x"), "com.bashcat.saybit.___x.sock");
    }

    #[test]
    fn message_filters_unknown_urls() {
        let msg = "saybit://toggle\n\nhttps://evil\nsaybit://rm-rf\n  saybit://start?mode=Email \n";
        assert_eq!(urls_from_message(msg), vec!["saybit://toggle".to_string(), "saybit://start?mode=Email".into()]);
    }

    #[test]
    fn scheme_registration_values() {
        assert_eq!(windows_open_command(r"C:\Saybit\saybit.exe"), "\"C:\\Saybit\\saybit.exe\" \"%1\"");
        let e = scheme_desktop_entry("/opt/My App/saybit");
        assert!(e.contains("Exec=\"/opt/My App/saybit\" %u\n"));
        assert!(e.contains("MimeType=x-scheme-handler/saybit;\n"));
    }

    /// 真的建一個本機 socket（測試專用名稱，在 $TMPDIR / abstract namespace），不碰正式實例
    #[test]
    fn single_instance_forwards_urls() {
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().subsec_nanos();
        let name = format!("com.bashcat.saybit.test-{}-{nanos}.sock", std::process::id());
        let (tx, rx) = std::sync::mpsc::channel::<String>();
        let tx = Mutex::new(tx);
        let role = acquire_with_name(
            &name,
            vec!["saybit://settings?tab=general".into(), "garbage".into()],
            Box::new(move |u| {
                let _ = tx.lock().send(u);
            }),
        );
        assert!(matches!(role, InstanceRole::Primary));
        // argv 的合法 URL 也會進 on_url
        assert_eq!(rx.recv_timeout(Duration::from_secs(2)).unwrap(), "saybit://settings?tab=general");

        let role2 = acquire_with_name(&name, vec!["saybit://toggle?mode=Email".into()], Box::new(|_| panic!("secondary 不該收 URL")));
        assert!(matches!(role2, InstanceRole::Secondary));
        assert_eq!(rx.recv_timeout(Duration::from_secs(2)).unwrap(), "saybit://toggle?mode=Email");

        // macOS 是 $TMPDIR 裡的 socket 檔；Linux / Windows 是 namespace，不留檔
        let _ = std::fs::remove_file(std::env::temp_dir().join(&name));
    }
}

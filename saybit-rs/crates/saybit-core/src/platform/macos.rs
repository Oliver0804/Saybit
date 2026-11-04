//! macOS：NSWorkspace（前景 App、最近外部 App）、AX（選取文字、視窗標題、權限）、
//! SMAppService / LaunchAgent（開機啟動）、NSSound。
//!
//! AppKit 的東西（NSWorkspace / NSRunningApplication / NSSound）一律透過 `inject::run_on_main`
//! 派回主執行緒；AX API 本身可在背景執行緒呼叫（原生版也是在 detached task 跑）。

use super::selection::AxSelection;
use crate::inject::run_on_main;
use crate::types::AppContext;
use objc2::rc::Retained;
use objc2_app_kit::{NSRunningApplication, NSWorkspace};
use objc2_foundation::NSString;
use std::ffi::c_void;
use std::time::Duration;

const MAIN_TIMEOUT: Duration = Duration::from_millis(500);

// ───────────────────────────── AX / CF FFI ─────────────────────────────

type CFTypeRef = *const c_void;
type AXUIElementRef = *const c_void;
type AXError = i32;
const AX_SUCCESS: AXError = 0;

#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    fn AXIsProcessTrusted() -> u8;
    fn AXIsProcessTrustedWithOptions(options: CFTypeRef) -> u8;
    fn AXUIElementCreateApplication(pid: i32) -> AXUIElementRef;
    fn AXUIElementCopyAttributeValue(element: AXUIElementRef, attribute: CFTypeRef, value: *mut CFTypeRef) -> AXError;
    fn AXUIElementSetMessagingTimeout(element: AXUIElementRef, timeout: f32) -> AXError;
    fn AXUIElementGetTypeID() -> usize;
    static kAXTrustedCheckOptionPrompt: CFTypeRef;
}

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFRelease(cf: CFTypeRef);
    fn CFGetTypeID(cf: CFTypeRef) -> usize;
    fn CFStringGetTypeID() -> usize;
}

/// 自己持有（Create / Copy 規則）的 CF 物件，drop 時 CFRelease
struct CfOwned(CFTypeRef);

impl Drop for CfOwned {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: 只包 Create/Copy 回來、由我們持有的物件
            unsafe { CFRelease(self.0) }
        }
    }
}

impl CfOwned {
    fn type_id(&self) -> usize {
        // SAFETY: 非 null 的有效 CF 物件
        unsafe { CFGetTypeID(self.0) }
    }

    fn is_ax_element(&self) -> bool {
        // SAFETY: 純查詢
        !self.0.is_null() && self.type_id() == unsafe { AXUIElementGetTypeID() }
    }

    /// CFString → String（toll-free bridged 到 NSString）
    fn as_string(&self) -> Option<String> {
        // SAFETY: 先確認型別是 CFString，CFString 與 NSString toll-free bridged
        unsafe {
            if self.0.is_null() || self.type_id() != CFStringGetTypeID() {
                return None;
            }
            let ns: &NSString = &*(self.0 as *const NSString);
            Some(ns.to_string())
        }
    }
}

/// `element` 的 `attribute`；失敗回 Err(AXError)
fn ax_copy(element: AXUIElementRef, attribute: &str) -> Result<CfOwned, AXError> {
    let name = NSString::from_str(attribute);
    let mut value: CFTypeRef = std::ptr::null();
    // SAFETY: element 是有效 AXUIElement；NSString toll-free bridged 為 CFStringRef；value 是區域變數
    let status = unsafe {
        AXUIElementCopyAttributeValue(element, Retained::as_ptr(&name) as CFTypeRef, &mut value)
    };
    if status == AX_SUCCESS && !value.is_null() {
        Ok(CfOwned(value))
    } else {
        if !value.is_null() {
            drop(CfOwned(value));
        }
        Err(status)
    }
}

fn ax_app(pid: i32, timeout: f32) -> Option<CfOwned> {
    // SAFETY: Create 規則，由 CfOwned 持有
    let app = CfOwned(unsafe { AXUIElementCreateApplication(pid) });
    if app.0.is_null() {
        return None;
    }
    // SAFETY: 有效 AXUIElement
    unsafe { AXUIElementSetMessagingTimeout(app.0, timeout) };
    Some(app)
}

/// AX 讀選取文字的三態 + 焦點元素的 role（拿不到焦點元素時 None）
pub(super) fn ax_selection(pid: i32) -> (AxSelection, Option<String>) {
    let Some(app) = ax_app(pid, 0.5) else { return (AxSelection::Unsupported, None) };
    let mut role = None;

    // 1a：焦點元素 → selected text
    match ax_copy(app.0, "AXFocusedUIElement") {
        Ok(focused) if focused.is_ax_element() => {
            role = ax_copy(focused.0, "AXRole").ok().and_then(|r| r.as_string());
            match ax_copy(focused.0, "AXSelectedText").map(|v| v.as_string()) {
                Ok(Some(text)) => return (to_selection(text), role),
                Ok(None) => log::info!("AX selectedText 不是字串"),
                Err(status) => log::info!("AX focusedElement 有但 selectedText 失敗 (status={status})"),
            }
        }
        Ok(_) => log::info!("AX focusedElement 型別不符"),
        Err(status) => log::info!("AX focusedElement 失敗 (status={status})"),
    }

    // 1b：有些 App 直接掛在 app element 上
    if let Ok(Some(text)) = ax_copy(app.0, "AXSelectedText").map(|v| v.as_string()) {
        return (to_selection(text), role);
    }
    (AxSelection::Unsupported, role)
}

fn to_selection(text: String) -> AxSelection {
    if text.is_empty() {
        AxSelection::EmptySelection
    } else {
        AxSelection::Text(text)
    }
}

/// 焦點視窗標題（沒有輔助使用權限或 App 不提供時為空字串）
fn ax_window_title(pid: i32) -> String {
    // SAFETY: 純查詢
    if unsafe { AXIsProcessTrusted() } == 0 {
        return String::new();
    }
    let Some(app) = ax_app(pid, 0.25) else { return String::new() };
    ax_copy(app.0, "AXFocusedWindow")
        .ok()
        .filter(|w| w.is_ax_element())
        .and_then(|w| ax_copy(w.0, "AXTitle").ok())
        .and_then(|t| t.as_string())
        .unwrap_or_default()
}

// ───────────────────────────── 前景 App ─────────────────────────────

fn context_of(running: &NSRunningApplication) -> AppContext {
    let pid = running.processIdentifier();
    AppContext {
        app_name: running.localizedName().map(|s| s.to_string()).unwrap_or_default(),
        bundle_id: running.bundleIdentifier().map(|s| s.to_string()).unwrap_or_default(),
        pid: (pid > 0).then_some(pid as u32),
        window_title: String::new(),
        selected_text: None,
    }
}

fn frontmost_on_main() -> Option<AppContext> {
    run_on_main(MAIN_TIMEOUT, || {
        NSWorkspace::sharedWorkspace().frontmostApplication().map(|a| context_of(&a))
    })
    .ok()
    .flatten()
}

pub(super) fn foreground_app() -> AppContext {
    let Some(mut ctx) = frontmost_on_main() else { return AppContext::default() };
    if let Some(pid) = ctx.pid {
        ctx.window_title = ax_window_title(pid as i32);
    }
    ctx
}

pub(super) fn foreground_pid() -> Option<u32> {
    frontmost_on_main().and_then(|c| c.pid)
}

// ───────────────────────────── 最近外部 App ─────────────────────────────

/// 在主執行緒呼叫一次：開始追蹤外部前景 App（整個程序生命週期）。
pub(super) fn start_tracking_external_app() {
    use block2::RcBlock;
    use objc2::runtime::AnyObject;
    use objc2::{class, msg_send};
    use std::ptr::NonNull;

    let workspace = NSWorkspace::sharedWorkspace();
    if let Some(front) = workspace.frontmostApplication() {
        super::remember_if_external(&context_of(&front));
    }

    let block = RcBlock::new(|notification: NonNull<AnyObject>| {
        // SAFETY: NSNotification 的 userInfo / objectForKey: 皆為標準 API；型別再以 downcast 確認
        unsafe {
            let key = NSString::from_str("NSWorkspaceApplicationKey");
            let info: Option<Retained<AnyObject>> = msg_send![notification.as_ref(), userInfo];
            let Some(info) = info else { return };
            let app: Option<Retained<AnyObject>> = msg_send![&*info, objectForKey: &*key];
            let Some(app) = app else { return };
            if let Ok(running) = app.downcast::<NSRunningApplication>() {
                super::remember_if_external(&context_of(&running));
            }
        }
    });

    // SAFETY: addObserverForName:object:queue:usingBlock: 參數型別與 AppKit 宣告一致
    unsafe {
        let center: Retained<AnyObject> = msg_send![&*workspace, notificationCenter];
        let name = NSString::from_str("NSWorkspaceDidActivateApplicationNotification");
        let queue: Retained<AnyObject> = msg_send![class!(NSOperationQueue), mainQueue];
        let nil: *const AnyObject = std::ptr::null();
        let observer: Option<Retained<AnyObject>> = msg_send![
            &*center,
            addObserverForName: &*name,
            object: nil,
            queue: &*queue,
            usingBlock: &*block
        ];
        // 整個程序生命週期都要觀察，刻意不移除
        std::mem::forget(observer);
    }
}

pub(super) fn activate_app(target: &AppContext) -> bool {
    let pid = target.pid;
    let bundle_id = target.bundle_id.clone();
    run_on_main(MAIN_TIMEOUT, move || {
        use objc2::{msg_send, sel};
        let running = match pid {
            Some(p) if p > 0 => NSRunningApplication::runningApplicationWithProcessIdentifier(p as i32),
            _ if !bundle_id.is_empty() => {
                let id = NSString::from_str(&bundle_id);
                NSRunningApplication::runningApplicationsWithBundleIdentifier(&id).firstObject()
            }
            _ => None,
        };
        let Some(running) = running else { return false };
        if running.isTerminated() {
            return false;
        }
        // SAFETY: activate（macOS 14+）存在才呼叫；舊系統退回 activateWithOptions:（IgnoringOtherApps = 1 << 1）
        unsafe {
            let responds: bool = msg_send![&*running, respondsToSelector: sel!(activate)];
            if responds {
                let _: bool = msg_send![&*running, activate];
            } else {
                let _: bool = msg_send![&*running, activateWithOptions: 1usize << 1];
            }
        }
        true
    })
    .unwrap_or(false)
}

// ───────────────────────────── 開檔 / URL ─────────────────────────────

fn run_open(args: &[&std::ffi::OsStr]) -> anyhow::Result<()> {
    let status = std::process::Command::new("/usr/bin/open").args(args).status()?;
    anyhow::ensure!(status.success(), "open 結束碼 {status}");
    Ok(())
}

pub(super) fn open_url(url: &str) -> anyhow::Result<()> {
    run_open(&[std::ffi::OsStr::new(url)])
}

pub(super) fn reveal_in_file_manager(path: &std::path::Path) -> anyhow::Result<()> {
    run_open(&[std::ffi::OsStr::new("-R"), path.as_os_str()])
}

// ───────────────────────────── 權限 ─────────────────────────────

pub(super) fn accessibility_trusted() -> Option<bool> {
    // SAFETY: 純查詢
    Some(unsafe { AXIsProcessTrusted() } != 0)
}

pub(super) fn request_accessibility() {
    use objc2::runtime::AnyObject;
    use objc2_foundation::{NSDictionary, NSNumber};
    // SAFETY: kAXTrustedCheckOptionPrompt 是 ApplicationServices 匯出的 CFStringRef 常數（toll-free 為 NSString）；
    // NSDictionary toll-free bridged 為 CFDictionaryRef
    unsafe {
        let key: &NSString = &*(kAXTrustedCheckOptionPrompt as *const NSString);
        let value = NSNumber::new_bool(true);
        let value: &AnyObject = &value;
        let dict = NSDictionary::<NSString, AnyObject>::from_slices(&[key], &[value]);
        AXIsProcessTrustedWithOptions(Retained::as_ptr(&dict) as CFTypeRef);
    }
}

pub(super) fn open_privacy_settings(pane: &str) -> anyhow::Result<()> {
    open_url(&super::macos_privacy_url(pane))
}

// ───────────────────────────── 開機啟動 ─────────────────────────────

/// 從 .app bundle 執行才能用 SMAppService（macOS 13+）；`cargo run` 的裸執行檔改用 LaunchAgent
fn sm_app_service_usable() -> bool {
    use objc2::runtime::AnyClass;
    let bundle_path = objc2_foundation::NSBundle::mainBundle().bundlePath().to_string();
    bundle_path.ends_with(".app") && AnyClass::get(c"SMAppService").is_some()
}

fn launch_agent_path() -> Option<std::path::PathBuf> {
    let home = std::env::var_os("HOME")?;
    Some(
        std::path::PathBuf::from(home)
            .join("Library/LaunchAgents")
            .join(format!("{}.plist", super::LAUNCH_AGENT_LABEL)),
    )
}

pub(super) fn launch_at_login() -> bool {
    if sm_app_service_usable() {
        use objc2_service_management::{SMAppService, SMAppServiceStatus};
        // SAFETY: 已確認類別存在
        let status = unsafe { SMAppService::mainAppService().status() };
        return status == SMAppServiceStatus::Enabled;
    }
    launch_agent_path().is_some_and(|p| p.exists())
}

pub(super) fn set_launch_at_login(enabled: bool) -> anyhow::Result<()> {
    if sm_app_service_usable() {
        use objc2_service_management::SMAppService;
        // SAFETY: 已確認類別存在
        let service = unsafe { SMAppService::mainAppService() };
        let result = unsafe {
            if enabled {
                service.registerAndReturnError()
            } else {
                service.unregisterAndReturnError()
            }
        };
        return result.map_err(|e| anyhow::anyhow!("SMAppService: {}", e.localizedDescription()));
    }
    let path = launch_agent_path().ok_or_else(|| anyhow::anyhow!("找不到 HOME"))?;
    if enabled {
        let exe = std::env::current_exe()?;
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        std::fs::write(&path, super::launch_agent_plist(&exe.to_string_lossy()))?;
    } else {
        match std::fs::remove_file(&path) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.into()),
        }
    }
    Ok(())
}

// ───────────────────────────── 音效 ─────────────────────────────

pub(super) fn play_sound(name: &str) {
    let name = name.to_string();
    let _ = run_on_main(MAIN_TIMEOUT, move || {
        use objc2_app_kit::NSSound;
        let ns = NSString::from_str(&name);
        match NSSound::soundNamed(&ns) {
            Some(sound) => {
                sound.play();
            }
            None => log::info!("找不到系統音效 {name}"),
        }
    });
}

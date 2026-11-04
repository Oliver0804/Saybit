//! Saybit（egui/eframe）—— 批次 A1 負責本檔與 app.rs / tray.rs / hotkeys.rs / overlay.rs / onboarding.rs / fonts.rs / theme.rs / strings_app.rs。
//! 批次 A2 負責 ui/（設定視窗各分頁、歷史、統計、日誌、檔案轉錄）與 strings_settings.rs。
//!
//! 啟動順序：argv 的 saybit:// → 單一實例（第二個實例轉送 URL 後結束）→ 日誌 → 設定 → 註冊 scheme → eframe。
//! `SAYBIT_SMOKE=1`：不建系統匣、不註冊快捷鍵／scheme、不啟動 pipeline、不讀寫設定，30 秒後自動結束（只看視窗與字型）。
#![cfg_attr(all(not(debug_assertions), target_os = "windows"), windows_subsystem = "windows")]

mod app;
mod fonts;
mod hotkeys;
mod onboarding;
mod overlay;
mod strings_app;
mod strings_settings;
mod theme;
mod tray;
mod ui;

use std::sync::atomic::{AtomicBool, Ordering};

static SMOKE: AtomicBool = AtomicBool::new(false);

pub fn is_smoke() -> bool {
    SMOKE.load(Ordering::Relaxed)
}

/// 日誌包裝：smoke 模式只印到 stderr，不寫使用者的日誌檔
pub mod applog {
    use saybit_core::LogLevel;

    fn emit(level: LogLevel, cat: &str, msg: String) {
        if crate::is_smoke() {
            eprintln!("[{level:?}] {cat}: {msg}");
        } else {
            saybit_core::logging::log(level, cat, msg);
        }
    }
    pub fn info(cat: &str, msg: String) {
        emit(LogLevel::Info, cat, msg)
    }
    pub fn warn(cat: &str, msg: String) {
        emit(LogLevel::Warn, cat, msg)
    }
    pub fn error(cat: &str, msg: String) {
        emit(LogLevel::Error, cat, msg)
    }
}

fn main() -> eframe::Result {
    let smoke = std::env::var("SAYBIT_SMOKE").is_ok_and(|v| v == "1");
    SMOKE.store(smoke, Ordering::Relaxed);

    let argv_urls: Vec<String> =
        std::env::args().skip(1).filter(|a| a.to_ascii_lowercase().starts_with("saybit:")).collect();

    let settings = if smoke {
        saybit_core::Settings::default()
    } else {
        // 第二個實例：把 URL 交給主實例後直接結束
        let on_url: Box<dyn Fn(String) + Send + Sync> = Box::new(|url| app::post(app::AppMsg::Url(url)));
        if let saybit_core::deeplink::InstanceRole::Secondary =
            saybit_core::deeplink::acquire_single_instance(argv_urls, on_url)
        {
            return Ok(());
        }
        saybit_core::logging::init();
        let settings = saybit_core::settings::load();
        if let Err(e) = saybit_core::deeplink::register_scheme() {
            applog::warn("URL", format!("saybit:// 註冊失敗：{e}"));
        }
        // macOS：App 已在執行時 LaunchServices 用 Apple Event 交付 saybit://，不經 argv / socket。
        // 必須在主執行緒、進 NSApplication 事件迴圈之前呼叫一次（其他平台 no-op）。
        saybit_core::deeplink::install_apple_event_handler();
        saybit_core::ducking::restore_pending_if_needed();
        settings
    };
    ui::l10n::set_language(settings.app_language);

    let show_onboarding = !settings.has_completed_onboarding;
    let (size, min) = app::root_size(show_onboarding);
    let icon = image::load_from_memory(include_bytes!("../assets/icon-256.png")).ok().map(|img| {
        let img = img.into_rgba8();
        let (w, h) = img.dimensions();
        egui::IconData { rgba: img.into_raw(), width: w, height: h }
    });
    let mut viewport = egui::ViewportBuilder::default()
        .with_title(if show_onboarding { ui::l10n::t("onb.windowTitle") } else { ui::l10n::t("menu.settingsWindowTitle") })
        .with_app_id("saybit")
        .with_inner_size(size)
        .with_min_inner_size(min);
    if let Some(icon) = icon {
        viewport = viewport.with_icon(std::sync::Arc::new(icon));
    }

    let mut options = eframe::NativeOptions { viewport, ..Default::default() };
    // macOS：像 LSUIElement 一樣不出現在 Dock（打包後 Info.plist 也設 LSUIElement=true）
    #[cfg(target_os = "macos")]
    {
        options.event_loop_builder = Some(Box::new(|builder| {
            use winit::platform::macos::{ActivationPolicy, EventLoopBuilderExtMacOS};
            builder.with_activation_policy(ActivationPolicy::Accessory);
        }));
    }
    // eframe 會記住視窗大小位置；設定視窗大小我們自己管
    options.persist_window = false;

    eframe::run_native(
        "Saybit",
        options,
        Box::new(move |cc| Ok(Box::new(app::SaybitApp::new(cc, settings, smoke)))),
    )
}

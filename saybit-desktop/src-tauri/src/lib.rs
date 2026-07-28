// Saybit Desktop Rust Core
mod apple_speech;
mod eventkit;
mod injection;
mod local_stt;
mod platform;
mod secure_store;
mod streaming_stt;

use tauri::{AppHandle, Emitter, Manager};
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut, ShortcutState};
use enigo::{Enigo, Keyboard, Settings, Key, Direction};
use std::fs::OpenOptions;
use std::io::Write;

fn log_startup(app: &AppHandle, msg: &str) {
    if let Ok(dir) = app.path().app_data_dir() {
        let _ = std::fs::create_dir_all(&dir);
        if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(dir.join("startup.log")) {
            let _ = writeln!(f, "[{}] {}", chrono_like_ts(), msg);
        }
    }
}

fn chrono_like_ts() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs().to_string()).unwrap_or_else(|_| "?".into())
}

fn build_tray(app: &tauri::App) -> Result<(), Box<dyn std::error::Error>> {
    let tray_menu = Menu::with_items(app, &[
        &MenuItem::with_id(app, "show_settings", "設定 (Settings)", true, None::<&str>)?,
        &MenuItem::with_id(app, "quit", "結束 (Quit)", true, None::<&str>)?,
    ])?;

    let icon = app.default_window_icon()
        .ok_or("default_window_icon not available")?
        .clone();

    let _tray = TrayIconBuilder::new()
        .icon(icon)
        .menu(&tray_menu)
        .on_menu_event(|app, event| {
            match event.id.as_ref() {
                "show_settings" => {
                    if let Some(window) = app.get_webview_window("main") {
                        let _ = window.show();
                        let _ = window.set_focus();
                    }
                }
                "quit" => app.exit(0),
                _ => {}
            }
        })
        .build(app)?;

    Ok(())
}

// enigo 在 macOS 會呼叫 Text Input Source API（TSM/HIToolbox），這些 API 斷言
// 必須在主執行緒執行。Tauri command 預設跑在 tokio worker 執行緒，直接呼叫會
// 觸發 dispatch_assert_queue 崩潰，因此一律用 run_on_main_thread 派到主執行緒。
#[tauri::command]
fn simulate_paste(app: AppHandle) -> Result<(), String> {
    app.run_on_main_thread(|| {
        if let Ok(mut enigo) = Enigo::new(&Settings::default()) {
            #[cfg(target_os = "macos")]
            let modifier = Key::Meta;
            #[cfg(not(target_os = "macos"))]
            let modifier = Key::Control;
            let _ = enigo.key(modifier, Direction::Press);
            let _ = enigo.key(Key::Unicode('v'), Direction::Click);
            let _ = enigo.key(modifier, Direction::Release);
        }
    })
    .map_err(|e| e.to_string())
}

#[tauri::command]
fn simulate_enter(app: AppHandle) -> Result<(), String> {
    app.run_on_main_thread(|| {
        if let Ok(mut enigo) = Enigo::new(&Settings::default()) {
            let _ = enigo.key(Key::Return, Direction::Click);
        }
    })
    .map_err(|e| e.to_string())
}

#[tauri::command]
fn apply_vibrancy(app: AppHandle, label: String) -> Result<(), String> {
    if let Some(window) = app.get_webview_window(&label) {
        #[cfg(target_os = "windows")]
        {
            window_vibrancy::apply_acrylic(&window, Some((0, 0, 0, 0)))
                .map_err(|e| e.to_string())?;
        }
        #[cfg(target_os = "macos")]
        {
            use window_vibrancy::{NSVisualEffectMaterial, NSVisualEffectState};
            window_vibrancy::apply_vibrancy(
                &window,
                NSVisualEffectMaterial::HudWindow,
                Some(NSVisualEffectState::Active),
                None
            ).map_err(|e| e.to_string())?;
        }
        #[cfg(target_os = "linux")]
        {
            let _ = &window; // Linux 不支援原生磨砂玻璃
        }
    }
    Ok(())
}

#[tauri::command]
fn show_window(app: AppHandle, label: String) -> Result<(), String> {
    if let Some(window) = app.get_webview_window(&label) {
        window.show().map_err(|e| e.to_string())?;
        // 膠囊絕不能搶焦點：一旦 Saybit 變成前景 App，後續 Cmd+V 會貼進膠囊自己，
        // 而且前景 App 查詢也只會查到 Saybit。原生版是用 nonactivatingPanel 達成
        // 同樣效果。設定視窗則維持照常聚焦。
        if label != "overlay" {
            window.set_focus().map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

#[tauri::command]
fn hide_window(app: AppHandle, label: String) -> Result<(), String> {
    if let Some(window) = app.get_webview_window(&label) {
        window.hide().map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
fn frontend_log(app: AppHandle, msg: String) {
    if let Ok(dir) = app.path().app_data_dir() {
        let _ = std::fs::create_dir_all(&dir);
        if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(dir.join("frontend.log")) {
            let _ = writeln!(f, "[{}] {}", chrono_like_ts(), msg);
        }
    }
}

/// 讀取日誌檔尾端內容供設定畫面顯示。kind 只接受固定的兩個值，
/// 不讓前端傳任意路徑進來。
#[tauri::command]
fn read_log(app: AppHandle, kind: String, max_lines: Option<usize>) -> Result<String, String> {
    let filename = match kind.as_str() {
        "frontend" => "frontend.log",
        "startup" => "startup.log",
        _ => return Err(format!("未知的日誌類型：{kind}")),
    };
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    let path = dir.join(filename);
    if !path.exists() {
        return Ok(String::new());
    }
    let content = std::fs::read_to_string(&path).map_err(|e| e.to_string())?;
    let limit = max_lines.unwrap_or(500);
    let lines: Vec<&str> = content.lines().collect();
    let start = lines.len().saturating_sub(limit);
    Ok(lines[start..].join("\n"))
}

#[tauri::command]
fn clear_log(app: AppHandle, kind: String) -> Result<(), String> {
    let filename = match kind.as_str() {
        "frontend" => "frontend.log",
        "startup" => "startup.log",
        _ => return Err(format!("未知的日誌類型：{kind}")),
    };
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    let path = dir.join(filename);
    if path.exists() {
        std::fs::write(&path, "").map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
fn set_hotkey(app: AppHandle, shortcut: String) -> Result<(), String> {
    let gs = app.global_shortcut();
    let _ = gs.unregister_all();
    let parsed: Shortcut = shortcut.parse().map_err(|e| format!("{e:?}"))?;
    gs.register(parsed).map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
fn show_overlay_menu(app: AppHandle) -> Result<(), String> {
    let overlay = app.get_webview_window("overlay").ok_or("overlay window not found")?;
    let menu = Menu::with_items(&app, &[
        &MenuItem::with_id(&app, "ov_open_settings", "設定 Settings", true, None::<&str>)
            .map_err(|e| e.to_string())?,
        &PredefinedMenuItem::separator(&app).map_err(|e| e.to_string())?,
        &MenuItem::with_id(&app, "ov_hide", "隱藏膠囊", true, None::<&str>)
            .map_err(|e| e.to_string())?,
        &MenuItem::with_id(&app, "ov_quit", "結束 Saybit", true, None::<&str>)
            .map_err(|e| e.to_string())?,
    ]).map_err(|e| e.to_string())?;
    overlay.popup_menu(&menu).map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // 把 whisper.cpp / GGML 的 C 層 log 導向 Rust log crate；未啟用 log backend
    // 時等同關閉，避免每次轉錄在 stdout 噴大量 token 級除錯訊息。
    whisper_rs::install_logging_hooks();

    tauri::Builder::default()
        .plugin(tauri_plugin_http::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_store::Builder::new().build())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, _shortcut, event| {
                    // 按下與放開都要送出：hold（按住說話）與 doubleTap 觸發模式需要
                    // 完整的 press/release 時序，前端狀態機才判斷得出來。
                    // toggle 模式也是在前端由 hotkey-pressed 推動。
                    match event.state() {
                        ShortcutState::Pressed => {
                            let _ = app.emit("hotkey-pressed", ());
                        }
                        ShortcutState::Released => {
                            let _ = app.emit("hotkey-released", ());
                        }
                    }
                })
                .build(),
        )
        .invoke_handler(tauri::generate_handler![
            simulate_paste,
            simulate_enter,
            apply_vibrancy,
            show_window,
            hide_window,
            set_hotkey,
            show_overlay_menu,
            frontend_log,
            read_log,
            clear_log,
            platform::foreground_app,
            platform::get_selected_text,
            injection::inject_text,
            apple_speech::apple_speech_supported,
            apple_speech::apple_speech_authorized,
            apple_speech::apple_speech_authorize,
            apple_speech::transcribe_apple,
            eventkit::action_intents_supported,
            eventkit::create_calendar_event,
            eventkit::create_reminder,
            streaming_stt::streaming_stt_start,
            streaming_stt::streaming_stt_push,
            streaming_stt::streaming_stt_finish,
            streaming_stt::streaming_stt_cancel,
            streaming_stt::streaming_stt_test,
            secure_store::secret_get,
            secure_store::secret_set,
            secure_store::secret_delete,
            local_stt::local_stt_status,
            local_stt::download_stt_model,
            local_stt::transcribe_local
        ])
        .on_menu_event(|app, event| {
            match event.id.as_ref() {
                "ov_open_settings" => {
                    if let Some(w) = app.get_webview_window("main") {
                        let _ = w.show();
                        let _ = w.set_focus();
                    }
                }
                "ov_hide" => {
                    if let Some(w) = app.get_webview_window("overlay") {
                        let _ = w.hide();
                    }
                }
                "ov_quit" => app.exit(0),
                _ => {}
            }
        })
        .setup(|app| {
            let handle = app.handle().clone();
            log_startup(&handle, "setup: begin");

            // 1. 初始化系統托盤（任一步失敗都不阻擋 app 啟動）
            match build_tray(app) {
                Ok(_) => log_startup(&handle, "setup: tray ok"),
                Err(e) => log_startup(&handle, &format!("setup: tray FAILED: {e}")),
            }

            // 2. 註冊預設全域熱鍵 Ctrl + Alt + Space
            if let Ok(shortcut) = "Ctrl+Alt+Space".parse::<Shortcut>() {
                match app.global_shortcut().register(shortcut) {
                    Ok(_) => log_startup(&handle, "setup: hotkey ok"),
                    Err(e) => log_startup(&handle, &format!("setup: hotkey FAILED: {e}")),
                }
            }

            // 3. 初始顯示主設定視窗（以利載入 Onboarding），置於主螢幕正中
            if let Some(main_window) = app.get_webview_window("main") {
                if let Ok(Some(primary)) = main_window.primary_monitor() {
                    let scale = primary.scale_factor();
                    let mon_w = (primary.size().width as f64) / scale;
                    let mon_h = (primary.size().height as f64) / scale;
                    let win_w = 900.0;
                    let win_h = 650.0;
                    let x = (mon_w - win_w) / 2.0;
                    let y = (mon_h - win_h) / 2.0;
                    let _ = main_window.set_position(tauri::LogicalPosition::new(x, y));
                }
                match main_window.show() {
                    Ok(_) => log_startup(&handle, "setup: main window shown"),
                    Err(e) => log_startup(&handle, &format!("setup: show main FAILED: {e}")),
                }
                let _ = main_window.set_focus();
            } else {
                log_startup(&handle, "setup: main window NOT FOUND");
            }

            log_startup(&handle, "setup: done");
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

// force-reload marker

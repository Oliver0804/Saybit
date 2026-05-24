// Saybit Desktop Rust Core
use tauri::{AppHandle, Emitter, Manager};
use tauri::menu::{Menu, MenuItem};
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

#[tauri::command]
async fn simulate_paste() -> Result<(), String> {
    let mut enigo = Enigo::new(&Settings::default()).map_err(|e| e.to_string())?;
    
    #[cfg(target_os = "macos")]
    let modifier = Key::Meta;
    #[cfg(not(target_os = "macos"))]
    let modifier = Key::Control;

    enigo.key(modifier, Direction::Press).map_err(|e| e.to_string())?;
    enigo.key(Key::Unicode('v'), Direction::Click).map_err(|e| e.to_string())?;
    enigo.key(modifier, Direction::Release).map_err(|e| e.to_string())?;
    
    Ok(())
}

#[tauri::command]
async fn simulate_enter() -> Result<(), String> {
    let mut enigo = Enigo::new(&Settings::default()).map_err(|e| e.to_string())?;
    enigo.key(Key::Return, Direction::Click).map_err(|e| e.to_string())?;
    Ok(())
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
        window.set_focus().map_err(|e| e.to_string())?;
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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_store::Builder::new().build())
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, _shortcut, event| {
                    if event.state() == ShortcutState::Pressed {
                        // 當快捷鍵被按下時，發送事件通知前端狀態機
                        app.emit("hotkey-triggered", ()).unwrap();
                    }
                })
                .build(),
        )
        .invoke_handler(tauri::generate_handler![
            simulate_paste,
            simulate_enter,
            apply_vibrancy,
            show_window,
            hide_window
        ])
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

            // 3. 初始顯示主設定視窗（以利載入 Onboarding）
            if let Some(main_window) = app.get_webview_window("main") {
                match main_window.show() {
                    Ok(_) => log_startup(&handle, "setup: main window shown"),
                    Err(e) => log_startup(&handle, &format!("setup: show main FAILED: {e}")),
                }
            } else {
                log_startup(&handle, "setup: main window NOT FOUND");
            }

            log_startup(&handle, "setup: done");
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

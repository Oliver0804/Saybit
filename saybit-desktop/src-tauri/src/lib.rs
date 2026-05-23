// Saybit Desktop Rust Core
use tauri::{AppHandle, Emitter, Manager};
use tauri::menu::{Menu, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut, ShortcutState};
use enigo::{Enigo, Keyboard, Settings, Key, Direction};

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
            // 1. 初始化系統托盤
            let tray_menu = Menu::with_items(app, &[
                &MenuItem::with_id(app, "show_settings", "設定 (Settings)", true, None::<&str>)?,
                &MenuItem::with_id(app, "quit", "結束 (Quit)", true, None::<&str>)?,
            ])?;

            let _tray = TrayIconBuilder::new()
                .icon(app.default_window_icon().unwrap().clone())
                .menu(&tray_menu)
                .on_menu_event(|app, event| {
                    match event.id.as_ref() {
                        "show_settings" => {
                            if let Some(window) = app.get_webview_window("main") {
                                window.show().unwrap();
                                window.set_focus().unwrap();
                            }
                        }
                        "quit" => {
                            app.exit(0);
                        }
                        _ => {}
                    }
                })
                .build(app)?;

            // 2. 註冊預設全域熱鍵 Ctrl + Alt + Space
            let shortcut = "Ctrl+Alt+Space".parse::<Shortcut>().unwrap();
            let _ = app.global_shortcut().register(shortcut);

            // 3. 初始顯示主設定視窗（以利載入 Onboarding）
            if let Some(main_window) = app.get_webview_window("main") {
                main_window.show().unwrap();
            }

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

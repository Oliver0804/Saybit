// 文字注入：把精煉結果送進前景 App。對應原生版 Core/Accessibility/TextInjector.swift。
//
// 三種模式與原生版一致：
//   paste             — 寫剪貼簿 + Cmd/Ctrl+V（預設，最快也最可靠）
//   keypress          — 逐字模擬鍵盤輸入，給不吃貼上的 App（部分終端機、遊戲輸入框）
//   replace_selection — 先送 Backspace 清掉選取內容再貼上
//
// 貼上模式會備份並還原使用者原本的剪貼簿內容 —— 先前 Tauri 版只有備份、從來沒
// 還原，等於每次語音輸入都吃掉使用者的剪貼簿。

use std::time::Duration;
use tauri::AppHandle;
use tauri_plugin_clipboard_manager::ClipboardExt;

use enigo::{Direction, Enigo, Key, Keyboard, Settings};

#[cfg(target_os = "macos")]
const PASTE_MODIFIER: Key = Key::Meta;
#[cfg(not(target_os = "macos"))]
const PASTE_MODIFIER: Key = Key::Control;

/// 注入模式。與前端 settings.injectionMode 的字串值對應。
#[derive(serde::Deserialize, Debug, Clone, Copy, PartialEq, Default)]
#[serde(rename_all = "snake_case")]
pub enum InjectionMode {
    #[default]
    Paste,
    Keypress,
    ReplaceSelection,
}

#[tauri::command]
pub fn inject_text(app: AppHandle, text: String, mode: InjectionMode) -> Result<(), String> {
    if text.is_empty() {
        return Ok(());
    }
    match mode {
        InjectionMode::Paste => inject_via_paste(&app, &text),
        InjectionMode::Keypress => inject_via_keypress(&app, &text),
        InjectionMode::ReplaceSelection => {
            send_key(&app, Key::Backspace)?;
            std::thread::sleep(Duration::from_millis(50));
            inject_via_paste(&app, &text)
        }
    }
}

fn inject_via_paste(app: &AppHandle, text: &str) -> Result<(), String> {
    let clipboard = app.clipboard();
    let backup = clipboard.read_text().unwrap_or_default();

    clipboard
        .write_text(text.to_string())
        .map_err(|e| e.to_string())?;

    // 給剪貼簿寫入落地的時間，太快送 Cmd+V 會貼到舊內容
    std::thread::sleep(Duration::from_millis(50));

    app.run_on_main_thread(|| {
        if let Ok(mut enigo) = Enigo::new(&Settings::default()) {
            let _ = enigo.key(PASTE_MODIFIER, Direction::Press);
            let _ = enigo.key(Key::Unicode('v'), Direction::Click);
            let _ = enigo.key(PASTE_MODIFIER, Direction::Release);
        }
    })
    .map_err(|e| e.to_string())?;

    // 給慢速 App（Electron、大型文件）足夠時間完成貼上再還原。
    // 只有在剪貼簿內容仍是我們寫進去的東西時才還原，避免覆寫使用者這期間的新複製。
    let clipboard_for_restore = app.clone();
    let expected = text.to_string();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(500));
        let clipboard = clipboard_for_restore.clipboard();
        if let Ok(current) = clipboard.read_text() {
            if current == expected {
                let _ = clipboard.write_text(backup);
            }
        }
    });

    Ok(())
}

fn inject_via_keypress(app: &AppHandle, text: &str) -> Result<(), String> {
    let owned = text.to_string();
    app.run_on_main_thread(move || {
        if let Ok(mut enigo) = Enigo::new(&Settings::default()) {
            let _ = enigo.text(&owned);
        }
    })
    .map_err(|e| e.to_string())
}

fn send_key(app: &AppHandle, key: Key) -> Result<(), String> {
    app.run_on_main_thread(move || {
        if let Ok(mut enigo) = Enigo::new(&Settings::default()) {
            let _ = enigo.key(key, Direction::Click);
        }
    })
    .map_err(|e| e.to_string())
}

// API 金鑰的安全儲存。對應原生版 Storage/KeychainHelper.swift。
//
// 先前 Tauri 版把所有 API key 明文寫在 localStorage（也就是 WebView 的
// LocalStorage 檔案裡，任何本機程序都讀得到）。改走各平台的系統金鑰庫：
// macOS Keychain、Windows Credential Manager、Linux Secret Service。
//
// ⚠️ 一定要有行程內快取。macOS 每一次 get_password 都可能彈出鑰匙圈授權對話框，
//    而兩個 webview（設定視窗 + 膠囊）各自會讀 LLM 與 STT 兩把金鑰，dev 模式下
//    React StrictMode 又讓 effect 跑兩遍 —— 沒有快取的話光啟動就要授權 8 次。
//    快取之後每把金鑰每次啟動最多只碰鑰匙圈一次。

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

const SERVICE: &str = "com.oliver.saybit-desktop";

fn cache() -> &'static Mutex<HashMap<String, String>> {
    static CACHE: OnceLock<Mutex<HashMap<String, String>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn entry(account: &str) -> Result<keyring::Entry, String> {
    keyring::Entry::new(SERVICE, account).map_err(|e| e.to_string())
}

/// 讀取金鑰。找不到時回空字串（而非錯誤），呼叫端可直接當作「未設定」。
/// 讀過一次就進快取，之後同一個行程內不再碰鑰匙圈。
#[tauri::command]
pub fn secret_get(account: String) -> Result<String, String> {
    if let Ok(cache) = cache().lock() {
        if let Some(cached) = cache.get(&account) {
            return Ok(cached.clone());
        }
    }

    let value = match entry(&account)?.get_password() {
        Ok(v) => v,
        Err(keyring::Error::NoEntry) => String::new(),
        Err(e) => return Err(e.to_string()),
    };

    // 空值也要快取：沒設定過的金鑰同樣會觸發鑰匙圈查詢
    if let Ok(mut cache) = cache().lock() {
        cache.insert(account, value.clone());
    }
    Ok(value)
}

/// 寫入金鑰。傳空字串等同刪除該筆。
#[tauri::command]
pub fn secret_set(account: String, value: String) -> Result<(), String> {
    let entry = entry(&account)?;

    let outcome = if value.is_empty() {
        match entry.delete_credential() {
            Ok(_) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(e.to_string()),
        }
    } else {
        entry.set_password(&value).map_err(|e| e.to_string())
    };

    // 只有真的寫成功才更新快取，否則快取會跟鑰匙圈說法不一致
    if outcome.is_ok() {
        if let Ok(mut cache) = cache().lock() {
            cache.insert(account, value);
        }
    }
    outcome
}

#[tauri::command]
pub fn secret_delete(account: String) -> Result<(), String> {
    let outcome = match entry(&account)?.delete_credential() {
        Ok(_) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(e.to_string()),
    };
    if outcome.is_ok() {
        if let Ok(mut cache) = cache().lock() {
            cache.remove(&account);
        }
    }
    outcome
}

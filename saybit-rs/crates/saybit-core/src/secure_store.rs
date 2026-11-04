//! API key（批次 C3）：keyring-core + 各平台原生 store（macOS Keychain / Windows Credential Manager / Linux Secret Service），
//! service "com.bashcat.saybit"，account "llm.<providerId>" / "stt.<name>"；process 內快取避免 macOS 重複彈授權。
//!
//! 直接用 keyring-core（而不是 keyring 4 的 v1 包裝）是為了測試時能把 default store 換成 mock：
//! v1 的 `Entry::new` 第一次呼叫會強制換回原生 store。`cfg(test)` 下整個 crate 都用 mock，不碰真的鑰匙圈。

use parking_lot::Mutex;
use std::collections::HashMap;
use std::sync::OnceLock;

const SERVICE: &str = "com.bashcat.saybit";

fn cache() -> &'static Mutex<HashMap<String, String>> {
    static CACHE: OnceLock<Mutex<HashMap<String, String>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// 第一次使用時設定 default store；失敗原因記住，之後每次呼叫都回同一個錯誤
fn ensure_store() -> anyhow::Result<()> {
    static INIT: OnceLock<Result<(), String>> = OnceLock::new();
    INIT.get_or_init(|| init_store().map_err(|e| e.to_string()))
        .clone()
        .map_err(|e| anyhow::anyhow!("無法開啟系統金鑰庫: {e}"))
}

#[cfg(test)]
fn init_store() -> keyring_core::Result<()> {
    keyring_core::set_default_store(keyring_core::mock::Store::new()?);
    Ok(())
}

#[cfg(all(not(test), target_os = "macos"))]
fn init_store() -> keyring_core::Result<()> {
    keyring_core::set_default_store(apple_native_keyring_store::keychain::Store::new()?);
    Ok(())
}

#[cfg(all(not(test), target_os = "windows"))]
fn init_store() -> keyring_core::Result<()> {
    keyring_core::set_default_store(windows_native_keyring_store::Store::new()?);
    Ok(())
}

#[cfg(all(not(test), target_os = "linux"))]
fn init_store() -> keyring_core::Result<()> {
    keyring_core::set_default_store(zbus_secret_service_keyring_store::Store::new()?);
    Ok(())
}

#[cfg(all(not(test), not(any(target_os = "macos", target_os = "windows", target_os = "linux"))))]
fn init_store() -> keyring_core::Result<()> {
    Err(keyring_core::Error::NotSupportedByStore("此平台沒有系統金鑰庫".into()))
}

fn entry(account: &str) -> anyhow::Result<keyring_core::Entry> {
    ensure_store()?;
    keyring_core::Entry::new(SERVICE, account).map_err(|e| anyhow::anyhow!("金鑰庫項目 {account}: {e}"))
}

/// 讀金鑰。沒設定（或空字串）回 None；讀過一次就進快取（空值也快取），同一個程序內不再碰鑰匙圈。
pub fn get(account: &str) -> Option<String> {
    if let Some(cached) = cache().lock().get(account) {
        return Some(cached.clone()).filter(|v| !v.is_empty());
    }
    let value = match entry(account).map(|e| e.get_password()) {
        Ok(Ok(v)) => v,
        Ok(Err(keyring_core::Error::NoEntry)) => String::new(),
        Ok(Err(e)) => {
            // 讀失敗（例如使用者拒絕鑰匙圈授權）不快取，下次再試
            log::warn!("讀取金鑰 {account} 失敗: {e}");
            return None;
        }
        Err(e) => {
            log::warn!("{e}");
            return None;
        }
    };
    cache().lock().insert(account.to_string(), value.clone());
    Some(value).filter(|v| !v.is_empty())
}

/// 寫入金鑰。空字串等同刪除。只有真的寫成功才更新快取。
pub fn set(account: &str, value: &str) -> anyhow::Result<()> {
    if value.is_empty() {
        return delete(account);
    }
    entry(account)?.set_password(value).map_err(|e| anyhow::anyhow!("寫入金鑰 {account} 失敗: {e}"))?;
    cache().lock().insert(account.to_string(), value.to_string());
    Ok(())
}

pub fn delete(account: &str) -> anyhow::Result<()> {
    match entry(account)?.delete_credential() {
        Ok(()) | Err(keyring_core::Error::NoEntry) => {}
        Err(e) => anyhow::bail!("刪除金鑰 {account} 失敗: {e}"),
    }
    cache().lock().insert(account.to_string(), String::new());
    Ok(())
}

pub fn llm_account(provider_id: &str) -> String { format!("llm.{provider_id}") }
pub fn stt_account(name: &str) -> String { format!("stt.{name}") }

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_with_mock_store() {
        let acc = llm_account("secure-store-test-roundtrip");
        assert_eq!(acc, "llm.secure-store-test-roundtrip");
        assert_eq!(get(&acc), None);
        set(&acc, "sk-123").unwrap();
        assert_eq!(get(&acc).as_deref(), Some("sk-123"));
        set(&acc, "sk-456").unwrap();
        assert_eq!(get(&acc).as_deref(), Some("sk-456"));
        delete(&acc).unwrap();
        assert_eq!(get(&acc), None);
        // 刪不存在的不算錯
        delete(&acc).unwrap();
    }

    #[test]
    fn empty_value_deletes() {
        let acc = stt_account("secure-store-test-empty");
        assert_eq!(acc, "stt.secure-store-test-empty");
        set(&acc, "k").unwrap();
        set(&acc, "").unwrap();
        assert_eq!(get(&acc), None);
    }

    #[test]
    fn cache_survives_backing_store_reads() {
        let acc = llm_account("secure-store-test-cache");
        set(&acc, "v1").unwrap();
        // 直接改底層 store：快取命中時不會看到（證明第二次 get 沒碰鑰匙圈）
        keyring_core::Entry::new(SERVICE, &acc).unwrap().set_password("v2").unwrap();
        assert_eq!(get(&acc).as_deref(), Some("v1"));
    }
}

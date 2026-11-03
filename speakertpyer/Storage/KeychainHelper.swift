//
//  KeychainHelper.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import Foundation
import Security

enum KeychainHelper {
    private static let service = "com.bashcat.speakertpyer"

    private static func account(for providerId: String) -> String {
        "\(providerId)-api-key"
    }

    // MARK: - Per-provider API Key

    #if os(iOS)
    /// iOS 背景處理（鍵盤待命）時可能已鎖機；預設的 WhenUnlocked 會讀不到 key，
    /// 被誤判為「未設定 API Key」。macOS 的檔案型 keychain 不使用此屬性。
    private static let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    private static let accessibilityMigratedKey = "keychainAccessibilityMigrated_v1"

    /// 既有項目一次性改成 AfterFirstUnlockThisDeviceOnly（鎖機時 update 會失敗，下次再試）。
    private static func migrateAccessibilityIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: accessibilityMigratedKey) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let attrs: [String: Any] = [kSecAttrAccessible as String: accessibility]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            UserDefaults.standard.set(true, forKey: accessibilityMigratedKey)
        }
    }
    #endif

    /// 空字串（含只有空白）視為「清除」：刪除該 provider 的 key，而不是寫入空值。
    static func saveAPIKey(_ apiKey: String, for providerId: String) throws {
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            deleteAPIKey(for: providerId)
            return
        }
        guard let data = apiKey.data(using: .utf8) else { return }
        let acct = account(for: providerId)

        // First try to update existing item
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct,
        ]
        var updateAttributes: [String: Any] = [
            kSecValueData as String: data,
        ]
        #if os(iOS)
        updateAttributes[kSecAttrAccessible as String] = accessibility
        #endif
        var status = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)

        if status == errSecItemNotFound {
            // Item doesn't exist, add new one
            var addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: acct,
                kSecValueData as String: data,
            ]
            #if os(iOS)
            addQuery[kSecAttrAccessible as String] = accessibility
            #endif
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            AppLogger.shared.error("Keychain 儲存失敗 (\(providerId)): OSStatus \(status)", category: "Keychain")
            throw KeychainError.saveFailed(status)
        }
        AppLogger.shared.info("已儲存 \(providerId) 的 API Key", category: "Keychain")
    }

    /// 找不到或內容為空（舊版可能存過空字串）都回 nil。
    static func loadAPIKey(for providerId: String) -> String? {
        #if os(iOS)
        migrateAccessibilityIfNeeded()
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: providerId),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, !data.isEmpty,
              let key = String(data: data, encoding: .utf8),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return key
    }

    static func deleteAPIKey(for providerId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: providerId),
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Legacy (backward-compatible, defaults to openrouter)
    // 這三個 method 永遠以 "openrouter" 為對象，會誤判其他 provider 的 key 狀態。
    // 留著只是怕外部還有 caller，新 code 一律用 `for: providerId`。

    @available(*, deprecated, message: "改用 saveAPIKey(_:for:) 並傳入 settingsStore.selectedProvider.id")
    static func saveAPIKey(_ apiKey: String) throws {
        try saveAPIKey(apiKey, for: "openrouter")
    }

    @available(*, deprecated, message: "改用 loadAPIKey(for:) 並傳入 settingsStore.selectedProvider.id")
    static func loadAPIKey() -> String? {
        loadAPIKey(for: "openrouter")
    }

    @available(*, deprecated, message: "改用 deleteAPIKey(for:) 並傳入 settingsStore.selectedProvider.id")
    static func deleteAPIKey() {
        deleteAPIKey(for: "openrouter")
    }
}

enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Keychain save failed with status: \(status)"
        }
    }
}

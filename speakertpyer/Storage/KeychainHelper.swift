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

    static func saveAPIKey(_ apiKey: String, for providerId: String) throws {
        guard let data = apiKey.data(using: .utf8) else { return }
        let acct = account(for: providerId)

        // First try to update existing item
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct,
        ]
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
        ]
        var status = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)

        if status == errSecItemNotFound {
            // Item doesn't exist, add new one
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: acct,
                kSecValueData as String: data,
            ]
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            print("[Keychain] Save failed for \(providerId): OSStatus \(status)")
            throw KeychainError.saveFailed(status)
        }
        print("[Keychain] Saved API key for \(providerId)")
    }

    static func loadAPIKey(for providerId: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: providerId),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
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

    static func saveAPIKey(_ apiKey: String) throws {
        try saveAPIKey(apiKey, for: "openrouter")
    }

    static func loadAPIKey() -> String? {
        loadAPIKey(for: "openrouter")
    }

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

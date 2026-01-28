//
//  AppLanguage.swift
//  speakertpyer
//

import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case zhTW = "zh-TW"
    case zhCN = "zh-CN"
    case en = "en-US"
    case ja = "ja-JP"

    var id: String { rawValue }

    /// Always shown in the target language itself (autonym)
    var displayName: String {
        switch self {
        case .zhTW: return "繁體中文"
        case .zhCN: return "简体中文"
        case .en: return "English"
        case .ja: return "日本語"
        }
    }
}

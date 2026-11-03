//
//  MobileSettings.swift
//  SaybitiOS
//
//  iOS 專屬設定（共用設定仍在 SettingsStore）。
//

import Combine
import Foundation

final class MobileSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    /// App 內錄音完成後自動複製到剪貼簿
    @Published var autoCopyResult: Bool {
        didSet { defaults.set(autoCopyResult, forKey: "ios.autoCopyResult") }
    }

    /// 觸覺回饋
    @Published var hapticFeedback: Bool {
        didSet { defaults.set(hapticFeedback, forKey: "ios.hapticFeedback") }
    }

    /// 鍵盤待命 session 長度（分鐘）。期間 App 在背景保持麥克風，鍵盤可直接開始錄音。
    @Published var keyboardSessionMinutes: Int {
        didSet { defaults.set(keyboardSessionMinutes, forKey: "ios.keyboardSessionMinutes") }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: "ios.hasCompletedOnboarding") }
    }

    static let sessionMinuteOptions = [3, 5, 15, 30, 60]

    init() {
        autoCopyResult = defaults.object(forKey: "ios.autoCopyResult") as? Bool ?? true
        hapticFeedback = defaults.object(forKey: "ios.hapticFeedback") as? Bool ?? true
        keyboardSessionMinutes = defaults.object(forKey: "ios.keyboardSessionMinutes") as? Int ?? 5
        hasCompletedOnboarding = defaults.bool(forKey: "ios.hasCompletedOnboarding")
    }
}

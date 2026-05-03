//
//  SimpleToggleSections.swift
//  speakertpyer
//
//  從 GeneralSettingsView 拆出來的、只依賴 settingsStore 與 searchState 的
//  純設定區塊。新增同類 section 時加在這裡，避免 GeneralSettingsView 一直膨脹。
//

import SwiftUI

// MARK: - 開機自動啟動

struct LaunchAtLoginSection: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var searchState: SettingsSearchState

    var body: some View {
        if settingsMatchesSearch(["開機", "啟動", "登入", "launch", "login", "自動啟動", "startup", "开机", "启动"],
                                 searchText: searchState.searchText) {
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    GlassSectionHeader(title: L10n.General.launchAtLogin, icon: "power")

                    Toggle(L10n.General.enableLaunchAtLogin, isOn: $settingsStore.launchAtLogin)
                    Text(L10n.General.launchAtLoginDesc)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                }
            }
        }
    }
}

// MARK: - 自動檢查更新

struct AutoUpdateCheckSection: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var searchState: SettingsSearchState

    var body: some View {
        if settingsMatchesSearch(["更新", "update", "version", "版本", "auto-update"],
                                 searchText: searchState.searchText) {
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    GlassSectionHeader(title: L10n.Update.checkButton, icon: "arrow.down.circle")

                    Toggle(L10n.General.enableAutoUpdateCheck, isOn: $settingsStore.enableAutoUpdateCheck)
                    Text(L10n.General.autoUpdateCheckDesc)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)

                    if !settingsStore.availableUpdateTag.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.green)
                            Text(L10n.Update.newer(latest: settingsStore.availableUpdateTag,
                                                   current: UpdateChecker.shared.currentVersion()))
                                .font(.body)
                            if let url = URL(string: settingsStore.availableUpdateURL),
                               !settingsStore.availableUpdateURL.isEmpty {
                                Link(L10n.Update.viewRelease, destination: url)
                                    .font(.body)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            }
        }
    }
}

// MARK: - 語言

struct LanguageSection: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var searchState: SettingsSearchState

    var body: some View {
        if settingsMatchesSearch(["語言", "语言", "language", "言語", "介面"],
                                 searchText: searchState.searchText) {
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    GlassSectionHeader(title: L10n.General.language, icon: "globe")

                    Picker(L10n.General.preferredLanguage, selection: $settingsStore.languagePreference) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(settingsStore.enableAutoLanguageDetection)

                    Divider().opacity(0.3)

                    Toggle(L10n.General.autoLanguageDetection, isOn: $settingsStore.enableAutoLanguageDetection)
                    Text(L10n.General.autoLanguageDetectionDesc)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                }
            }
        }
    }
}

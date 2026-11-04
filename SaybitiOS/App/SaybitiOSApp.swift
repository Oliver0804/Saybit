//
//  SaybitiOSApp.swift
//  SaybitiOS
//

import SwiftUI

/// App 層級的單例容器（App Intents 也需要取用同一個 pipeline）
@MainActor
final class AppServices {
    static let shared = AppServices()

    let settingsStore: SettingsStore
    let mobileSettings: MobileSettings
    let pipeline: MobileVoicePipeline
    let persistence = PersistenceController.shared

    private init() {
        let store = SettingsStore()
        SettingsStore.shared = store
        settingsStore = store
        mobileSettings = MobileSettings()
        pipeline = MobileVoicePipeline(settingsStore: store, mobileSettings: mobileSettings)
        cleanupHistoryIfNeeded()
    }

    private func cleanupHistoryIfNeeded() {
        guard settingsStore.enableHistoryAutoCleanup else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -settingsStore.historyRetentionDays, to: Date()) ?? Date()
        try? persistence.deleteRecords(olderThan: cutoff)
    }
}

@main
struct SaybitiOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let services = AppServices.shared
    @State private var selectedTab: RootView.Tab = .dictation

    var body: some Scene {
        WindowGroup {
            RootView(selectedTab: $selectedTab)
                .environment(services.pipeline)
                .environmentObject(services.settingsStore)
                .environmentObject(services.mobileSettings)
                .environment(\.managedObjectContext, services.persistence.container.viewContext)
                .onOpenURL(perform: handleURL)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                services.pipeline.sceneDidEnterBackground()
            }
        }
    }

    /// saybit://dictate?source=keyboard  — 鍵盤叫醒 App 開始錄音
    /// saybit://dictate                    — 一般開始錄音（小工具 / 捷徑）
    private func handleURL(_ url: URL) {
        guard url.scheme == SaybitShared.urlScheme else { return }
        let source = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "source" })?.value
        switch url.host {
        case "dictate":
            selectedTab = .dictation
            if source == "keyboard" {
                services.pipeline.handleKeyboardLaunch()
            } else if !services.pipeline.isBusy {
                services.pipeline.startRecording(source: .app)
            }
        default:
            break
        }
    }
}

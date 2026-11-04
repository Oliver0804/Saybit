//
//  RootView.swift
//  SaybitiOS
//

import SwiftUI

struct RootView: View {
    enum Tab: Hashable {
        case dictation, history, library, settings
    }

    @Binding var selectedTab: Tab
    @EnvironmentObject private var mobileSettings: MobileSettings

    var body: some View {
        if mobileSettings.hasCompletedOnboarding {
            TabView(selection: $selectedTab) {
                SwiftUI.Tab("語音", systemImage: "mic.fill", value: Tab.dictation) {
                    DictationView()
                }
                SwiftUI.Tab("歷史", systemImage: "clock.arrow.circlepath", value: Tab.history) {
                    HistoryListView()
                }
                SwiftUI.Tab("詞庫", systemImage: "character.book.closed", value: Tab.library) {
                    LibraryView()
                }
                SwiftUI.Tab("設定", systemImage: "gearshape", value: Tab.settings) {
                    SettingsRootView()
                }
            }
        } else {
            OnboardingView()
        }
    }
}

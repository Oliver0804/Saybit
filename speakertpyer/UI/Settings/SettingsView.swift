//
//  SettingsView.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label(L10n.Tabs.general, systemImage: "gear")
                }

            APISettingsView()
                .tabItem {
                    Label(L10n.Tabs.api, systemImage: "key.fill")
                }

            PromptSettingsView()
                .tabItem {
                    Label(L10n.Tabs.prompt, systemImage: "text.bubble")
                }

            HotKeySettingsView()
                .tabItem {
                    Label(L10n.Tabs.hotkey, systemImage: "keyboard")
                }

            DictionarySettingsView()
                .tabItem {
                    Label(L10n.Tabs.dictionary, systemImage: "book")
                }

            HistoryView()
                .tabItem {
                    Label(L10n.Tabs.history, systemImage: "clock")
                }

            StatisticsView()
                .tabItem {
                    Label(L10n.Tabs.statistics, systemImage: "chart.bar.fill")
                }
        }
        .frame(minWidth: 680, idealWidth: 680, maxWidth: .infinity,
               minHeight: 500, idealHeight: 720, maxHeight: .infinity)
        .id(settingsStore.languagePreference)
    }
}

// MARK: - Glass Card Style

struct GlassCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.3), .white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
    }
}

struct GlassSectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        }
        .padding(.bottom, 4)
    }
}

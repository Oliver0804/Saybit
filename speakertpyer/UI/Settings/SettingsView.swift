//
//  SettingsView.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import Combine
import SwiftUI

// MARK: - Search State

class SettingsSearchState: ObservableObject {
    @Published var searchText = ""
}

// MARK: - Search Helper

func settingsMatchesSearch(_ keywords: [String], searchText: String) -> Bool {
    guard !searchText.isEmpty else { return true }
    let query = searchText.lowercased()
    return keywords.contains { $0.lowercased().contains(query) }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @StateObject private var searchState = SettingsSearchState()

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L10n.Common.searchSettings, text: $searchState.searchText)
                    .textFieldStyle(.plain)
                if !searchState.searchText.isEmpty {
                    Button {
                        searchState.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.06))
            )
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)

            TabView {
                GeneralSettingsView()
                    .environmentObject(searchState)
                    .tabItem {
                        Label(L10n.Tabs.general, systemImage: "gear")
                    }

                APISettingsView()
                    .environmentObject(searchState)
                    .tabItem {
                        Label(L10n.Tabs.ai, systemImage: "cpu")
                    }

                HotKeySettingsView()
                    .environmentObject(searchState)
                    .tabItem {
                        Label(L10n.Tabs.hotkey, systemImage: "keyboard")
                    }

                DictionarySettingsView()
                    .environmentObject(searchState)
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
        }
        .frame(minWidth: 800, idealWidth: 800, maxWidth: .infinity,
               minHeight: 600, idealHeight: 800, maxHeight: .infinity)
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
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        }
        .padding(.bottom, 8)
    }
}

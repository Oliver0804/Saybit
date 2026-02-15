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

// MARK: - Settings Tab

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, api, hotkey, dictionary, history, statistics, logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L10n.Tabs.general
        case .api: return L10n.Tabs.ai
        case .hotkey: return L10n.Tabs.hotkey
        case .dictionary: return L10n.Tabs.dictionary
        case .history: return L10n.Tabs.history
        case .statistics: return L10n.Tabs.statistics
        case .logs: return L10n.Tabs.logs
        }
    }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .api: return "cpu"
        case .hotkey: return "keyboard"
        case .dictionary: return "book"
        case .history: return "clock"
        case .statistics: return "chart.bar.fill"
        case .logs: return "doc.text.magnifyingglass"
        }
    }

    var iconColor: Color {
        switch self {
        case .general: return .gray
        case .api: return .purple
        case .hotkey: return .orange
        case .dictionary: return .blue
        case .history: return .green
        case .statistics: return .pink
        case .logs: return .brown
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @StateObject private var searchState = SettingsSearchState()
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(spacing: 0) {
                // Search bar
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    TextField(L10n.Common.searchSettings, text: $searchState.searchText)
                        .textFieldStyle(.plain)
                        .font(.callout)
                    if !searchState.searchText.isEmpty {
                        Button {
                            searchState.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(7)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(0.06))
                )
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

                // Tab list
                VStack(spacing: 2) {
                    ForEach(SettingsTab.allCases) { tab in
                        SidebarRow(
                            tab: tab,
                            isSelected: selectedTab == tab
                        ) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedTab = tab
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)

                Spacer()

                // Version info
                Text("Saybit v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                    .padding(.bottom, 12)
            }
            .frame(width: 200)
            .background(Color(.windowBackgroundColor).opacity(0.4))

            // Divider
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)

            // Detail content
            Group {
                switch selectedTab {
                case .general:
                    GeneralSettingsView()
                        .environmentObject(searchState)
                case .api:
                    APISettingsView()
                        .environmentObject(searchState)
                case .hotkey:
                    HotKeySettingsView()
                        .environmentObject(searchState)
                case .dictionary:
                    DictionarySettingsView()
                        .environmentObject(searchState)
                case .history:
                    HistoryView()
                case .statistics:
                    StatisticsView()
                case .logs:
                    LogsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1000, idealWidth: 1000, maxWidth: .infinity,
               minHeight: 600, idealHeight: 800, maxHeight: .infinity)
        .id(settingsStore.languagePreference)
    }
}

// MARK: - Sidebar Row

struct SidebarRow: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? tab.iconColor : .secondary)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isSelected ? tab.iconColor.opacity(0.15) : .clear)
                    )

                Text(tab.title)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? .primary : .secondary)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected
                        ? Color.accentColor.opacity(0.12)
                        : isHovered ? Color.primary.opacity(0.04) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
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

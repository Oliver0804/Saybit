//
//  SettingsView.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("一般", systemImage: "gear")
                }

            APISettingsView()
                .tabItem {
                    Label("API", systemImage: "key.fill")
                }

            PromptSettingsView()
                .tabItem {
                    Label("Prompt", systemImage: "text.bubble")
                }

            HotKeySettingsView()
                .tabItem {
                    Label("快捷鍵", systemImage: "keyboard")
                }

            DictionarySettingsView()
                .tabItem {
                    Label("字典", systemImage: "book")
                }

            HistoryView()
                .tabItem {
                    Label("歷史", systemImage: "clock")
                }

            StatisticsView()
                .tabItem {
                    Label("統計", systemImage: "chart.bar.fill")
                }
        }
        .frame(width: 680, height: 640)
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

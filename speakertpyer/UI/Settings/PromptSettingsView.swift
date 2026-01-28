//
//  PromptSettingsView.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import SwiftUI

struct PromptSettingsView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var searchState: SettingsSearchState

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // MARK: - Prompt 風格
                if settingsMatchesSearch(["prompt", "風格", "style", "提示詞", "提示词", "模式"], searchText: searchState.searchText) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            GlassSectionHeader(title: L10n.Prompt.promptStyle, icon: "text.bubble")

                            Picker("", selection: $settingsStore.promptStyle) {
                                ForEach(PromptStyle.allCases) { style in
                                    Text(style.displayName).tag(style)
                                }
                            }
                            .pickerStyle(.radioGroup)

                            promptDescription
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                        }
                    }
                }

                // MARK: - 語調
                if settingsMatchesSearch(["語氣", "tone", "語調", "语气", "語調"], searchText: searchState.searchText) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            GlassSectionHeader(title: L10n.Prompt.tone, icon: "theatermasks")

                            Picker("", selection: $settingsStore.toneStyle) {
                                ForEach(ToneStyle.allCases) { tone in
                                    Text(tone.displayName).tag(tone)
                                }
                            }
                            .pickerStyle(.radioGroup)

                            Text(L10n.Prompt.toneAutoDesc)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                        }
                    }
                }

                if !searchState.searchText.isEmpty
                    && !settingsMatchesSearch(["prompt", "風格", "style", "提示詞", "提示词", "模式"], searchText: searchState.searchText)
                    && !settingsMatchesSearch(["語氣", "tone", "語調", "语气", "語調"], searchText: searchState.searchText)
                {
                    Text(L10n.Common.noResults)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private var promptDescription: some View {
        switch settingsStore.promptStyle {
        case .typeless:
            Text(L10n.Prompt.typelessDesc)
        case .wisprFlow:
            Text(L10n.Prompt.wisprFlowDesc)
        }
    }
}

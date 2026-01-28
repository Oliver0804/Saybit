//
//  PromptSettingsView.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import SwiftUI

struct PromptSettingsView: View {
    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // MARK: - Prompt 風格
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

                // MARK: - 語調
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

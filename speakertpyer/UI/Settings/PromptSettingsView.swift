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
                        GlassSectionHeader(title: "Prompt 風格", icon: "text.bubble")

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
                        GlassSectionHeader(title: "語調", icon: "theatermasks")

                        Picker("", selection: $settingsStore.toneStyle) {
                            ForEach(ToneStyle.allCases) { tone in
                                Text(tone.displayName).tag(tone)
                            }
                        }
                        .pickerStyle(.radioGroup)

                        Text("「自動」會根據當前 App 推斷語調（Slack → 口語，Mail → 正式）")
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
            Text("強調意圖理解、自動格式化清單、去贅詞/改口修正。適合一般文字輸入。")
        case .wisprFlow:
            Text("強調開發者功能（變數命名、CLI 命令）、Command Mode。適合程式開發。")
        }
    }
}

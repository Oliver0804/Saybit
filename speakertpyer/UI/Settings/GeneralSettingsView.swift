//
//  GeneralSettingsView.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @State private var accessibilityAuthorized = AccessibilityManager.shared.isAuthorized
    @State private var micAuthorized = AudioSessionManager.isMicrophoneAuthorized

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // MARK: - 語言
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        GlassSectionHeader(title: "語言", icon: "globe")

                        Picker("偏好語言", selection: $settingsStore.languagePreference) {
                            Text("繁體中文").tag("zh-TW")
                            Text("English").tag("en-US")
                            Text("日本語").tag("ja-JP")
                        }
                        .pickerStyle(.segmented)
                    }
                }

                // MARK: - 功能開關
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        GlassSectionHeader(title: "功能", icon: "switch.2")

                        Toggle("Context Awareness", isOn: $settingsStore.enableContextAwareness)
                        Text("讀取目前選取的文字作為上下文")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)

                        Divider().opacity(0.3)

                        Toggle("On-Device STT", isOn: $settingsStore.enableOnDeviceSTT)
                        Text("使用本地語音辨識，不需網路")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)

                        Divider().opacity(0.3)

                        Toggle("音效回饋", isOn: $settingsStore.enableSoundFeedback)

                        Divider().opacity(0.3)

                        Toggle("Whisper Mode", isOn: $settingsStore.enableWhisperMode)
                        Text("提示 LLM 過濾背景噪音與雜訊")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)
                    }
                }

                // MARK: - 麥克風靈敏度
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        GlassSectionHeader(title: "麥克風靈敏度", icon: "mic.fill")

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("增益倍數")
                                Spacer()
                                Text(String(format: "%.1fx", settingsStore.micSensitivity))
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $settingsStore.micSensitivity, in: 0.5...5.0, step: 0.5)
                            Text("調高此值可讓音量顯示更靈敏，建議錄音時觀察音量條調整至 3-4 格")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // MARK: - 自動停止
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        GlassSectionHeader(title: "靜音自動停止", icon: "waveform.slash")

                        Toggle("啟用自動停止", isOn: $settingsStore.enableAutoStop)

                        if settingsStore.enableAutoStop {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("靜音等待時間")
                                    Spacer()
                                    Text(String(format: "%.1f 秒", settingsStore.silenceTimeout))
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: $settingsStore.silenceTimeout, in: 0.5...5.0, step: 0.5)
                                Text("說完話後等待此時間未偵測到聲音即自動結束錄音")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.leading, 2)
                        }
                    }
                }

                // MARK: - 權限狀態
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        GlassSectionHeader(title: "權限狀態", icon: "lock.shield")

                        HStack {
                            Image(systemName: "hand.raised.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text("Accessibility")
                            Spacer()
                            if accessibilityAuthorized {
                                Label("已授權", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else {
                                Button("開啟設定") {
                                    AccessibilityManager.shared.promptIfNeeded()
                                }
                                .controlSize(.small)
                                .buttonStyle(.bordered)
                            }
                        }

                        Divider().opacity(0.3)

                        HStack {
                            Image(systemName: "mic.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text("麥克風")
                            Spacer()
                            if micAuthorized {
                                Label("已授權", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else {
                                Button("開啟設定") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .controlSize(.small)
                                .buttonStyle(.bordered)
                            }
                        }

                        Divider().opacity(0.3)

                        HStack {
                            Spacer()
                            Button {
                                refreshPermissions()
                            } label: {
                                Label("重新檢查", systemImage: "arrow.clockwise")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
            .padding(20)
        }
        .onAppear {
            refreshPermissions()
        }
    }

    private func refreshPermissions() {
        accessibilityAuthorized = AccessibilityManager.shared.isAuthorized
        micAuthorized = AudioSessionManager.isMicrophoneAuthorized
    }
}

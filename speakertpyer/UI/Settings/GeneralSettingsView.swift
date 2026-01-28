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
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var micTestLevel: Float = 0
    @State private var isMicTesting: Bool = false
    @StateObject private var micTester = MicLevelTester()

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

                // MARK: - 膠囊大小
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        GlassSectionHeader(title: "膠囊大小", icon: "arrow.up.left.and.arrow.down.right")

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("縮放比例")
                                Spacer()
                                Text(String(format: "%.0f%%", settingsStore.capsuleScale * 100))
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $settingsStore.capsuleScale, in: 0.5...2.0, step: 0.1)
                            Text("調整浮動膠囊的顯示大小")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // MARK: - 輸入裝置
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        GlassSectionHeader(title: "輸入裝置", icon: "mic.badge.xmark")

                        Picker("輸入裝置", selection: $settingsStore.selectedInputDeviceUID) {
                            Text("系統預設").tag("")
                            ForEach(inputDevices) { device in
                                Text(device.name).tag(device.uid)
                            }
                        }

                        Text("選擇語音輸入使用的麥克風")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Divider().opacity(0.3)

                        // 音量偵測
                        HStack(spacing: 8) {
                            Button {
                                toggleMicTest()
                            } label: {
                                Label(isMicTesting ? "停止測試" : "測試麥克風", systemImage: isMicTesting ? "stop.fill" : "waveform")
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                            .tint(isMicTesting ? .red : .accentColor)

                            // 音量條
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.primary.opacity(0.1))
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(micTester.level > 0.6 ? Color.green : micTester.level > 0.3 ? Color.yellow : Color.green.opacity(0.7))
                                        .frame(width: geo.size.width * CGFloat(micTester.level))
                                        .animation(.linear(duration: 0.05), value: micTester.level)
                                }
                            }
                            .frame(height: 8)

                            Text(String(format: "%.0f%%", micTester.level * 100))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                        .frame(height: 24)

                        if isMicTesting {
                            Text("對麥克風說話，觀察音量條是否有反應")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
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

                // MARK: - Smart Send
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        GlassSectionHeader(title: "Smart Send", icon: "paperplane.fill")

                        Toggle("啟用 Smart Send", isOn: $settingsStore.enableSmartSend)
                        Text("文字貼上後自動倒數，到期自動按下 Enter 送出")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)

                        if settingsStore.enableSmartSend {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("倒數秒數")
                                    Spacer()
                                    Text(String(format: "%.1f 秒", settingsStore.smartSendDelay))
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: $settingsStore.smartSendDelay, in: 1.0...10.0, step: 0.5)
                                Text("倒數期間若偵測到說話，會自動取消送出")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.leading, 2)
                        }
                    }
                }

                // MARK: - 歷史記錄清理
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        GlassSectionHeader(title: "歷史記錄清理", icon: "clock.arrow.circlepath")

                        Toggle("自動清理舊紀錄", isOn: $settingsStore.enableHistoryAutoCleanup)

                        if settingsStore.enableHistoryAutoCleanup {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("保留天數")
                                    Spacer()
                                    Text("\(settingsStore.historyRetentionDays) 天")
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Slider(
                                    value: Binding(
                                        get: { Double(settingsStore.historyRetentionDays) },
                                        set: { settingsStore.historyRetentionDays = Int($0) }
                                    ),
                                    in: 7...90,
                                    step: 1
                                )
                                Text("超過此天數的歷史紀錄會在開啟時自動清除")
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
            inputDevices = AudioSessionManager.listInputDevices()
        }
    }

    private func toggleMicTest() {
        if isMicTesting {
            micTester.stop()
            isMicTesting = false
        } else {
            micTester.start(inputDeviceUID: settingsStore.selectedInputDeviceUID)
            isMicTesting = true
        }
    }

    private func refreshPermissions() {
        accessibilityAuthorized = AccessibilityManager.shared.isAuthorized
        micAuthorized = AudioSessionManager.isMicrophoneAuthorized
    }
}

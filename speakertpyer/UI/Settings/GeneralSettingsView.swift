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

    // Whisper API Key states
    @State private var whisperAPIKeyInput: String = ""
    @State private var showWhisperKey: Bool = false
    @State private var isTestingWhisper: Bool = false
    @State private var whisperTestStatus: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // MARK: - 語言
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        GlassSectionHeader(title: L10n.General.language, icon: "globe")

                        Picker(L10n.General.preferredLanguage, selection: $settingsStore.languagePreference) {
                            ForEach(AppLanguage.allCases) { lang in
                                Text(lang.displayName).tag(lang.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                // MARK: - 功能開關
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        GlassSectionHeader(title: L10n.General.features, icon: "switch.2")

                        Toggle(L10n.General.contextAwareness, isOn: $settingsStore.enableContextAwareness)
                        Text(L10n.General.contextAwarenessDesc)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)

                        Divider().opacity(0.3)

                        Toggle(L10n.General.soundFeedback, isOn: $settingsStore.enableSoundFeedback)

                        Divider().opacity(0.3)

                        Toggle(L10n.General.whisperMode, isOn: $settingsStore.enableWhisperMode)
                        Text(L10n.General.whisperModeDesc)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)
                    }
                }

                // MARK: - 語音辨識引擎
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        GlassSectionHeader(title: L10n.General.sttEngine, icon: "waveform.circle")

                        Picker(L10n.General.sttEnginePicker, selection: $settingsStore.sttEngine) {
                            ForEach(STTEngine.allCases, id: \.self) { engine in
                                Text(engine.displayName).tag(engine)
                            }
                        }
                        .pickerStyle(.segmented)

                        if settingsStore.sttEngine == .whisperAPI {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(L10n.General.whisperAPIKey)
                                    Spacer()
                                    whisperAPIKeyStatus
                                }

                                HStack(spacing: 8) {
                                    if showWhisperKey {
                                        TextField("sk-...", text: $whisperAPIKeyInput)
                                            .textFieldStyle(.roundedBorder)
                                    } else {
                                        SecureField("sk-...", text: $whisperAPIKeyInput)
                                            .textFieldStyle(.roundedBorder)
                                    }

                                    Button {
                                        showWhisperKey.toggle()
                                    } label: {
                                        Image(systemName: showWhisperKey ? "eye.slash" : "eye")
                                    }
                                    .buttonStyle(.borderless)

                                    Button(L10n.Common.save) {
                                        saveWhisperAPIKey()
                                    }
                                    .controlSize(.small)
                                    .buttonStyle(.bordered)
                                    .disabled(whisperAPIKeyInput.isEmpty)
                                }

                                HStack(spacing: 8) {
                                    Button {
                                        testWhisperConnection()
                                    } label: {
                                        Label(
                                            whisperTestStatus ?? L10n.Common.testConnection,
                                            systemImage: whisperTestStatus == L10n.Common.connectionSuccess ? "checkmark.circle.fill" : "bolt.horizontal"
                                        )
                                    }
                                    .controlSize(.small)
                                    .buttonStyle(.bordered)
                                    .tint(whisperTestStatus == L10n.Common.connectionSuccess ? .green : .accentColor)
                                    .disabled(isTestingWhisper)

                                    if isTestingWhisper {
                                        ProgressView()
                                            .scaleEffect(0.5)
                                    }
                                }

                                Text(L10n.General.whisperDesc)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.leading, 2)
                        }

                        if settingsStore.sttEngine == .appleSpeech {
                            Divider().opacity(0.3)

                            Toggle(L10n.General.onDeviceSTT, isOn: $settingsStore.enableOnDeviceSTT)
                            Text(L10n.General.onDeviceSTTDesc)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 2)
                        }
                    }
                }

                // MARK: - 膠囊大小
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        GlassSectionHeader(title: L10n.General.capsuleSize, icon: "arrow.up.left.and.arrow.down.right")

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(L10n.General.scaleRatio)
                                Spacer()
                                Text(String(format: "%.0f%%", settingsStore.capsuleScale * 100))
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $settingsStore.capsuleScale, in: 0.5...2.0, step: 0.1)
                            Text(L10n.General.capsuleSizeDesc)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // MARK: - 輸入裝置
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        GlassSectionHeader(title: L10n.General.inputDevice, icon: "mic.badge.xmark")

                        Picker(L10n.General.inputDevice, selection: $settingsStore.selectedInputDeviceUID) {
                            Text(L10n.General.systemDefault).tag("")
                            ForEach(inputDevices) { device in
                                Text(device.name).tag(device.uid)
                            }
                        }

                        Text(L10n.General.selectMicDesc)
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Divider().opacity(0.3)

                        // 音量偵測
                        HStack(spacing: 8) {
                            Button {
                                toggleMicTest()
                            } label: {
                                Label(isMicTesting ? L10n.General.stopTest : L10n.General.testMic, systemImage: isMicTesting ? "stop.fill" : "waveform")
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
                            Text(L10n.General.micTestHint)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // MARK: - 麥克風靈敏度
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        GlassSectionHeader(title: L10n.General.micSensitivity, icon: "mic.fill")

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(L10n.General.gainMultiplier)
                                Spacer()
                                Text(String(format: "%.1fx", settingsStore.micSensitivity))
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $settingsStore.micSensitivity, in: 0.5...5.0, step: 0.5)
                            Text(L10n.General.micSensitivityDesc)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // MARK: - 自動停止
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        GlassSectionHeader(title: L10n.General.silenceAutoStop, icon: "waveform.slash")

                        Toggle(L10n.General.enableAutoStop, isOn: $settingsStore.enableAutoStop)

                        if settingsStore.enableAutoStop {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(L10n.General.silenceTimeout)
                                    Spacer()
                                    Text(L10n.General.seconds(settingsStore.silenceTimeout))
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: $settingsStore.silenceTimeout, in: 0.5...5.0, step: 0.5)
                                Text(L10n.General.silenceAutoStopDesc)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.leading, 2)
                        }
                    }
                }

                // MARK: - 注入前預覽
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        GlassSectionHeader(title: L10n.General.previewBeforeInject, icon: "eye")

                        Toggle(L10n.General.enablePreview, isOn: $settingsStore.enablePreviewBeforeInject)
                        Text(L10n.General.previewDesc)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)
                    }
                }

                // MARK: - Smart Send
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        GlassSectionHeader(title: L10n.General.smartSend, icon: "paperplane.fill")

                        Toggle(L10n.General.enableSmartSend, isOn: $settingsStore.enableSmartSend)
                        Text(L10n.General.smartSendDesc)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)

                        if settingsStore.enableSmartSend {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(L10n.General.countdownSeconds)
                                    Spacer()
                                    Text(L10n.General.seconds(settingsStore.smartSendDelay))
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: $settingsStore.smartSendDelay, in: 1.0...10.0, step: 0.5)
                                Text(L10n.General.smartSendCancelHint)
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
                        GlassSectionHeader(title: L10n.General.historyCleanup, icon: "clock.arrow.circlepath")

                        Toggle(L10n.General.autoCleanup, isOn: $settingsStore.enableHistoryAutoCleanup)

                        if settingsStore.enableHistoryAutoCleanup {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(L10n.General.retentionDays)
                                    Spacer()
                                    Text(L10n.General.days(settingsStore.historyRetentionDays))
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
                                Text(L10n.General.historyCleanupDesc)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.leading, 2)
                        }
                    }
                }

                // MARK: - Tutorial
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        GlassSectionHeader(title: L10n.General.tutorial, icon: "book.fill")

                        Button {
                            NotificationCenter.default.post(name: .showTutorial, object: nil)
                        } label: {
                            Label(L10n.General.replayTutorial, systemImage: "play.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                // MARK: - 權限狀態
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        GlassSectionHeader(title: L10n.General.permissionStatus, icon: "lock.shield")

                        HStack {
                            Image(systemName: "hand.raised.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text(L10n.General.accessibility)
                            Spacer()
                            if accessibilityAuthorized {
                                Label(L10n.Common.authorized, systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else {
                                Button(L10n.Common.openSettings) {
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
                            Text(L10n.General.microphone)
                            Spacer()
                            if micAuthorized {
                                Label(L10n.Common.authorized, systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else {
                                Button(L10n.Common.openSettings) {
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
                                Label(L10n.Common.recheck, systemImage: "arrow.clockwise")
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
            // Load existing Whisper API key hint
            if let existing = KeychainHelper.loadAPIKey(for: "whisper_api"), !existing.isEmpty {
                whisperAPIKeyInput = ""  // Don't show actual key
            }
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

    // MARK: - Whisper API Key

    @ViewBuilder
    private var whisperAPIKeyStatus: some View {
        if KeychainHelper.loadAPIKey(for: "whisper_api") != nil {
            Label(L10n.Common.set, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            Label(L10n.Common.notSet, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func saveWhisperAPIKey() {
        try? KeychainHelper.saveAPIKey(whisperAPIKeyInput, for: "whisper_api")
        whisperAPIKeyInput = ""
        whisperTestStatus = nil
    }

    private func testWhisperConnection() {
        isTestingWhisper = true
        whisperTestStatus = nil
        Task {
            do {
                let client = WhisperSTTClient()
                try await client.testConnection()
                await MainActor.run {
                    whisperTestStatus = L10n.Common.connectionSuccess
                    isTestingWhisper = false
                }
            } catch {
                await MainActor.run {
                    whisperTestStatus = error.localizedDescription
                    isTestingWhisper = false
                }
            }
        }
    }
}

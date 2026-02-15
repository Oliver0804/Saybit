//
//  GeneralSettingsView.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import EventKit
import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var searchState: SettingsSearchState
    @State private var accessibilityAuthorized = AccessibilityManager.shared.isAuthorized
    @State private var micAuthorized = AudioSessionManager.isMicrophoneAuthorized
    @State private var automationAuthorized = false
    @State private var remindersAuthorized = false
    @State private var calendarAuthorized = false
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var micTestLevel: Float = 0
    @State private var isMicTesting: Bool = false
    @StateObject private var micTester = MicLevelTester()

    // Whisper API Key states
    @State private var whisperAPIKeyInput: String = ""
    @State private var showWhisperKey: Bool = false
    @State private var isTestingWhisper: Bool = false
    @State private var whisperTestStatus: String?
    @State private var showContextRulesSheet: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // MARK: - 開機自動啟動
                if settingsMatchesSearch(["開機", "啟動", "登入", "launch", "login", "自動啟動", "startup", "开机", "启动"], searchText: searchState.searchText) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            GlassSectionHeader(title: L10n.General.launchAtLogin, icon: "power")

                            Toggle(L10n.General.enableLaunchAtLogin, isOn: $settingsStore.launchAtLogin)
                            Text(L10n.General.launchAtLoginDesc)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 2)
                        }
                    }
                }

                // MARK: - 語言
                if settingsMatchesSearch(["語言", "语言", "language", "言語", "介面"], searchText: searchState.searchText) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            GlassSectionHeader(title: L10n.General.language, icon: "globe")

                            Picker(L10n.General.preferredLanguage, selection: $settingsStore.languagePreference) {
                                ForEach(AppLanguage.allCases) { lang in
                                    Text(lang.displayName).tag(lang.rawValue)
                                }
                            }
                            .pickerStyle(.segmented)
                            .disabled(settingsStore.enableAutoLanguageDetection)

                            Divider().opacity(0.3)

                            Toggle(L10n.General.autoLanguageDetection, isOn: $settingsStore.enableAutoLanguageDetection)
                            Text(L10n.General.autoLanguageDetectionDesc)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 2)
                        }
                    }
                }

                // MARK: - 功能開關
                if settingsMatchesSearch(["功能", "features", "context", "上下文", "音效", "sound", "whisper"], searchText: searchState.searchText) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            GlassSectionHeader(title: L10n.General.features, icon: "switch.2")

                            Toggle(L10n.General.contextAwareness, isOn: $settingsStore.enableContextAwareness)
                            Text(L10n.General.contextAwarenessDesc)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 2)

                            Divider().opacity(0.3)

                            Toggle(L10n.General.soundFeedback, isOn: $settingsStore.enableSoundFeedback)

                            Divider().opacity(0.3)

                            Toggle(L10n.General.whisperMode, isOn: $settingsStore.enableWhisperMode)
                            Text(L10n.General.whisperModeDesc)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 2)

                            if settingsStore.enableContextAwareness {
                                Divider().opacity(0.3)

                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(L10n.General.contextRules)
                                            .font(.body)
                                        Text(L10n.General.contextRulesDesc)
                                            .font(.body)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button {
                                        showContextRulesSheet = true
                                    } label: {
                                        Label(L10n.General.contextRulesManage, systemImage: "list.bullet.rectangle")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }

                // MARK: - 語音辨識引擎
                if settingsMatchesSearch(["語音辨識", "语音识别", "speech", "STT", "engine", "whisper", "引擎"], searchText: searchState.searchText) {
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
                                        .font(.body)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.leading, 2)
                            }

                            if settingsStore.sttEngine == .appleSpeech {
                                Divider().opacity(0.3)

                                Toggle(L10n.General.onDeviceSTT, isOn: $settingsStore.enableOnDeviceSTT)
                                Text(L10n.General.onDeviceSTTDesc)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 2)

                                Divider().opacity(0.3)

                                Toggle("持續背景辨識", isOn: $settingsStore.enableContinuousSTT)
                                Text("開啟後 STT 在背景持續運行，按快捷鍵時直接截取文字，完全消除開頭語音遺失。會增加少許 CPU 使用。")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 2)
                            }
                        }
                    }
                }

                // MARK: - 膠囊大小
                if settingsMatchesSearch(["膠囊", "胶囊", "capsule", "大小", "size", "縮放", "scale"], searchText: searchState.searchText) {
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
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // MARK: - 輸入裝置與麥克風靈敏度
                if settingsMatchesSearch(["輸入裝置", "输入设备", "input", "device", "麥克風", "麦克风", "microphone", "mic", "靈敏度", "灵敏度", "sensitivity", "gain"], searchText: searchState.searchText) {
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
                                .font(.body)
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
                                    .font(.system(.title3, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40, alignment: .trailing)
                            }
                            .frame(height: 24)

                            if isMicTesting {
                                Text(L10n.General.micTestHint)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }

                            Divider().opacity(0.3)

                            // 麥克風靈敏度
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
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // MARK: - 自動停止
                if settingsMatchesSearch(["自動停止", "auto stop", "靜音", "silence", "自动停止"], searchText: searchState.searchText) {
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
                                        .font(.body)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.leading, 2)
                            }
                        }
                    }
                }

                // MARK: - 注入方式
                if settingsMatchesSearch(["注入", "inject", "貼上", "paste", "keypress", "逐字", "取代", "replace"], searchText: searchState.searchText) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            GlassSectionHeader(title: L10n.General.injectionMode, icon: "keyboard")

                            Picker(L10n.General.injectionMode, selection: $settingsStore.injectionMode) {
                                ForEach(InjectionMode.allCases, id: \.self) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)

                            Text(L10n.General.injectionModeDesc)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 2)
                        }
                    }
                }

                // MARK: - 預覽與送出
                if settingsMatchesSearch(["預覽", "preview", "注入", "inject", "预览", "smart send", "倒數", "countdown", "自動送出", "自动发送"], searchText: searchState.searchText) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            GlassSectionHeader(title: L10n.General.previewAndSend, icon: "text.badge.checkmark")

                            Toggle(L10n.General.enablePreview, isOn: $settingsStore.enablePreviewBeforeInject)
                            Text(L10n.General.previewDesc)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 2)

                            if settingsStore.enablePreviewBeforeInject {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(L10n.General.previewTimeout)
                                        Spacer()
                                        Text(L10n.General.seconds(settingsStore.previewTimeout))
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    Slider(value: $settingsStore.previewTimeout, in: 1.0...10.0, step: 0.5)
                                    Text(L10n.General.previewTimeoutDesc)
                                        .font(.body)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.leading, 2)
                            }

                            Divider().opacity(0.3)

                            Toggle(L10n.General.enableSmartSend, isOn: $settingsStore.enableSmartSend)
                            Text(L10n.General.smartSendDesc)
                                .font(.body)
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
                                        .font(.body)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.leading, 2)
                            }
                        }
                    }
                }

                // MARK: - 歷史記錄清理
                if settingsMatchesSearch(["歷史", "history", "清理", "cleanup", "保留", "retention", "历史"], searchText: searchState.searchText) {
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
                                        .font(.body)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.leading, 2)
                            }
                        }
                    }
                }

                // MARK: - Tutorial
                if settingsMatchesSearch(["教學", "tutorial", "教程", "使用指南"], searchText: searchState.searchText) {
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
                }

                // MARK: - 權限狀態
                if settingsMatchesSearch(["權限", "permission", "accessibility", "麥克風", "microphone", "权限"], searchText: searchState.searchText) {
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
                                        .font(.title3)
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
                                        .font(.title3)
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
                                Image(systemName: "gearshape.2.fill")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                Text(L10n.General.automation)
                                Spacer()
                                if automationAuthorized {
                                    Label(L10n.Common.authorized, systemImage: "checkmark.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(.green)
                                } else {
                                    Button(L10n.Common.requestAccess) {
                                        requestAutomationAccess()
                                    }
                                    .controlSize(.small)
                                    .buttonStyle(.bordered)
                                }
                            }

                            Divider().opacity(0.3)

                            HStack {
                                Image(systemName: "checklist")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                Text(L10n.General.reminders)
                                Spacer()
                                if remindersAuthorized {
                                    Label(L10n.Common.authorized, systemImage: "checkmark.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(.green)
                                } else {
                                    Button(L10n.Common.openSettings) {
                                        requestRemindersAccess()
                                    }
                                    .controlSize(.small)
                                    .buttonStyle(.bordered)
                                }
                            }

                            Divider().opacity(0.3)

                            HStack {
                                Image(systemName: "calendar")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                Text(L10n.General.calendar)
                                Spacer()
                                if calendarAuthorized {
                                    Label(L10n.Common.authorized, systemImage: "checkmark.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(.green)
                                } else {
                                    Button(L10n.Common.openSettings) {
                                        requestCalendarAccess()
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
                                        .font(.title3)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }

                // MARK: - No Results
                if !searchState.searchText.isEmpty {
                    let hasAny =
                        settingsMatchesSearch(["開機", "啟動", "登入", "launch", "login", "自動啟動", "startup", "开机", "启动"], searchText: searchState.searchText) ||
                        settingsMatchesSearch(["語言", "语言", "language", "言語", "介面"], searchText: searchState.searchText) ||
                        settingsMatchesSearch(["功能", "features", "context", "上下文", "音效", "sound", "whisper"], searchText: searchState.searchText) ||
                        settingsMatchesSearch(["語音辨識", "语音识别", "speech", "STT", "engine", "whisper", "引擎"], searchText: searchState.searchText) ||
                        settingsMatchesSearch(["膠囊", "胶囊", "capsule", "大小", "size", "縮放", "scale"], searchText: searchState.searchText) ||
                        settingsMatchesSearch(["輸入裝置", "输入设备", "input", "device", "麥克風", "麦克风", "microphone", "mic", "靈敏度", "灵敏度", "sensitivity", "gain"], searchText: searchState.searchText) ||
                        settingsMatchesSearch(["自動停止", "auto stop", "靜音", "silence", "自动停止"], searchText: searchState.searchText) ||
                        settingsMatchesSearch(["注入", "inject", "貼上", "paste", "keypress", "逐字", "取代", "replace"], searchText: searchState.searchText) ||
                        settingsMatchesSearch(["預覽", "preview", "注入", "inject", "预览", "smart send", "倒數", "countdown", "自動送出", "自动发送"], searchText: searchState.searchText) ||
                        settingsMatchesSearch(["歷史", "history", "清理", "cleanup", "保留", "retention", "历史"], searchText: searchState.searchText) ||
                        settingsMatchesSearch(["教學", "tutorial", "教程", "使用指南"], searchText: searchState.searchText) ||
                        settingsMatchesSearch(["權限", "permission", "accessibility", "麥克風", "microphone", "权限"], searchText: searchState.searchText)
                    if !hasAny {
                        Text(L10n.Common.noResults)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
            }
            .padding(20)
        }
        .sheet(isPresented: $showContextRulesSheet) {
            ContextRulesView(settingsStore: settingsStore)
                .frame(minWidth: 500, minHeight: 400)
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
            micTester.start()
            isMicTesting = true
        }
    }

    private func refreshPermissions() {
        accessibilityAuthorized = AccessibilityManager.shared.isAuthorized
        micAuthorized = AudioSessionManager.isMicrophoneAuthorized
        automationAuthorized = checkAutomationPermission()
        remindersAuthorized = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
            || EKEventStore.authorizationStatus(for: .reminder) == .authorized
        calendarAuthorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
            || EKEventStore.authorizationStatus(for: .event) == .authorized
    }

    private func checkAutomationPermission() -> Bool {
        let script = NSAppleScript(source: """
            tell application "System Events"
                return name of first process
            end tell
        """)
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        return error == nil
    }

    private func requestAutomationAccess() {
        // 觸發 AppleScript 讓 Saybit 出現在自動化清單，然後開啟設定
        let script = NSAppleScript(source: """
            tell application "System Events"
                return name of first process
            end tell
        """)
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        automationAuthorized = (error == nil)
        if !automationAuthorized {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
        }
    }

    // 保留 EKEventStore 實例避免被提前釋放
    @State private var eventStore = EKEventStore()

    private func requestRemindersAccess() {
        Task {
            NSLog("[Permission] Reminders: current status = %d", EKEventStore.authorizationStatus(for: .reminder).rawValue)
            do {
                let granted = try await eventStore.requestFullAccessToReminders()
                NSLog("[Permission] Reminders requestFullAccess: granted=%d", granted ? 1 : 0)
                await MainActor.run {
                    remindersAuthorized = granted
                    if !granted {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!)
                    }
                }
            } catch {
                NSLog("[Permission] Reminders requestFullAccess error: %@", error.localizedDescription)
                await MainActor.run {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!)
                }
            }
        }
    }

    private func requestCalendarAccess() {
        Task {
            NSLog("[Permission] Calendar: current status = %d", EKEventStore.authorizationStatus(for: .event).rawValue)
            do {
                let granted = try await eventStore.requestFullAccessToEvents()
                NSLog("[Permission] Calendar requestFullAccessToEvents: granted=%d", granted ? 1 : 0)
                await MainActor.run {
                    calendarAuthorized = granted
                    if !granted {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                    }
                }
            } catch {
                NSLog("[Permission] Calendar requestFullAccessToEvents error: %@", error.localizedDescription)
                // Fallback: try legacy API
                do {
                    let legacyGranted = try await eventStore.requestAccess(to: .event)
                    NSLog("[Permission] Calendar legacy requestAccess: granted=%d", legacyGranted ? 1 : 0)
                    await MainActor.run {
                        calendarAuthorized = legacyGranted
                        if !legacyGranted {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                        }
                    }
                } catch {
                    NSLog("[Permission] Calendar legacy requestAccess error: %@", error.localizedDescription)
                    await MainActor.run {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                    }
                }
            }
        }
    }

    // MARK: - Whisper API Key

    @ViewBuilder
    private var whisperAPIKeyStatus: some View {
        if KeychainHelper.loadAPIKey(for: "whisper_api") != nil {
            Label(L10n.Common.set, systemImage: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
        } else {
            Label(L10n.Common.notSet, systemImage: "xmark.circle.fill")
                .font(.title3)
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

//
//  GeneralSettingsView.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import EventKit
import Speech
import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var searchState: SettingsSearchState
    @State private var accessibilityAuthorized = AccessibilityManager.shared.isAuthorized
    @State private var micAuthorized = AudioSessionManager.isMicrophoneAuthorized
    @State private var speechAuthorized = SFSpeechRecognizer.authorizationStatus() == .authorized
    /// Keychain 查詢結果快取，避免 body 每次重繪（麥克風測試時很頻繁）都讀 Keychain
    @State private var whisperKeySet = false
    @State private var automationAuthorized = false
    @State private var remindersAuthorized = false
    @State private var calendarAuthorized = false
    @State private var screenRecordingAuthorized = ScreenContextCapture.hasPermission
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var isMicTesting: Bool = false
    @StateObject private var micTester = MicLevelTester()

    // Whisper API Key states
    @State private var whisperAPIKeyInput: String = ""
    @State private var showWhisperKey: Bool = false
    @State private var isTestingWhisper: Bool = false
    @State private var whisperTestStatus: String?
    @State private var showContextRulesSheet: Bool = false

    // 每張卡片的搜尋關鍵字（卡片顯示與「沒有結果」共用同一份）
    /// 給側邊欄跨分頁搜尋用
    static var searchKeywords: [String] { Keys.all.flatMap { $0 } }

    fileprivate enum Keys {
        static let recording = ["錄音", "录音", "recording", "輸入裝置", "输入设备", "input", "device", "麥克風", "麦克风", "microphone", "mic", "靈敏度", "灵敏度", "sensitivity", "gain", "自動停止", "auto stop", "靜音", "silence", "自动停止", "音量", "volume", "duck", "音效", "sound"]
        static let recognition = ["語音辨識", "语音识别", "speech", "STT", "engine", "whisper", "引擎", "sensevoice", "離線", "offline", "降噪", "noise", "回音", "echo", "AEC", "背景"]
        static let ai = ["AI", "上下文", "context", "選取", "selected", "螢幕", "screen", "ocr", "嘈雜", "noisy", "whisper", "語氣", "tone", "規則", "rule"]
        static let output = ["輸出", "注入", "inject", "貼上", "paste", "keypress", "逐字", "取代", "replace", "預覽", "preview", "预览", "smart send", "智慧送出", "倒數", "countdown", "自動送出", "自动发送", "enter"]
        static let interface = ["介面", "語言", "语言", "language", "言語", "膠囊", "胶囊", "capsule", "大小", "size", "縮放", "scale"]
        static let system = ["系統", "開機", "啟動", "登入", "launch", "login", "startup", "开机", "启动", "更新", "update", "version", "版本", "歷史", "history", "清理", "cleanup", "保留", "retention", "历史", "教學", "tutorial", "教程"]
        static let permissions = ["權限", "permission", "accessibility", "輔助使用", "麥克風", "microphone", "权限", "螢幕錄製", "screen recording", "提醒事項", "行事曆", "calendar", "reminders", "自動化", "automation", "語音辨識", "speech"]
        static let all = [recording, recognition, ai, output, interface, system, permissions]
    }

    private func shows(_ keys: [String]) -> Bool {
        settingsMatchesSearch(keys, searchText: searchState.searchText)
    }

    private var isSelectedDeviceMissing: Bool {
        let uid = settingsStore.selectedInputDeviceUID
        return !uid.isEmpty && !inputDevices.contains { $0.uid == uid }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if shows(Keys.recording) { recordingCard }
                if shows(Keys.recognition) { recognitionCard }
                if shows(Keys.ai) { aiCard }
                if shows(Keys.output) { outputCard }
                if shows(Keys.interface) { interfaceCard }
                if shows(Keys.system) { systemCard }
                if shows(Keys.permissions) { permissionsCard }

                if !searchState.searchText.isEmpty && !Keys.all.contains(where: shows) {
                    SettingsNoResults()
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
            refreshWhisperKeyStatus()
        }
        .onDisappear {
            if isMicTesting { toggleMicTest() }
        }
        // 從系統設定授權回來時更新權限狀態
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    // MARK: - 錄音

    private var recordingCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                GlassSectionHeader(title: L10n.General.sectionRecording, icon: "mic")

                SettingRow(title: L10n.General.inputDevice, description: L10n.General.selectMicDesc) {
                    Picker(L10n.General.inputDevice, selection: $settingsStore.selectedInputDeviceUID) {
                        Text(L10n.General.systemDefault).tag("")
                        ForEach(inputDevices) { device in
                            Text(device.name).tag(device.uid)
                        }
                        // 已選的裝置拔掉後仍要有對應的項目，否則選單會顯示空白
                        if isSelectedDeviceMissing {
                            Text(L10n.General.deviceUnavailable).tag(settingsStore.selectedInputDeviceUID)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }

                // 音量偵測
                HStack(spacing: 10) {
                    Button {
                        toggleMicTest()
                    } label: {
                        Label(isMicTesting ? L10n.General.stopTest : L10n.General.testMic,
                              systemImage: isMicTesting ? "stop.fill" : "waveform")
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .tint(isMicTesting ? .red : nil)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.1))
                            Capsule()
                                .fill(micTester.level > 0.85 ? Color.orange : Color.green)
                                .frame(width: geo.size.width * CGFloat(micTester.level))
                                .animation(.linear(duration: 0.05), value: micTester.level)
                        }
                    }
                    .frame(height: 6)
                    .opacity(isMicTesting ? 1 : 0.4)

                    Text(String(format: "%.0f%%", micTester.level * 100))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                if isMicTesting {
                    SettingDescription(L10n.General.micTestHint)
                }

                SettingSlider(
                    title: L10n.General.gainMultiplier,
                    valueText: String(format: "%.1fx", settingsStore.micSensitivity),
                    value: $settingsStore.micSensitivity, range: 0.5...5.0, step: 0.5,
                    description: L10n.General.micSensitivityDesc
                )

                SettingDivider()

                SettingToggle(title: L10n.General.enableAutoStop, description: L10n.General.silenceAutoStopDesc,
                              isOn: $settingsStore.enableAutoStop)
                if settingsStore.enableAutoStop {
                    SettingIndent {
                        SettingSlider(
                            title: L10n.General.silenceTimeout,
                            valueText: L10n.General.seconds(settingsStore.silenceTimeout),
                            value: $settingsStore.silenceTimeout, range: 0.5...5.0, step: 0.5
                        )
                    }
                }

                SettingDivider()

                SettingToggle(title: L10n.General.ducking, description: L10n.General.duckingDesc,
                              isOn: $settingsStore.enableDuckingWhileRecording)

                SettingDivider()

                SettingToggle(title: L10n.General.soundFeedback, isOn: $settingsStore.enableSoundFeedback)
            }
        }
    }

    // MARK: - 語音辨識

    private var recognitionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                GlassSectionHeader(title: L10n.General.sectionRecognition, icon: "waveform.circle")

                Picker(L10n.General.sttEnginePicker, selection: $settingsStore.sttEngine) {
                    ForEach(STTEngine.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch settingsStore.sttEngine {
                case .whisperAPI:
                    whisperAPIPanel
                case .sherpaSenseVoice:
                    SherpaModelPanel()
                case .appleSpeech:
                    SettingToggle(title: L10n.General.onDeviceSTT, description: L10n.General.onDeviceSTTDesc,
                                  isOn: $settingsStore.enableOnDeviceSTT)
                    SettingToggle(title: L10n.General.continuousBackgroundSTT, description: L10n.General.continuousSTTDesc,
                                  isOn: $settingsStore.enableContinuousSTT)
                }

                SettingDivider()

                SettingToggle(title: L10n.General.voiceBandpass, description: L10n.General.voiceBandpassDesc,
                              isOn: $settingsStore.enableVoiceBandpass)

                SettingDivider()

                SettingToggle(title: L10n.General.echoCancellation, description: L10n.General.echoCancellationDesc,
                              isOn: $settingsStore.enableEchoCancellation)
            }
        }
    }

    private var whisperAPIPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.General.whisperAPIKey)
                Spacer()
                whisperAPIKeyStatus
            }

            HStack(spacing: 8) {
                Group {
                    if showWhisperKey {
                        TextField("sk-...", text: $whisperAPIKeyInput)
                    } else {
                        SecureField("sk-...", text: $whisperAPIKeyInput)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !whisperAPIKeyInput.isEmpty { saveWhisperAPIKey() } }

                Button {
                    showWhisperKey.toggle()
                } label: {
                    Image(systemName: showWhisperKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(showWhisperKey ? L10n.Common.hide : L10n.Common.show)
                .accessibilityLabel(showWhisperKey ? L10n.Common.hide : L10n.Common.show)

                Button(L10n.Common.save) {
                    saveWhisperAPIKey()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(whisperAPIKeyInput.isEmpty)

                Button {
                    testWhisperConnection()
                } label: {
                    if isTestingWhisper {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(L10n.Common.testConnection, systemImage: "bolt.horizontal")
                    }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(isTestingWhisper)
            }

            if let whisperTestStatus {
                let ok = whisperTestStatus == L10n.Common.connectionSuccess
                Label(whisperTestStatus, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(ok ? .green : .orange)
            }

            SettingDescription(L10n.General.whisperDesc)
        }
    }

    // MARK: - AI 理解

    private var aiCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                GlassSectionHeader(title: L10n.General.sectionAI, icon: "sparkles")

                SettingToggle(title: L10n.General.contextAwareness, description: L10n.General.contextAwarenessDesc,
                              isOn: $settingsStore.enableContextAwareness)
                if settingsStore.enableContextAwareness {
                    SettingIndent {
                        SettingRow(title: L10n.General.contextRules, description: L10n.General.contextRulesDesc) {
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

                SettingDivider()

                SettingToggle(title: L10n.General.screenContext, description: L10n.General.screenContextDesc,
                              isOn: $settingsStore.enableScreenContext)
                    .onChange(of: settingsStore.enableScreenContext) { _, on in
                        if on && !ScreenContextCapture.hasPermission {
                            ScreenContextCapture.requestPermission()
                        }
                        refreshPermissions()
                    }
                if settingsStore.enableScreenContext && !screenRecordingAuthorized {
                    SettingIndent {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(L10n.General.screenRecordingMissing)
                                .font(.callout)
                            Spacer()
                            Button(L10n.General.grantScreenRecording) { openScreenRecordingSettings() }
                                .controlSize(.small)
                        }
                    }
                }

                SettingDivider()

                SettingToggle(title: L10n.General.whisperMode, description: L10n.General.whisperModeDesc,
                              isOn: $settingsStore.enableWhisperMode)
            }
        }
    }

    // MARK: - 輸出

    private var outputCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                GlassSectionHeader(title: L10n.General.sectionOutput, icon: "text.cursor")

                SettingRow(title: L10n.General.injectionMode, description: L10n.General.injectionModeDesc) {
                    Picker(L10n.General.injectionMode, selection: $settingsStore.injectionMode) {
                        ForEach(InjectionMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }

                SettingDivider()

                SettingToggle(title: L10n.General.enablePreview, description: L10n.General.previewDesc,
                              isOn: $settingsStore.enablePreviewBeforeInject)
                if settingsStore.enablePreviewBeforeInject {
                    SettingIndent {
                        SettingSlider(
                            title: L10n.General.previewTimeout,
                            valueText: L10n.General.seconds(settingsStore.previewTimeout),
                            value: $settingsStore.previewTimeout, range: 1.0...10.0, step: 0.5,
                            description: L10n.General.previewTimeoutDesc
                        )
                    }
                }

                SettingDivider()

                SettingToggle(title: L10n.General.enableSmartSend, description: L10n.General.smartSendDesc,
                              isOn: $settingsStore.enableSmartSend)
                if settingsStore.enableSmartSend {
                    SettingIndent {
                        SettingSlider(
                            title: L10n.General.countdownSeconds,
                            valueText: L10n.General.seconds(settingsStore.smartSendDelay),
                            value: $settingsStore.smartSendDelay, range: 1.0...10.0, step: 0.5,
                            description: L10n.General.smartSendCancelHint
                        )
                    }
                }
            }
        }
    }

    // MARK: - 介面

    private var interfaceCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                GlassSectionHeader(title: L10n.General.sectionInterface, icon: "macwindow")

                SettingRow(title: L10n.General.preferredLanguage) {
                    Picker(L10n.General.preferredLanguage, selection: $settingsStore.languagePreference) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .disabled(settingsStore.sttEngine == .whisperAPI && settingsStore.enableAutoLanguageDetection)
                }

                // 自動語言偵測只對 Whisper API 有效，其他引擎不顯示
                if settingsStore.sttEngine == .whisperAPI {
                    SettingToggle(title: L10n.General.autoLanguageDetection, description: L10n.General.autoLanguageDetectionDesc,
                                  isOn: $settingsStore.enableAutoLanguageDetection)
                }

                SettingDivider()

                SettingSlider(
                    title: L10n.General.capsuleSize,
                    valueText: String(format: "%.0f%%", settingsStore.capsuleScale * 100),
                    value: $settingsStore.capsuleScale, range: 0.5...2.0, step: 0.1,
                    description: L10n.General.capsuleSizeDesc
                )
            }
        }
    }

    // MARK: - 系統

    private var systemCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                GlassSectionHeader(title: L10n.General.sectionSystem, icon: "gearshape")

                SettingToggle(title: L10n.General.enableLaunchAtLogin, description: L10n.General.launchAtLoginDesc,
                              isOn: $settingsStore.launchAtLogin)

                SettingDivider()

                SettingToggle(title: L10n.General.enableAutoUpdateCheck, description: L10n.General.autoUpdateCheckDesc,
                              isOn: $settingsStore.enableAutoUpdateCheck)
                if !settingsStore.availableUpdateTag.isEmpty {
                    SettingIndent {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles").foregroundStyle(.green)
                            Text(L10n.Update.newer(latest: settingsStore.availableUpdateTag,
                                                   current: UpdateChecker.shared.currentVersion()))
                            if let url = URL(string: settingsStore.availableUpdateURL),
                               !settingsStore.availableUpdateURL.isEmpty {
                                Link(L10n.Update.viewRelease, destination: url)
                            }
                        }
                    }
                }

                SettingDivider()

                SettingToggle(title: L10n.General.autoCleanup, description: L10n.General.historyCleanupDesc,
                              isOn: $settingsStore.enableHistoryAutoCleanup)
                if settingsStore.enableHistoryAutoCleanup {
                    SettingIndent {
                        SettingSlider(
                            title: L10n.General.retentionDays,
                            valueText: L10n.General.days(settingsStore.historyRetentionDays),
                            value: Binding(
                                get: { Double(settingsStore.historyRetentionDays) },
                                set: { settingsStore.historyRetentionDays = Int($0) }
                            ),
                            range: 7...90, step: 1
                        )
                    }
                }

                SettingDivider()

                SettingRow(title: L10n.General.tutorial, description: L10n.General.tutorialDesc) {
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
    }

    // MARK: - 權限

    private var permissionsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    GlassSectionHeader(title: L10n.General.permissionStatus, icon: "lock.shield")
                    Spacer()
                    Button {
                        refreshPermissions()
                    } label: {
                        Label(L10n.Common.recheck, systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }

                permissionRow(icon: "hand.raised.fill", title: L10n.General.accessibility,
                              granted: accessibilityAuthorized, required: true) {
                    AccessibilityManager.shared.promptIfNeeded()
                }
                SettingDivider()
                permissionRow(icon: "mic.fill", title: L10n.General.microphone,
                              granted: micAuthorized, required: true) {
                    openPrivacyPane("Privacy_Microphone")
                }
                SettingDivider()
                permissionRow(icon: "waveform", title: L10n.General.speechRecognition,
                              granted: speechAuthorized, required: settingsStore.sttEngine == .appleSpeech) {
                    requestSpeechAccess()
                }
                SettingDivider()
                permissionRow(icon: "rectangle.dashed.badge.record", title: L10n.General.screenRecording,
                              granted: screenRecordingAuthorized, required: settingsStore.enableScreenContext) {
                    openScreenRecordingSettings()
                }
                SettingDivider()
                permissionRow(icon: "gearshape.2.fill", title: L10n.General.automation,
                              granted: automationAuthorized, required: false, actionTitle: L10n.Common.requestAccess) {
                    requestAutomationAccess()
                }
                SettingDivider()
                permissionRow(icon: "checklist", title: L10n.General.reminders,
                              granted: remindersAuthorized, required: false) {
                    requestRemindersAccess()
                }
                SettingDivider()
                permissionRow(icon: "calendar", title: L10n.General.calendar,
                              granted: calendarAuthorized, required: false) {
                    requestCalendarAccess()
                }
            }
        }
    }

    private func permissionRow(icon: String, title: String, granted: Bool, required: Bool,
                               actionTitle: String = L10n.Common.openSettings,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title)
            if !granted && required {
                Text(L10n.General.requiredBadge)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange.opacity(0.2)))
                    .foregroundStyle(.orange)
            }
            Spacer()
            if granted {
                Label(L10n.Common.authorized, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .buttonStyle(.bordered)
            }
        }
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openScreenRecordingSettings() {
        if !ScreenContextCapture.hasPermission { ScreenContextCapture.requestPermission() }
        openPrivacyPane("Privacy_ScreenCapture")
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
        screenRecordingAuthorized = ScreenContextCapture.hasPermission
        micAuthorized = AudioSessionManager.isMicrophoneAuthorized
        speechAuthorized = SFSpeechRecognizer.authorizationStatus() == .authorized
        automationAuthorized = checkAutomationPermission()
        remindersAuthorized = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
            || EKEventStore.authorizationStatus(for: .reminder) == .authorized
        calendarAuthorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
            || EKEventStore.authorizationStatus(for: .event) == .authorized
    }

    /// 只查詢、不跳授權對話框、不執行 AppleScript（主執行緒上跑 AppleScript 會卡住，且首次會彈「自動化」詢問）。
    /// System Events 沒在執行時回 procNotFound，視為未授權；使用者按「請求授權」才會真的觸發。
    private func checkAutomationPermission() -> Bool {
        var target = AEAddressDesc()
        let bundleID = "com.apple.systemevents"
        let created = bundleID.withCString { ptr in
            AECreateDesc(DescType(typeApplicationBundleID), ptr, strlen(ptr), &target)
        }
        guard created == noErr else { return false }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
        if status == OSStatus(procNotFound) {
            // System Events 平常不一定在執行，查不到不代表未授權：背景啟動它（不搶焦點、不彈窗）後再查一次，
            // 這段期間維持上一次的顯示結果，避免已授權的使用者看到「請求授權」
            launchSystemEventsAndRecheck()
            return automationAuthorized
        }
        return status == noErr
    }

    @State private var systemEventsLaunchAttempted = false

    private func launchSystemEventsAndRecheck() {
        guard !systemEventsLaunchAttempted,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systemevents") else { return }
        systemEventsLaunchAttempted = true
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                refreshPermissions()
            }
        }
    }

    private func requestSpeechAccess() {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async {
                    speechAuthorized = status == .authorized
                }
            }
        } else {
            openPrivacyPane("Privacy_SpeechRecognition")
        }
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
            NSWorkspace.shared.open(URL(staticString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"))
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
                        NSWorkspace.shared.open(URL(staticString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"))
                    }
                }
            } catch {
                NSLog("[Permission] Reminders requestFullAccess error: %@", error.localizedDescription)
                await MainActor.run {
                    NSWorkspace.shared.open(URL(staticString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"))
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
                        NSWorkspace.shared.open(URL(staticString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"))
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
                            NSWorkspace.shared.open(URL(staticString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"))
                        }
                    }
                } catch {
                    NSLog("[Permission] Calendar legacy requestAccess error: %@", error.localizedDescription)
                    await MainActor.run {
                        NSWorkspace.shared.open(URL(staticString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"))
                    }
                }
            }
        }
    }

    // MARK: - Whisper API Key

    @ViewBuilder
    private var whisperAPIKeyStatus: some View {
        if whisperKeySet {
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
        refreshWhisperKeyStatus()
    }

    private func refreshWhisperKeyStatus() {
        whisperKeySet = !(KeychainHelper.loadAPIKey(for: "whisper_api") ?? "").isEmpty
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

// MARK: - SenseVoice 離線模型

private struct SherpaModelPanel: View {
    @State private var models = SherpaModelManager.shared
    @State private var confirmDelete = false

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: SherpaModelManager.totalSize, countStyle: .file)
    }

    var body: some View {
        SettingRow(
            title: L10n.Sherpa.modelTitle,
            description: L10n.Sherpa.modelDesc
        ) {
            switch models.state {
            case .installed:
                HStack(spacing: 8) {
                    Label(L10n.Sherpa.installed, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Menu {
                        Button(L10n.Sherpa.showInFinder) {
                            NSWorkspace.shared.activateFileViewerSelecting([SherpaModelManager.shared.directory])
                        }
                        Divider()
                        Button(L10n.Sherpa.deleteModel(sizeText), role: .destructive) { confirmDelete = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(L10n.Sherpa.moreActions)
                    .accessibilityLabel(L10n.Sherpa.moreActions)
                }
            case .notInstalled:
                Button {
                    models.download()
                } label: {
                    Label(L10n.Sherpa.download(sizeText), systemImage: "arrow.down.circle")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            case .downloading(let progress):
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(width: 120)
                    Text(progress.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                    Button(L10n.Common.cancel) { models.cancelDownload() }
                        .controlSize(.small)
                }
            case .failed(let message):
                HStack(spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .help(message)
                    Button(L10n.Sherpa.retry) { models.download() }
                        .controlSize(.small)
                }
            }
        }
        .confirmationDialog(L10n.Sherpa.deleteConfirmTitle, isPresented: $confirmDelete) {
            Button(L10n.Common.delete, role: .destructive) { models.delete() }
        } message: {
            Text(L10n.Sherpa.deleteConfirmMessage(sizeText))
        }
    }
}

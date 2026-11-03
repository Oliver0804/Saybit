//
//  TutorialView.swift
//  speakertpyer
//

import SwiftUI

struct TutorialView: View {
    @ObservedObject var settingsStore: SettingsStore
    @State private var currentPage = 0
    @State private var practiceText = ""
    @State private var apiKeyInput = ""
    @FocusState private var isTextFieldFocused: Bool
    var onDismiss: () -> Void

    // Mic testing states
    @State private var inputDevices: [AudioInputDevice] = []
    @StateObject private var micTester = MicLevelTester()
    @State private var isMicTesting = false

    // Hotkey recording states
    @State private var isRecordingHotkey = false
    @State private var recordingTimeRemaining = 0
    @State private var countdownTask: Task<Void, Never>?
    private let recordingTimeout = 10

    @State private var tutorialKeySaved = false

    // Pages: 0=Hotkey, 1=API, 2=Audio, 3=Features, 4-7=Practice 1-4
    private let totalPages = 8

    var body: some View {
        VStack(spacing: 0) {
            // Content - 使用 Group + switch 取代 TabView 以隱藏標籤列
            Group {
                switch currentPage {
                case 0: hotkeyPage
                case 1: apiPage
                case 2: audioPage
                case 3: featuresPage
                case 4: practicePage(step: 1)
                case 5: practicePage(step: 2)
                case 6: practicePage(step: 3)
                case 7: practicePage(step: 4)
                default: hotkeyPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Navigation
            HStack {
                if currentPage > 0 {
                    Button(L10n.Common.previous) {
                        withAnimation { currentPage -= 1 }
                    }
                    .font(.title3)
                }

                Spacer()

                // Page indicators
                HStack(spacing: 8) {
                    ForEach(0..<totalPages, id: \.self) { i in
                        Circle()
                            .fill(i == currentPage ? Color.accentColor : Color.primary.opacity(0.2))
                            .frame(width: 10, height: 10)
                    }
                }

                Spacer()

                if currentPage < totalPages - 1 {
                    HStack(spacing: 8) {
                        Button(L10n.Common.skip) {
                            onDismiss()
                        }
                        .font(.title3)
                        .foregroundStyle(.secondary)

                        Button(L10n.Common.next) {
                            withAnimation {
                                currentPage += 1
                                practiceText = "" // Clear text when moving to next practice
                            }
                        }
                        .font(.title3)
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    Button(L10n.Common.startUsing) {
                        onDismiss()
                    }
                    .font(.title3)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .frame(width: 620, height: 580)
    }

    // MARK: - Page 1: Hotkey Setup

    private var hotkeyPage: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "keyboard.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue.gradient)

            Text(L10n.Tutorial.hotkeyTitle)
                .font(.largeTitle)
                .fontWeight(.bold)

            Text(L10n.Tutorial.hotkeyDesc)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            // Current hotkey badge with record button
            VStack(spacing: 12) {
                Text(L10n.Tutorial.currentHotkey)
                    .font(.title3)
                    .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    Text(isRecordingHotkey ? L10n.HotKey.recording : GlobalHotKeyManager.hotkeyDescription(
                        keyCode: UInt16(settingsStore.hotkeyKeyCode),
                        modifiers: CGEventFlags(rawValue: UInt64(settingsStore.hotkeyModifiers))
                    ))
                    .font(.system(.largeTitle, design: .rounded))
                    .fontWeight(.bold)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(isRecordingHotkey ? Color.orange.opacity(0.15) : Color.accentColor.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(isRecordingHotkey ? Color.orange.opacity(0.6) : Color.accentColor.opacity(0.4), lineWidth: 1.5)
                    )

                    if isRecordingHotkey {
                        VStack {
                            Text("\(recordingTimeRemaining)s")
                                .font(.title2)
                                .foregroundStyle(.orange)
                                .monospacedDigit()
                            Button(L10n.Common.cancel) {
                                cancelRecording()
                            }
                            .font(.subheadline)
                        }
                    } else {
                        Button {
                            startRecording()
                        } label: {
                            Label(L10n.HotKey.recordNew, systemImage: "record.circle")
                                .font(.title3)
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if isRecordingHotkey {
                    Text(L10n.HotKey.recordingHint)
                        .font(.body)
                        .foregroundStyle(.orange)
                } else {
                    Text(L10n.HotKey.requirement)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }

            // Trigger mode picker
            VStack(spacing: 8) {
                Text(L10n.HotKey.triggerMode)
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Picker("", selection: $settingsStore.hotkeyTriggerMode) {
                    ForEach(HotkeyTriggerMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 400)
                .onChange(of: settingsStore.hotkeyTriggerMode) { _, _ in
                    if let appDelegate = NSApp.delegate as? AppDelegate {
                        appDelegate.setupHotKey()
                    }
                }

                Text(L10n.hotkeyTriggerModeDesc(settingsStore.hotkeyTriggerMode))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Page 2: API Introduction

    private var apiPage: some View {
        VStack(spacing: 14) {
            Image(systemName: "dollarsign.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green.gradient)

            Text(L10n.Onboarding.apiTutorialTitle)
                .font(.title)
                .fontWeight(.bold)

            Text(L10n.Onboarding.apiTutorialDesc)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            // Price comparison card
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.Onboarding.apiTutorialCompare)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    priceRow(text: L10n.Onboarding.apiTutorialPrice1, highlight: true)
                    priceRow(text: L10n.Onboarding.apiTutorialPrice2, highlight: false)
                }
                HStack(spacing: 12) {
                    priceRow(text: L10n.Onboarding.apiTutorialPrice3, highlight: false)
                    priceRow(text: L10n.Onboarding.apiTutorialPrice4, highlight: true)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.green.opacity(0.08))
            )
            .padding(.horizontal, 50)

            Divider()
                .padding(.horizontal, 80)

            // API Key input section
            VStack(spacing: 10) {
                // Provider selection
                HStack(spacing: 12) {
                    Text(L10n.API.provider)
                        .font(.body)
                    // 列出所有需要 key 的服務商，key 才會存到使用者實際選的那一家
                    Picker("", selection: $settingsStore.selectedProviderID) {
                        ForEach(settingsStore.allProviders.filter(\.requiresAPIKey)) { provider in
                            Text(provider.name).tag(provider.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 280)
                    .onChange(of: settingsStore.selectedProviderID) { _, _ in
                        apiKeyInput = ""
                        refreshTutorialKeyStatus()
                    }
                }

                // Get API Key link based on selection
                if let url = Self.keyPortalURL(for: settingsStore.selectedProviderID) {
                    Link(destination: url) {
                        Label(L10n.Onboarding.apiTutorialGetKey, systemImage: "link")
                            .font(.callout)
                    }
                }

                // API Key input field
                HStack {
                    SecureField(settingsStore.selectedProvider.keyPlaceholder, text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.body)

                    Button(L10n.Common.save) {
                        guard !apiKeyInput.isEmpty else { return }
                        try? KeychainHelper.saveAPIKey(apiKeyInput,
                                                       for: settingsStore.selectedProvider.id)
                        if let preset = LLMProvider.defaultModel(for: settingsStore.selectedProviderID) {
                            settingsStore.selectedModel = preset
                        }
                        refreshTutorialKeyStatus()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(apiKeyInput.isEmpty)
                }
                .padding(.horizontal, 50)

                // Status
                if tutorialKeySaved {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(L10n.Onboarding.apiKeySaved)
                            .foregroundColor(.green)
                    }
                    .font(.callout)
                }

                // Model hint
                Text(settingsStore.selectedProvider.modelHint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .onAppear { refreshTutorialKeyStatus() }
    }

    /// Keychain 只在切換服務商 / 儲存 / 進頁時查，不在 body 裡查
    private func refreshTutorialKeyStatus() {
        tutorialKeySaved = !(KeychainHelper.loadAPIKey(for: settingsStore.selectedProvider.id) ?? "").isEmpty
    }

    private static func keyPortalURL(for providerID: String) -> URL? {
        switch providerID {
        case "openrouter": URL(string: "https://openrouter.ai/keys")
        case "openai":     URL(string: "https://platform.openai.com/api-keys")
        case "deepseek":   URL(string: "https://platform.deepseek.com/api_keys")
        case "groq":       URL(string: "https://console.groq.com/keys")
        case "together":   URL(string: "https://api.together.xyz/settings/api-keys")
        default:           nil
        }
    }

    private func priceRow(text: String, highlight: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: highlight ? "star.fill" : "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(highlight ? .yellow : .green)
            Text(text)
                .font(.callout)
                .fontWeight(highlight ? .semibold : .regular)
        }
    }

    // MARK: - Page 3: Audio Setup

    private var audioPage: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "mic.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green.gradient)

            Text(L10n.General.inputDevice)
                .font(.largeTitle)
                .fontWeight(.bold)

            Text(L10n.General.selectMicDesc)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            // Input device picker
            VStack(spacing: 12) {
                Picker(L10n.General.inputDevice, selection: $settingsStore.selectedInputDeviceUID) {
                    Text(L10n.General.systemDefault).tag("")
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                    // 已選的裝置拔掉後仍要有對應項目，否則選單顯示空白
                    let uid = settingsStore.selectedInputDeviceUID
                    if !uid.isEmpty && !inputDevices.contains(where: { $0.uid == uid }) {
                        Text(L10n.General.deviceUnavailable).tag(uid)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 400)

                // Volume indicator
                HStack(spacing: 12) {
                    Button {
                        toggleMicTest()
                    } label: {
                        Label(
                            isMicTesting ? L10n.General.stopTest : L10n.General.testMic,
                            systemImage: isMicTesting ? "stop.fill" : "waveform"
                        )
                        .font(.title3)
                    }
                    .buttonStyle(.bordered)
                    .tint(isMicTesting ? .red : .accentColor)

                    // Volume bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.primary.opacity(0.1))
                            RoundedRectangle(cornerRadius: 5)
                                .fill(micTester.level > 0.6 ? Color.green : micTester.level > 0.3 ? Color.yellow : Color.green.opacity(0.7))
                                .frame(width: geo.size.width * CGFloat(micTester.level))
                                .animation(.linear(duration: 0.05), value: micTester.level)
                        }
                    }
                    .frame(width: 200, height: 16)

                    Text(String(format: "%.0f%%", micTester.level * 100))
                        .font(.system(.title3, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }

                // Gain slider
                VStack(spacing: 6) {
                    HStack {
                        Text(L10n.General.micSensitivity)
                            .font(.title3)
                        Spacer()
                        Text(String(format: "%.1fx", settingsStore.micSensitivity))
                            .font(.system(.title3, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settingsStore.micSensitivity, in: 0.5...5.0, step: 0.5)
                    Text(L10n.General.micSensitivityDesc)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 400)
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.primary.opacity(0.04))
            )
            .padding(.horizontal, 40)

            Spacer()
        }
        .padding()
        .onAppear {
            inputDevices = AudioSessionManager.listInputDevices()
            if !isMicTesting {
                toggleMicTest()
            }
        }
        .onDisappear {
            if isMicTesting {
                micTester.stop()
                isMicTesting = false
            }
        }
    }

    // MARK: - Hotkey Recording

    private func startRecording() {
        isRecordingHotkey = true
        recordingTimeRemaining = recordingTimeout

        GlobalHotKeyManager.shared.startRecording { keyCode, modifiers in
            settingsStore.hotkeyKeyCode = Int(keyCode)
            settingsStore.hotkeyModifiers = Int(modifiers.rawValue)
            isRecordingHotkey = false
            GlobalHotKeyManager.shared.register(
                keyCode: keyCode,
                modifiers: modifiers
            )
        }
        startCountdown()
    }

    private func startCountdown() {
        // 可取消的 Task 取代遞迴 asyncAfter，避免重複開始錄製時多條倒數同時跑
        countdownTask?.cancel()
        countdownTask = Task { @MainActor in
            while recordingTimeRemaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled || !isRecordingHotkey { return }
                recordingTimeRemaining -= 1
            }
            if isRecordingHotkey { cancelRecording() }
        }
    }

    private func cancelRecording() {
        countdownTask?.cancel()
        countdownTask = nil
        GlobalHotKeyManager.shared.cancelRecording()
        isRecordingHotkey = false
        recordingTimeRemaining = 0
    }

    // MARK: - Mic Testing

    private func toggleMicTest() {
        if isMicTesting {
            micTester.stop()
            isMicTesting = false
        } else {
            micTester.start()
            isMicTesting = true
        }
    }

    // MARK: - Page 2: Features Overview

    private var featuresPage: some View {
        VStack(spacing: 16) {
            Text(L10n.Tutorial.advancedTitle)
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.top, 12)

            // Two-column layout
            HStack(alignment: .top, spacing: 24) {
                // Left column: Modes
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.Tutorial.modesTitle)
                        .font(.title2)
                        .fontWeight(.semibold)

                    compactModeRow(icon: "mic.fill", name: L10n.Tutorial.dictationName, desc: L10n.Tutorial.dictationDesc, color: .blue)
                    compactModeRow(icon: "terminal.fill", name: L10n.Tutorial.commandName, desc: L10n.Tutorial.commandDesc, color: .orange)
                    compactModeRow(icon: "pencil", name: L10n.Tutorial.editName, desc: L10n.Tutorial.editDesc, color: .green)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                // Right column: Smart Features
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.Tutorial.contextTitle)
                        .font(.title2)
                        .fontWeight(.semibold)

                    compactFeatureRow(icon: "calendar.badge.plus", title: L10n.Tutorial.actionIntents, color: .red)
                    compactFeatureRow(icon: "text.cursor", title: L10n.Tutorial.contextFeature, color: .purple)
                    compactFeatureRow(icon: "eye.fill", title: L10n.Tutorial.previewFeature, color: .blue)
                    compactFeatureRow(icon: "paperplane.fill", title: L10n.Tutorial.smartSendFeature, color: .cyan)
                    compactFeatureRow(icon: "sparkles", title: L10n.Tutorial.voiceSkills, color: .orange)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 28)

            Spacer()

            // Visual flow
            HStack(spacing: 10) {
                flowStep(icon: "keyboard", label: "Hotkey")
                Image(systemName: "arrow.right")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                flowStep(icon: "mic.fill", label: "Speak")
                Image(systemName: "arrow.right")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                flowStep(icon: "brain", label: "AI")
                Image(systemName: "arrow.right")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                flowStep(icon: "text.badge.checkmark", label: "Done")
            }
            .padding(.bottom, 12)
        }
        .padding()
    }

    private func compactModeRow(icon: String, name: String, desc: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.title3)
                    .fontWeight(.medium)
                Text(desc)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func compactFeatureRow(icon: String, title: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(color)
                .frame(width: 28)
            Text(title)
                .font(.title3)
        }
    }

    private func flowStep(icon: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(.accentColor)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(width: 60, height: 50)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.06))
        )
    }

    // MARK: - Practice Pages

    private struct PracticeContent {
        let title: String
        let script: String
        let hint: String
        let icon: String
        let color: Color
        let defaultText: String?
        let selectHint: String?
    }

    private func practiceContent(for step: Int) -> PracticeContent {
        switch step {
        case 1:
            return PracticeContent(
                title: L10n.Tutorial.practice1Title,
                script: L10n.Tutorial.practice1Script,
                hint: L10n.Tutorial.practice1Hint,
                icon: "mic.fill",
                color: .blue,
                defaultText: nil,
                selectHint: nil
            )
        case 2:
            return PracticeContent(
                title: L10n.Tutorial.practice2Title,
                script: L10n.Tutorial.practice2Script,
                hint: L10n.Tutorial.practice2Hint,
                icon: "globe",
                color: .green,
                defaultText: L10n.Tutorial.practice2DefaultText,
                selectHint: L10n.Tutorial.practice2SelectHint
            )
        case 3:
            return PracticeContent(
                title: L10n.Tutorial.practice3Title,
                script: L10n.Tutorial.practice3Script,
                hint: L10n.Tutorial.practice3Hint,
                icon: "calendar.badge.plus",
                color: .red,
                defaultText: nil,
                selectHint: nil
            )
        case 4:
            return PracticeContent(
                title: L10n.Tutorial.practice4Title,
                script: L10n.Tutorial.practice4Script,
                hint: L10n.Tutorial.practice4Hint,
                icon: "bell.badge",
                color: .orange,
                defaultText: nil,
                selectHint: nil
            )
        default:
            return PracticeContent(title: "", script: "", hint: "", icon: "mic", color: .gray, defaultText: nil, selectHint: nil)
        }
    }

    private func practicePage(step: Int) -> some View {
        let content = practiceContent(for: step)
        let hasDefaultText = content.defaultText != nil

        return VStack(spacing: 12) {
            // Header
            HStack {
                Image(systemName: content.icon)
                    .font(.system(size: 40))
                    .foregroundStyle(content.color)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(L10n.Tutorial.practiceStep) \(step) / 4")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(content.title)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                }

                Spacer()

                // Step indicator
                HStack(spacing: 6) {
                    ForEach(1...4, id: \.self) { i in
                        Circle()
                            .fill(i == step ? content.color : Color.primary.opacity(0.15))
                            .frame(width: 12, height: 12)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 10)

            // Script card
            VStack(alignment: .leading, spacing: 8) {
                Text("📢 " + L10n.Tutorial.practiceStep + "：")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Text(content.script)
                    .font(.system(.title, design: .rounded))
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(content.color.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(content.color.opacity(0.2), lineWidth: 1)
            )
            .padding(.horizontal, 28)

            // Hint
            Text(content.hint)
                .font(.title3)
                .foregroundStyle(hasDefaultText ? content.color : .secondary)
                .fontWeight(hasDefaultText ? .medium : .regular)
                .padding(.horizontal, 28)

            // Input area
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let selectHint = content.selectHint {
                        Text(selectHint)
                            .font(.title3)
                            .foregroundStyle(content.color)
                    } else {
                        Text(L10n.Tutorial.practiceInputHint)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !practiceText.isEmpty && practiceText != content.defaultText {
                        Button(L10n.Tutorial.practiceInputClear) {
                            practiceText = content.defaultText ?? ""
                        }
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    }
                }

                TextEditor(text: $practiceText)
                    .font(.system(.title2, design: .rounded))
                    .frame(height: 100)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                isTextFieldFocused ? content.color.opacity(0.5) : Color.primary.opacity(0.1),
                                lineWidth: isTextFieldFocused ? 2 : 1
                            )
                    )
                    .focused($isTextFieldFocused)
                    .overlay(
                        Group {
                            if practiceText.isEmpty {
                                Text(L10n.Tutorial.practiceInputPlaceholder)
                                    .font(.title3)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                    .allowsHitTesting(false)
                            }
                        },
                        alignment: .topLeading
                    )
            }
            .padding(.horizontal, 28)

            // Hotkey reminder (no Spacer, directly at bottom)
            HStack(spacing: 14) {
                Text(L10n.Tutorial.practiceTryIt)
                    .font(.title3)

                Text(GlobalHotKeyManager.hotkeyDescription(
                    keyCode: UInt16(settingsStore.hotkeyKeyCode),
                    modifiers: CGEventFlags(rawValue: UInt64(settingsStore.hotkeyModifiers))
                ))
                .font(.system(.title3, design: .rounded))
                .fontWeight(.semibold)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.1))
                )
            }
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .onAppear {
            // Pre-fill default text for practice 2 (translation)
            if let defaultText = content.defaultText {
                practiceText = defaultText
            }
            // Auto-focus the text field
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isTextFieldFocused = true
            }
        }
    }
}

//
//  OnboardingView.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//
//  第一次啟動的引導：語言 → 權限 → 選 AI 方式 → API Key（只有雲端才有）→ 完成。
//  API Key 這一步要讓完全沒碰過 API 的人也能做完：說明 Key 是什麼、三步驟怎麼拿、
//  要不要儲值、貼上後立刻測試並把錯誤翻成可行動的提示。
//

import AppKit
import Speech
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var settingsStore: SettingsStore
    @State private var currentStep = 0
    @State private var micGranted = false
    @State private var speechGranted = false
    @State private var accessibilityGranted = false

    // AI 方式
    private enum AIChoice { case cloud, local, server }
    @State private var aiChoice: AIChoice = .cloud

    // API Key
    @State private var apiKey = ""
    @State private var showKey = false
    @State private var apiKeySaved = false
    @State private var isTesting = false
    @State private var testSucceeded: Bool?
    @State private var testMessage: String?
    @State private var testHint: String?
    @State private var testTask: Task<Void, Never>?

    var onComplete: () -> Void
    var onStartTutorial: (() -> Void)?

    private enum Step: Int { case language, permissions, aiChoice, apiKey, done }
    private let totalSteps = 5

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(currentStep == 0 ? "Saybit" : L10n.Onboarding.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                if currentStep > 0 {
                    Text(L10n.Onboarding.stepOf(currentStep, totalSteps - 1))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()

            Divider()

            // Content
            Group {
                switch Step(rawValue: currentStep) ?? .language {
                case .language: languageStep
                case .permissions: permissionsStep
                case .aiChoice: aiChoiceStep
                case .apiKey: apiKeyStep
                case .done: doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()

            Divider()

            // Navigation
            HStack {
                if currentStep > 0 {
                    Button(L10n.Common.previous) {
                        withAnimation { currentStep = previousStep() }
                    }
                }

                Spacer()

                if currentStep < totalSteps - 1 {
                    Button(L10n.Common.next) {
                        withAnimation { currentStep = nextStep() }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    HStack(spacing: 10) {
                        if onStartTutorial != nil {
                            Button(L10n.Onboarding.continueTutorial) {
                                markCompleted()
                                onStartTutorial?()
                            }
                            .buttonStyle(.borderedProminent)

                            Button(L10n.Common.startUsing) {
                                markCompleted()
                                onComplete()
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button(L10n.Common.startUsing) {
                                markCompleted()
                                onComplete()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .padding()
        }
        .frame(width: 560, height: 560)
        .onAppear {
            checkPermissions()
            aiChoice = initialChoice()
        }
        .onDisappear { testTask?.cancel() }
    }

    private func markCompleted() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
    }

    /// 本機模型 / 自架伺服器不需要 API Key，跳過那一步
    private func nextStep() -> Int {
        if currentStep == Step.aiChoice.rawValue, aiChoice != .cloud { return Step.done.rawValue }
        return currentStep + 1
    }

    private func previousStep() -> Int {
        if currentStep == Step.done.rawValue, aiChoice != .cloud { return Step.aiChoice.rawValue }
        return currentStep - 1
    }

    private func initialChoice() -> AIChoice {
        switch settingsStore.selectedProviderID {
        case AppleOnDeviceLLM.providerID: return .local
        case "ollama", "lmstudio": return .server
        default: return .cloud
        }
    }

    // MARK: - Step 0: Language Selection

    private var languageStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "globe")
                .font(.system(size: 48))
                .foregroundStyle(.blue.gradient)

            Text(L10n.Onboarding.chooseLanguage)
                .font(.headline)
                .multilineTextAlignment(.center)

            VStack(spacing: 8) {
                ForEach(AppLanguage.allCases) { lang in
                    Button {
                        settingsStore.languagePreference = lang.rawValue
                    } label: {
                        HStack {
                            Text(lang.displayName)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if settingsStore.appLanguage == lang {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(settingsStore.appLanguage == lang
                                    ? Color.accentColor.opacity(0.1)
                                    : Color.primary.opacity(0.03))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    settingsStore.appLanguage == lang
                                        ? Color.accentColor.opacity(0.5)
                                        : Color.clear,
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 280)

            Spacer()
        }
    }

    // MARK: - Step 1: Permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.Onboarding.permissionsTitle)
                .font(.headline)

            Text(L10n.Onboarding.permissionsDesc)
                .foregroundColor(.secondary)

            VStack(spacing: 12) {
                permissionRow(
                    icon: "mic.fill",
                    title: L10n.Onboarding.micTitle,
                    description: L10n.Onboarding.micDesc,
                    granted: micGranted
                ) {
                    AVAudioApplication.requestRecordPermission { granted in
                        DispatchQueue.main.async {
                            micGranted = granted
                            if !granted {
                                openSystemSettings("com.apple.preference.security?Privacy_Microphone")
                            }
                        }
                    }
                }

                permissionRow(
                    icon: "waveform",
                    title: L10n.Onboarding.speechTitle,
                    description: L10n.Onboarding.speechDesc,
                    granted: speechGranted
                ) {
                    SFSpeechRecognizer.requestAuthorization { status in
                        DispatchQueue.main.async {
                            speechGranted = status == .authorized
                            if status != .authorized {
                                openSystemSettings("com.apple.preference.security?Privacy_SpeechRecognition")
                            }
                        }
                    }
                }

                permissionRow(
                    icon: "accessibility",
                    title: L10n.Onboarding.accessibilityTitle,
                    description: L10n.Onboarding.accessibilityDesc,
                    granted: accessibilityGranted
                ) {
                    AccessibilityManager.shared.promptIfNeeded()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        accessibilityGranted = AccessibilityManager.shared.isAuthorized
                    }
                }
            }

            Button(L10n.Onboarding.recheckPermissions) {
                checkPermissions()
            }
            .font(.caption)
            .foregroundColor(.accentColor)
        }
        // 從系統設定授權回來時自動更新
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkPermissions()
        }
    }

    private func openSystemSettings(_ path: String) {
        if let url = URL(string: "x-apple.systempreferences:\(path)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func permissionRow(
        icon: String,
        title: String,
        description: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading) {
                Text(title).font(.body)
                Text(description).font(.caption).foregroundColor(.secondary)
            }

            Spacer()

            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Button(L10n.Common.openSettings) { action() }
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
    }

    // MARK: - Step 2: AI choice

    private var aiChoiceStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.Onboarding.aiChoiceTitle)
                .font(.headline)
            Text(L10n.Onboarding.aiChoiceDesc)
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            choiceCard(.cloud, icon: "cloud.fill",
                       title: L10n.Onboarding.choiceCloudTitle,
                       description: L10n.Onboarding.choiceCloudDesc,
                       status: nil, statusOK: true)

            choiceCard(.local, icon: "apple.logo",
                       title: L10n.Onboarding.choiceLocalTitle,
                       description: L10n.Onboarding.choiceLocalDesc,
                       status: AppleOnDeviceLLM.unavailableReason ?? L10n.Onboarding.localAvailable,
                       statusOK: AppleOnDeviceLLM.isAvailable)

            choiceCard(.server, icon: "server.rack",
                       title: L10n.Onboarding.choiceServerTitle,
                       description: L10n.Onboarding.choiceServerDesc,
                       status: nil, statusOK: true)

            Spacer(minLength: 0)
        }
    }

    private func choiceCard(_ choice: AIChoice, icon: String, title: String, description: String,
                            status: String?, statusOK: Bool) -> some View {
        let selected = aiChoice == choice
        return Button {
            selectChoice(choice)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 26)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body).fontWeight(.medium)
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let status {
                        Label(status, systemImage: statusOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(statusOK ? .green : .orange)
                    }
                }
                Spacer()
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func selectChoice(_ choice: AIChoice) {
        aiChoice = choice
        switch choice {
        case .local:
            settingsStore.selectedProviderID = AppleOnDeviceLLM.providerID
            settingsStore.selectedModel = LLMProvider.defaultModel(for: AppleOnDeviceLLM.providerID) ?? AppleOnDeviceLLM.providerID
        case .server:
            if !["ollama", "lmstudio"].contains(settingsStore.selectedProviderID) {
                settingsStore.selectedProviderID = "ollama"
                settingsStore.selectedModel = LLMProvider.defaultModel(for: "ollama") ?? settingsStore.selectedModel
            }
        case .cloud:
            if !onboardingProviders.contains(where: { $0.id == settingsStore.selectedProviderID }) {
                selectProvider(.openRouter)
            }
        }
    }

    // MARK: - Step 3: API Key

    /// 引導快速選擇用的雲端服務商；使用者若已選了其他雲端服務商（Together / 自訂）也一併列出
    private var onboardingProviders: [LLMProvider] {
        var list: [LLMProvider] = [.openRouter, .openAI, .deepSeek, .groq]
        if let current = settingsStore.allProviders.first(where: { $0.id == settingsStore.selectedProviderID }),
           current.requiresAPIKey, !list.contains(where: { $0.id == current.id }) {
            list.append(current)
        }
        return list
    }

    private var currentProvider: LLMProvider {
        settingsStore.allProviders.first(where: { $0.id == settingsStore.selectedProviderID }) ?? .openRouter
    }

    private var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var apiKeyStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.Onboarding.apiKeyTitle)
                    .font(.headline)

                Text(L10n.Onboarding.apiKeyIntro)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // 服務商
                Text(L10n.Onboarding.chooseProvider)
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 6) {
                    ForEach(onboardingProviders) { p in
                        Button {
                            selectProvider(p)
                        } label: {
                            Text(p.name)
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .tint(settingsStore.selectedProviderID == p.id ? .accentColor : .secondary)
                    }
                }
                if let blurb = currentProvider.onboardingBlurb {
                    Text(blurb).font(.caption).foregroundColor(.secondary)
                }

                // 三步驟
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        stepBadge(1)
                        Text(L10n.Onboarding.keyStep1(currentProvider.name))
                        if let url = currentProvider.keyPortalURL {
                            Button(L10n.Onboarding.openKeyPage) { NSWorkspace.shared.open(url) }
                                .controlSize(.small)
                        }
                    }
                    HStack(spacing: 8) { stepBadge(2); Text(L10n.Onboarding.keyStep2) }
                    HStack(spacing: 8) { stepBadge(3); Text(L10n.Onboarding.keyStep3) }
                    if currentProvider.needsPrepaidCredit {
                        Label(L10n.Onboarding.keyNeedsCredit(currentProvider.name), systemImage: "creditcard")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                }
                .font(.callout)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))

                // 輸入
                HStack(spacing: 8) {
                    Group {
                        if showKey {
                            TextField(currentProvider.keyPlaceholder, text: $apiKey)
                        } else {
                            SecureField(currentProvider.keyPlaceholder, text: $apiKey)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveAndTest() }

                    Button {
                        showKey.toggle()
                    } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(showKey ? L10n.Common.hide : L10n.Common.show)

                    Button {
                        if let pasted = NSPasteboard.general.string(forType: .string) {
                            apiKey = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.Onboarding.pasteFromClipboard)
                }

                HStack(spacing: 10) {
                    Button {
                        saveAndTest()
                    } label: {
                        if isTesting {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(L10n.Onboarding.testing)
                            }
                        } else {
                            Text(L10n.Onboarding.saveAndTest)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedKey.isEmpty || isTesting)

                    if apiKeySaved, testSucceeded == nil, !isTesting {
                        Label(L10n.Onboarding.apiKeySaved, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }

                if let testMessage {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(testMessage, systemImage: testSucceeded == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.callout)
                            .foregroundColor(testSucceeded == true ? .green : .red)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if let testHint {
                            Text(testHint)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill((testSucceeded == true ? Color.green : Color.red).opacity(0.08)))
                }

                Text(L10n.Onboarding.skipKeyHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear { loadKeyForCurrentProvider() }
    }

    private func stepBadge(_ n: Int) -> some View {
        Text("\(n)")
            .font(.caption).fontWeight(.bold)
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Color.accentColor.opacity(0.8)))
    }

    private func selectProvider(_ p: LLMProvider) {
        testTask?.cancel()
        settingsStore.selectedProviderID = p.id
        // 換服務商就換成它的預設模型，否則會拿 OpenRouter 格式的模型名去打 OpenAI
        if let preset = LLMProvider.defaultModel(for: p.id) {
            settingsStore.selectedModel = preset
        }
        loadKeyForCurrentProvider()
    }

    private func loadKeyForCurrentProvider() {
        apiKey = KeychainHelper.loadAPIKey(for: currentProvider.id) ?? ""
        apiKeySaved = !apiKey.isEmpty
        testSucceeded = nil
        testMessage = nil
        testHint = nil
        isTesting = false
    }

    private func saveAndTest() {
        let key = trimmedKey
        guard !key.isEmpty else { return }
        let provider = currentProvider
        do {
            try KeychainHelper.saveAPIKey(key, for: provider.id)
        } catch {
            testSucceeded = false
            testMessage = L10n.Common.saveFailed
            testHint = nil
            return
        }
        apiKey = key
        apiKeySaved = true
        if settingsStore.selectedModel.isEmpty, let preset = LLMProvider.defaultModel(for: provider.id) {
            settingsStore.selectedModel = preset
        }

        isTesting = true
        testSucceeded = nil
        testMessage = nil
        testHint = nil
        let model = settingsStore.selectedModel.isEmpty
            ? (LLMProvider.defaultModel(for: provider.id) ?? "")
            : settingsStore.selectedModel
        testTask?.cancel()
        testTask = Task {
            let client = OpenRouterClient()
            do {
                try await client.testConnection(model: model, provider: provider)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    testSucceeded = true
                    testMessage = L10n.Onboarding.testSuccess
                    isTesting = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    testSucceeded = false
                    testMessage = TextRefiner.friendlyErrorMessage(error)
                    testHint = Self.hint(for: error, provider: provider)
                    isTesting = false
                }
            }
        }
    }

    /// 把常見失敗翻成「接下來該做什麼」
    private static func hint(for error: Error, provider: LLMProvider) -> String? {
        guard let ce = error as? OpenRouterClient.ClientError else { return nil }
        switch ce {
        case .invalidResponse(let code), .httpError(let code, _), .retriesExhausted(let code, _):
            switch code {
            case 401, 403: return L10n.Onboarding.testHint401
            case 402: return L10n.Onboarding.testHint402(provider.name)
            default: return nil
            }
        case .networkError: return L10n.Onboarding.testHintNetwork
        default: return nil
        }
    }

    // MARK: - Step 4: Done

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.Onboarding.doneTitle)
                .font(.headline)

            doneRow(icon: "keyboard", text: L10n.Onboarding.doneHotkey(currentHotkeyLabel))
            doneRow(icon: "gearshape", text: L10n.Onboarding.doneSettings)
            doneRow(icon: "waveform.circle", text: L10n.Onboarding.doneOffline)

            if aiChoice == .cloud, !apiKeySaved {
                Label(L10n.Onboarding.doneNoKeyWarning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if aiChoice == .server {
                Label(L10n.Onboarding.doneServerHint, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if !accessibilityGranted {
                Label(L10n.Onboarding.accessibilityTitle + "：" + L10n.Common.notSet, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Spacer()
        }
        .onAppear {
            checkPermissions()
            apiKeySaved = !(KeychainHelper.loadAPIKey(for: currentProvider.id) ?? "").isEmpty
        }
    }

    private func doneRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundColor(.accentColor)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var currentHotkeyLabel: String {
        GlobalHotKeyManager.hotkeyDescription(
            keyCode: UInt16(settingsStore.hotkeyKeyCode),
            modifiers: CGEventFlags(rawValue: UInt64(settingsStore.hotkeyModifiers))
        )
    }

    // MARK: - Helpers

    private func checkPermissions() {
        micGranted = AVAudioApplication.shared.recordPermission == .granted
        speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
        accessibilityGranted = AccessibilityManager.shared.isAuthorized
    }
}

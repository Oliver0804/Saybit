//
//  APISettingsView.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import SwiftUI

struct APISettingsView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var searchState: SettingsSearchState
    @State private var apiKey: String = ""
    @State private var hasKey: Bool = false
    @State private var showKey: Bool = false
    @State private var saveStatus: String = ""
    @State private var isTesting: Bool = false
    @State private var testResult: String = ""
    @State private var showAddCustom: Bool = false
    @State private var customName: String = ""
    @State private var customBaseURL: String = ""
    @State private var ollamaRunning: Bool? = nil
    @State private var ollamaModels: [String] = []
    @State private var lmStudioRunning: Bool? = nil
    @State private var lmStudioModels: [String] = []
    @State private var fetchedCloudModels: [String] = []
    @State private var isFetchingCloudModels: Bool = false
    @State private var cloudModelsError: String = ""
    @State private var cloudModelsSearch: String = ""
    @State private var fetchModelsTask: Task<Void, Never>? = nil
    @State private var testConnectionTask: Task<Void, Never>? = nil

    private var currentProvider: LLMProvider {
        settingsStore.selectedProvider
    }

    // 每張卡片的搜尋關鍵字（卡片顯示與「沒有結果」共用同一份）
    private enum Keys {
        static let provider = ["API", "provider", "模型", "model", "服務商", "服务商", "OpenRouter", "Ollama", "LM Studio",
                               "自訂", "custom", "key", "金鑰", "密钥", "本地", "local", "連線", "connection", "test", "測試",
                               "apple", "本機", "離線"]
        static let advanced = ["進階", "advanced", "max_tokens", "penalty", "top_p", "參數", "参数", "高级"]
        static let prompt = ["prompt", "風格", "style", "提示詞", "提示词", "模式"]
        static let tone = ["語氣", "tone", "語調", "语气"]
        static let all = [provider, advanced, prompt, tone]
    }

    private func shows(_ keys: [String]) -> Bool {
        settingsMatchesSearch(keys, searchText: searchState.searchText)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // MARK: - API 設定（合併：服務商 + API Key + 模型）
                if shows(Keys.provider) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 14) {
                            GlassSectionHeader(title: L10n.API.provider, icon: "server.rack")

                            // Provider picker
                            HStack {
                                Picker(L10n.API.providerPicker, selection: $settingsStore.selectedProviderID) {
                                    ForEach(settingsStore.allProviders) { provider in
                                        Text(provider.name).tag(provider.id)
                                    }
                                }
                                .labelsHidden()
                                .fixedSize()
                                .onChange(of: settingsStore.selectedProviderID) { _, newID in
                                    loadKeyForCurrentProvider()
                                    updateModelForProvider(newID)
                                    testResult = ""
                                    saveStatus = ""
                                    fetchedCloudModels = []
                                    cloudModelsError = ""
                                    cloudModelsSearch = ""
                                }

                                Button {
                                    showAddCustom = true
                                } label: {
                                    Label(L10n.API.addCustomEndpoint, systemImage: "plus")
                                }
                                .controlSize(.small)
                                .buttonStyle(.bordered)

                                if !settingsStore.customProviders.isEmpty {
                                    ForEach(settingsStore.customProviders) { cp in
                                        if settingsStore.selectedProviderID == cp.id {
                                            Button {
                                                removeCustomProvider(cp)
                                            } label: {
                                                Image(systemName: "trash")
                                            }
                                            .controlSize(.small)
                                            .buttonStyle(.bordered)
                                            .tint(.red)
                                            .help(L10n.API.removeProvider(cp.name))
                                            .accessibilityLabel(L10n.API.removeProvider(cp.name))
                                        }
                                    }
                                }
                            }

                            Divider()

                            // API Key section (for providers that require key)
                            if currentProvider.requiresAPIKey {
                                // 怎麼拿 Key、要不要儲值：讓第一次設定的人不用去翻文件
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 10) {
                                        if let blurb = currentProvider.onboardingBlurb {
                                            Text(blurb).font(.callout).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if let url = currentProvider.keyPortalURL {
                                            Link(destination: url) {
                                                Label(L10n.Onboarding.getProviderKey(currentProvider.name), systemImage: "key")
                                                    .font(.callout)
                                            }
                                        }
                                    }
                                    if currentProvider.needsPrepaidCredit {
                                        Text(L10n.Onboarding.keyNeedsCredit(currentProvider.name))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.bottom, 2)

                                HStack(spacing: 8) {
                                    Group {
                                        if showKey {
                                            TextField(currentProvider.keyPlaceholder, text: $apiKey)
                                        } else {
                                            SecureField(currentProvider.keyPlaceholder, text: $apiKey)
                                        }
                                    }
                                    .textFieldStyle(.roundedBorder)

                                    Button(showKey ? L10n.Common.hide : L10n.Common.show) {
                                        showKey.toggle()
                                    }
                                    .controlSize(.small)
                                    .buttonStyle(.bordered)
                                }

                                HStack(spacing: 8) {
                                    Button(L10n.Common.save) {
                                        guard !trimmedAPIKey.isEmpty else { return }
                                        do {
                                            try KeychainHelper.saveAPIKey(trimmedAPIKey, for: currentProvider.id)
                                            apiKey = trimmedAPIKey
                                            hasKey = !apiKey.isEmpty
                                            showTemporaryStatus(L10n.Common.saved)
                                        } catch {
                                            showTemporaryStatus(L10n.Common.saveFailed)
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(trimmedAPIKey.isEmpty)

                                    Button(L10n.API.clear) {
                                        KeychainHelper.deleteAPIKey(for: currentProvider.id)
                                        apiKey = ""
                                        hasKey = false
                                        showTemporaryStatus(L10n.Common.cleared)
                                    }
                                    .controlSize(.small)
                                    .buttonStyle(.bordered)
                                    .tint(.red)

                                    Button {
                                        testAPIConnection()
                                    } label: {
                                        if isTesting {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Text(L10n.Common.testConnection)
                                        }
                                    }
                                    .controlSize(.small)
                                    .buttonStyle(.bordered)
                                    .disabled(isTesting || !hasKey)

                                    Spacer()

                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(hasKey ? Color.green : Color.red)
                                            .frame(width: 8, height: 8)
                                        Text(L10n.API.apiKeySet(hasKey))
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                if !saveStatus.isEmpty {
                                    Text(saveStatus)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .transition(.opacity)
                                }
                            } else if currentProvider.id == "lmstudio" {
                                // LM Studio: URL + optional API key + status
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(L10n.API.serverAddress)
                                        .font(.headline)

                                    TextField("http://192.168.0.147:1234", text: $settingsStore.lmStudioBaseURL)
                                        .textFieldStyle(.roundedBorder)
                                        .onSubmit {
                                            checkLMStudioStatus()
                                        }
                                        .onChange(of: settingsStore.lmStudioBaseURL) { _, _ in
                                            lmStudioRunning = nil
                                            lmStudioModels = []
                                        }

                                    Text(L10n.API.apiKeyOptional)
                                        .font(.headline)
                                        .padding(.top, 4)

                                    HStack(spacing: 8) {
                                        Group {
                                            if showKey {
                                                TextField(currentProvider.keyPlaceholder, text: $apiKey)
                                            } else {
                                                SecureField(currentProvider.keyPlaceholder, text: $apiKey)
                                            }
                                        }
                                        .textFieldStyle(.roundedBorder)

                                        Button(showKey ? L10n.Common.hide : L10n.Common.show) {
                                            showKey.toggle()
                                        }
                                        .controlSize(.small)
                                        .buttonStyle(.bordered)
                                    }

                                    HStack(spacing: 8) {
                                        Button(L10n.Common.save) {
                                            do {
                                                // 選填：清空後儲存等同移除，不在 Keychain 留空字串
                                                apiKey = trimmedAPIKey
                                                if apiKey.isEmpty {
                                                    KeychainHelper.deleteAPIKey(for: currentProvider.id)
                                                } else {
                                                    try KeychainHelper.saveAPIKey(apiKey, for: currentProvider.id)
                                                }
                                                hasKey = !apiKey.isEmpty
                                                showTemporaryStatus(L10n.Common.saved)
                                            } catch {
                                                showTemporaryStatus(L10n.Common.saveFailed)
                                            }
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)

                                        if hasKey {
                                            Button(L10n.API.clear) {
                                                KeychainHelper.deleteAPIKey(for: currentProvider.id)
                                                apiKey = ""
                                                hasKey = false
                                                showTemporaryStatus(L10n.Common.cleared)
                                            }
                                            .controlSize(.small)
                                            .buttonStyle(.bordered)
                                            .tint(.red)
                                        }
                                    }

                                    if !saveStatus.isEmpty {
                                        Text(saveStatus)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                            .transition(.opacity)
                                    }

                                    Divider().opacity(0.3)
                                }

                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(lmStudioStatusColor)
                                        .frame(width: 8, height: 8)
                                    Text(lmStudioStatusText)
                                        .font(.body)

                                    Spacer()

                                    Button {
                                        checkLMStudioStatus()
                                    } label: {
                                        Label(L10n.Common.recheck, systemImage: "arrow.clockwise")
                                    }
                                    .controlSize(.small)
                                    .buttonStyle(.bordered)

                                    Button {
                                        testAPIConnection()
                                    } label: {
                                        if isTesting {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Text(L10n.Common.testConnection)
                                        }
                                    }
                                    .controlSize(.small)
                                    .buttonStyle(.bordered)
                                    .disabled(isTesting || lmStudioRunning != true)
                                }

                                if !lmStudioModels.isEmpty {
                                    FlowLayout(spacing: 4) {
                                        ForEach(lmStudioModels, id: \.self) { model in
                                            Button(model) {
                                                settingsStore.selectedModel = model
                                            }
                                            .controlSize(.mini)
                                            .buttonStyle(.bordered)
                                            .tint(settingsStore.selectedModel == model ? .accentColor : .secondary)
                                        }
                                    }
                                }

                                Text(L10n.API.lmStudioHint)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            } else if currentProvider.id == AppleOnDeviceLLM.providerID {
                                // Apple 本機模型：不走 Ollama 偵測，也不改 selectedModel
                                VStack(alignment: .leading, spacing: 6) {
                                    if let reason = AppleOnDeviceLLM.unavailableReason {
                                        Label(reason, systemImage: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.orange)
                                    } else {
                                        Label(L10n.API.appleAvailable, systemImage: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                    SettingDescription(L10n.API.appleDesc)
                                }
                                .font(.callout)

                                HStack {
                                    Spacer()
                                    Button {
                                        testAPIConnection()
                                    } label: {
                                        if isTesting {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Text(L10n.Common.testConnection)
                                        }
                                    }
                                    .controlSize(.small)
                                    .buttonStyle(.bordered)
                                    .disabled(isTesting || AppleOnDeviceLLM.unavailableReason != nil)
                                }
                            } else if currentProvider.id == "ollama" {
                                // Ollama status
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(ollamaStatusColor)
                                        .frame(width: 8, height: 8)
                                    Text(ollamaStatusText)
                                        .font(.body)

                                    Spacer()

                                    Button {
                                        checkOllamaStatus()
                                    } label: {
                                        Label(L10n.Common.recheck, systemImage: "arrow.clockwise")
                                    }
                                    .controlSize(.small)
                                    .buttonStyle(.bordered)

                                    Button {
                                        testAPIConnection()
                                    } label: {
                                        if isTesting {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Text(L10n.Common.testConnection)
                                        }
                                    }
                                    .controlSize(.small)
                                    .buttonStyle(.bordered)
                                    .disabled(isTesting || ollamaRunning != true)
                                }

                                if !ollamaModels.isEmpty {
                                    FlowLayout(spacing: 4) {
                                        ForEach(ollamaModels, id: \.self) { model in
                                            Button(model) {
                                                settingsStore.selectedModel = model
                                            }
                                            .controlSize(.mini)
                                            .buttonStyle(.bordered)
                                            .tint(settingsStore.selectedModel == model ? .accentColor : .secondary)
                                        }
                                    }
                                }

                                Text(L10n.API.ollamaHint)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }

                            if !testResult.isEmpty {
                                HStack(spacing: 4) {
                                    Image(systemName: testResult.starts(with: "✓") ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(testResult.starts(with: "✓") ? .green : .red)
                                    Text(testResult)
                                        .foregroundStyle(testResult.starts(with: "✓") ? .green : .red)
                                }
                                .font(.callout)
                                .transition(.opacity)
                            }

                            Divider()

                            // Model section
                            HStack {
                                Text(L10n.API.model)
                                    .font(.headline)
                                Spacer()
                                if currentProvider.requiresAPIKey {
                                    Button {
                                        fetchCloudModels()
                                    } label: {
                                        if isFetchingCloudModels {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Label(L10n.APIModels.listButton, systemImage: "arrow.clockwise")
                                        }
                                    }
                                    .controlSize(.small)
                                    .buttonStyle(.bordered)
                                    .disabled(isFetchingCloudModels || !hasKey)
                                }
                            }

                            TextField("Model ID", text: $settingsStore.selectedModel)
                                .textFieldStyle(.roundedBorder)

                            if currentProvider.requiresAPIKey, !fetchedCloudModels.isEmpty {
                                if fetchedCloudModels.count > 12 {
                                    TextField(L10n.APIModels.searchPlaceholder, text: $cloudModelsSearch)
                                        .textFieldStyle(.roundedBorder)
                                        .controlSize(.small)
                                }
                                FlowLayout(spacing: 4) {
                                    ForEach(filteredCloudModels, id: \.self) { model in
                                        Button(model) {
                                            settingsStore.selectedModel = model
                                        }
                                        .controlSize(.mini)
                                        .buttonStyle(.bordered)
                                        .tint(settingsStore.selectedModel == model ? .accentColor : .secondary)
                                    }
                                }
                                Text(cloudModelsSearch.isEmpty
                                     ? L10n.APIModels.count(fetchedCloudModels.count)
                                     : L10n.APIModels.filteredCount(query: cloudModelsSearch,
                                                                    total: fetchedCloudModels.count,
                                                                    matched: filteredCloudModels.count))
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }

                            if !cloudModelsError.isEmpty {
                                Text(cloudModelsError)
                                    .font(.body)
                                    .foregroundStyle(.red)
                            }

                            if !currentProvider.modelHint.isEmpty {
                                Text(L10n.API.commonModels(currentProvider.modelHint))
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // MARK: - 進階參數
                if shows(Keys.advanced) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            GlassSectionHeader(title: L10n.API.advancedParams, icon: "slider.horizontal.3")

                            SettingToggle(title: L10n.API.useCustomParams, description: L10n.API.advancedParamsDesc,
                                          isOn: $settingsStore.useCustomLLMParams)

                            if settingsStore.useCustomLLMParams {
                                Divider()

                                // Max Tokens
                                HStack {
                                    Text(L10n.API.maxTokens)
                                        .frame(width: 120, alignment: .leading)
                                    Stepper(value: $settingsStore.llmMaxTokens, in: 256...16384, step: 256) {
                                        Text("\(settingsStore.llmMaxTokens)")
                                            .monospacedDigit()
                                            .frame(width: 60, alignment: .trailing)
                                    }
                                }

                                // Frequency Penalty
                                HStack {
                                    Text(L10n.API.frequencyPenalty)
                                        .frame(width: 120, alignment: .leading)
                                    Slider(value: $settingsStore.llmFrequencyPenalty, in: -2.0...2.0, step: 0.1)
                                    Text(String(format: "%.1f", settingsStore.llmFrequencyPenalty))
                                        .monospacedDigit()
                                        .frame(width: 40, alignment: .trailing)
                                }

                                // Presence Penalty
                                HStack {
                                    Text(L10n.API.presencePenalty)
                                        .frame(width: 120, alignment: .leading)
                                    Slider(value: $settingsStore.llmPresencePenalty, in: -2.0...2.0, step: 0.1)
                                    Text(String(format: "%.1f", settingsStore.llmPresencePenalty))
                                        .monospacedDigit()
                                        .frame(width: 40, alignment: .trailing)
                                }

                                // Top P
                                HStack {
                                    Text(L10n.API.topP)
                                        .frame(width: 120, alignment: .leading)
                                    Slider(value: $settingsStore.llmTopP, in: 0.0...1.0, step: 0.05)
                                    Text(String(format: "%.2f", settingsStore.llmTopP))
                                        .monospacedDigit()
                                        .frame(width: 40, alignment: .trailing)
                                }
                            }
                        }
                    }
                }

                // MARK: - Prompt 風格
                if shows(Keys.prompt) {
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
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                        }
                    }
                }

                // MARK: - 語調
                if shows(Keys.tone) {
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
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                        }
                    }
                }

                // No results
                if !searchState.searchText.isEmpty && !Keys.all.contains(where: shows) {
                    SettingsNoResults()
                }
            }
            .padding(20)
        }
        .onAppear {
            loadKeyForCurrentProvider()
        }
        .sheet(isPresented: $showAddCustom) {
            addCustomProviderSheet
        }
    }

    // MARK: - Add Custom Provider Sheet

    private var addCustomProviderSheet: some View {
        VStack(spacing: 16) {
            Text(L10n.API.addCustomTitle)
                .font(.headline)

            TextField(L10n.API.nameHint, text: $customName)
                .textFieldStyle(.roundedBorder)

            TextField(L10n.API.baseURLHint, text: $customBaseURL)
                .textFieldStyle(.roundedBorder)

            switch Self.customURLStatus(customBaseURL) {
            case .empty, .secure:
                EmptyView()
            case .localHTTP:
                Label(L10n.API.localHTTPNote, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .insecure:
                Label(L10n.API.insecureURLWarning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .invalid:
                Label(L10n.API.invalidURL, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button(L10n.Common.cancel) {
                    showAddCustom = false
                    customName = ""
                    customBaseURL = ""
                }
                .buttonStyle(.bordered)

                Button(L10n.Common.add) {
                    addCustomProvider()
                }
                .buttonStyle(.borderedProminent)
                .disabled(customName.trimmingCharacters(in: .whitespaces).isEmpty
                          || !Self.customURLStatus(customBaseURL).isAllowed)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    // MARK: - Custom endpoint URL check

    private enum CustomURLStatus {
        case empty, secure, localHTTP, insecure, invalid
        var isAllowed: Bool { self == .secure || self == .localHTTP }
    }

    /// https 一律允許；http 只允許本機 / 區網（localhost、127.x、10.x、172.16–31.x、192.168.x、*.local），
    /// 避免 API Key 以明文送到公網
    private static func customURLStatus(_ raw: String) -> CustomURLStatus {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard let comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(),
              let host = comps.host?.lowercased(), !host.isEmpty else { return .invalid }
        switch scheme {
        case "https": return .secure
        case "http": return isLocalHost(host) ? .localHTTP : .insecure
        default: return .invalid
        }
    }

    private static func isLocalHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") || host == "[::1]" || host == "::1" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (127, _), (10, _), (192, 168): return true
        case (172, let b): return (16...31).contains(b)
        default: return false
        }
    }

    // MARK: - Actions

    private var ollamaStatusColor: Color {
        switch ollamaRunning {
        case .none: return .gray
        case .some(true): return .green
        case .some(false): return .red
        }
    }

    private var ollamaStatusText: String {
        switch ollamaRunning {
        case .none: return L10n.API.checking
        case .some(true): return L10n.API.connectedModels(ollamaModels.count)
        case .some(false): return L10n.API.notDetected
        }
    }

    // MARK: - LM Studio Status

    private var lmStudioStatusColor: Color {
        switch lmStudioRunning {
        case .none: return .gray
        case .some(true): return .green
        case .some(false): return .red
        }
    }

    private var lmStudioStatusText: String {
        switch lmStudioRunning {
        case .none: return L10n.API.checking
        case .some(true): return L10n.API.connectedModels(lmStudioModels.count)
        case .some(false): return L10n.API.notDetectedServer("LM Studio")
        }
    }

    private func checkLMStudioStatus() {
        lmStudioRunning = nil
        lmStudioModels = []
        let baseURL = settingsStore.lmStudioBaseURL
        Task {
            let running = await LLMProvider.isLMStudioRunning(baseOrigin: baseURL)
            let models = running ? await LLMProvider.fetchLMStudioModels(baseOrigin: baseURL) : []
            await MainActor.run {
                lmStudioRunning = running
                lmStudioModels = models
                if running, !models.isEmpty, !models.contains(settingsStore.selectedModel) {
                    settingsStore.selectedModel = models.first ?? ""
                }
            }
        }
    }

    private func checkOllamaStatus() {
        ollamaRunning = nil
        ollamaModels = []
        Task {
            let running = await LLMProvider.isOllamaRunning()
            let models = running ? await LLMProvider.fetchOllamaModels() : []
            await MainActor.run {
                ollamaRunning = running
                ollamaModels = models
                // Auto-select first model if current model is empty or not in list
                if running, !models.isEmpty, !models.contains(settingsStore.selectedModel) {
                    settingsStore.selectedModel = models.first ?? ""
                }
            }
        }
    }

    private func loadKeyForCurrentProvider() {
        if currentProvider.requiresAPIKey {
            if let key = KeychainHelper.loadAPIKey(for: currentProvider.id) {
                apiKey = key
                // 舊版可能存過空字串，空的不算已設定
                hasKey = !key.isEmpty
            } else {
                apiKey = ""
                hasKey = false
            }
            showKey = false
        } else if currentProvider.id == "lmstudio" {
            // LM Studio: optional API key
            if let key = KeychainHelper.loadAPIKey(for: currentProvider.id) {
                apiKey = key
                hasKey = !key.isEmpty
            } else {
                apiKey = ""
                hasKey = false
            }
            showKey = false
            checkLMStudioStatus()
        } else if currentProvider.id == "ollama" {
            hasKey = true
            apiKey = ""
            checkOllamaStatus()
        } else {
            // Apple 本機模型等不需 key 的 provider：不要跑 Ollama 偵測（它會改掉 selectedModel）
            hasKey = true
            apiKey = ""
        }
    }

    private var trimmedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateModelForProvider(_ providerID: String) {
        // OpenRouter 用 "owner/model" 前綴，沒前綴就帶上預設
        if providerID == "openrouter", !settingsStore.selectedModel.contains("/") {
            settingsStore.selectedModel = LLMProvider.defaultModel(for: providerID) ?? ""
            return
        }
        // OpenAI 不接受前綴，剝掉
        if providerID == "openai", settingsStore.selectedModel.contains("/") {
            let parts = settingsStore.selectedModel.split(separator: "/")
            if let last = parts.last, parts.count > 1 {
                settingsStore.selectedModel = String(last)
            }
        }
        // 其他雲端 provider 一律塞回該 provider 的預設模型
        if let preset = LLMProvider.defaultModel(for: providerID) {
            // 對 openai：上一段已剝前綴，若仍空或含 /，再 fallback
            if providerID == "openai" {
                if settingsStore.selectedModel.isEmpty || settingsStore.selectedModel.contains("/") {
                    settingsStore.selectedModel = preset
                }
            } else if providerID != "openrouter" {
                settingsStore.selectedModel = preset
            }
            return
        }
        // Local providers (ollama, lmstudio) 由 model list 自動帶
        switch providerID {
        case "ollama":
            // Will be auto-selected from available models
            break
        case "lmstudio":
            // Will be auto-selected from available models
            break
        default:
            break
        }
    }

    private func addCustomProvider() {
        guard Self.customURLStatus(customBaseURL).isAllowed else { return }
        let id = "custom-\(UUID().uuidString.prefix(8).lowercased())"
        let provider = LLMProvider.custom(id: id,
                                          name: customName.trimmingCharacters(in: .whitespaces),
                                          baseURL: customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
        settingsStore.customProviders.append(provider)
        settingsStore.selectedProviderID = provider.id
        showAddCustom = false
        customName = ""
        customBaseURL = ""
        loadKeyForCurrentProvider()
    }

    private func removeCustomProvider(_ provider: LLMProvider) {
        KeychainHelper.deleteAPIKey(for: provider.id)
        settingsStore.customProviders.removeAll { $0.id == provider.id }
        if settingsStore.selectedProviderID == provider.id {
            settingsStore.selectedProviderID = "openrouter"
            loadKeyForCurrentProvider()
        }
    }

    private func showTemporaryStatus(_ message: String) {
        saveStatus = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if saveStatus == message {
                saveStatus = ""
            }
        }
    }

    private func testAPIConnection() {
        // 取消前一個 in-flight test，避免使用者連點 chip 時多個並行測試
        testConnectionTask?.cancel()
        isTesting = true
        testResult = ""
        let client = OpenRouterClient()
        let provider = currentProvider
        let model = settingsStore.selectedModel
        testConnectionTask = Task {
            do {
                try await client.testConnection(model: model, provider: provider)
                if Task.isCancelled { return }
                await MainActor.run {
                    testResult = L10n.API.connectionSuccessModel(model)
                    isTesting = false
                    clearTestResult()
                }
            } catch is CancellationError {
                // 被新測試取代，略過
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    testResult = "✗ \(error.localizedDescription)"
                    isTesting = false
                    clearTestResult()
                }
            }
        }
    }

    private func clearTestResult() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            testResult = ""
        }
    }

    // MARK: - Cloud Models Fetch

    private var filteredCloudModels: [String] {
        let q = cloudModelsSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return fetchedCloudModels }
        return fetchedCloudModels.filter { $0.lowercased().contains(q) }
    }

    private func fetchCloudModels() {
        // 取消前一個 in-flight fetch，避免重複點按造成的 race
        fetchModelsTask?.cancel()
        let provider = currentProvider
        isFetchingCloudModels = true
        cloudModelsError = ""
        fetchModelsTask = Task {
            do {
                let models = try await LLMProvider.fetchOpenAIModels(provider: provider)
                if Task.isCancelled { return }
                await MainActor.run {
                    fetchedCloudModels = models
                    isFetchingCloudModels = false
                    if models.isEmpty {
                        cloudModelsError = L10n.APIModels.emptyResponse
                    }
                }
            } catch is CancellationError {
                // 被新 fetch 取代
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    isFetchingCloudModels = false
                    fetchedCloudModels = []
                    cloudModelsError = L10n.APIModels.fetchFailed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Prompt Description

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

// MARK: - Flow Layout (for model chips)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}

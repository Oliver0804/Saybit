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

    private var currentProvider: LLMProvider {
        settingsStore.selectedProvider
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // MARK: - API 設定（合併：服務商 + API Key + 模型）
                if settingsMatchesSearch(["API", "provider", "模型", "model", "服務商", "服务商", "OpenRouter", "Ollama", "LM Studio", "自訂", "custom", "key", "金鑰", "密钥"], searchText: searchState.searchText) {
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
                                .frame(maxWidth: 200)
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
                                        }
                                    }
                                }
                            }

                            Divider()

                            // API Key section (for providers that require key)
                            if currentProvider.requiresAPIKey {
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
                                            try KeychainHelper.saveAPIKey(apiKey, for: currentProvider.id)
                                            hasKey = true
                                            showTemporaryStatus(L10n.Common.saved)
                                        } catch {
                                            showTemporaryStatus(L10n.Common.saveFailed)
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)

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
                                            .font(.title3)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                if !saveStatus.isEmpty {
                                    Text(saveStatus)
                                        .font(.title3)
                                        .foregroundStyle(.secondary)
                                        .transition(.opacity)
                                }
                            } else if currentProvider.id == "lmstudio" {
                                // LM Studio: URL + optional API key + status
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("伺服器位址")
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

                                    Text("API Key（選填）")
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
                                                try KeychainHelper.saveAPIKey(apiKey, for: currentProvider.id)
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
                                            .font(.title3)
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

                                Text("連接 LM Studio 本地伺服器，支援所有 OpenAI 相容模型。")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            } else {
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
                                .font(.title3)
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
                                            Label("列出模型", systemImage: "arrow.clockwise")
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
                                    TextField("搜尋模型…", text: $cloudModelsSearch)
                                        .textFieldStyle(.roundedBorder)
                                        .controlSize(.small)
                                }
                                FlowLayout(spacing: 4) {
                                    ForEach(filteredCloudModels, id: \.self) { model in
                                        Button(model) {
                                            settingsStore.selectedModel = model
                                            testAPIConnection()
                                        }
                                        .controlSize(.mini)
                                        .buttonStyle(.bordered)
                                        .tint(settingsStore.selectedModel == model ? .accentColor : .secondary)
                                    }
                                }
                                Text("共 \(fetchedCloudModels.count) 個模型\(cloudModelsSearch.isEmpty ? "" : "，符合「\(cloudModelsSearch)」共 \(filteredCloudModels.count) 個")")
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
                if settingsMatchesSearch(["進階", "advanced", "max_tokens", "penalty", "top_p", "參數", "参数", "高级"], searchText: searchState.searchText) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            GlassSectionHeader(title: L10n.API.advancedParams, icon: "slider.horizontal.3")

                            Toggle(L10n.API.useCustomParams, isOn: $settingsStore.useCustomLLMParams)
                                .toggleStyle(.switch)

                            Text(L10n.API.advancedParamsDesc)
                                .font(.body)
                                .foregroundStyle(.secondary)

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
                if settingsMatchesSearch(["prompt", "風格", "style", "提示詞", "提示词", "模式"], searchText: searchState.searchText) {
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
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                        }
                    }
                }

                // MARK: - 語調
                if settingsMatchesSearch(["語氣", "tone", "語調", "语气"], searchText: searchState.searchText) {
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
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                        }
                    }
                }

                // No results
                if !searchState.searchText.isEmpty
                    && !settingsMatchesSearch(["API", "provider", "模型", "model", "服務商", "服务商", "OpenRouter", "Ollama", "自訂", "custom"], searchText: searchState.searchText)
                    && !settingsMatchesSearch(["API key", "金鑰", "密钥", "Ollama", "本地", "local", "連線", "connection", "test", "測試"], searchText: searchState.searchText)
                    && !settingsMatchesSearch(["模型", "model", "CPU", "選擇", "select"], searchText: searchState.searchText)
                    && !settingsMatchesSearch(["進階", "advanced", "max_tokens", "penalty", "top_p", "參數", "参数", "高级"], searchText: searchState.searchText)
                    && !settingsMatchesSearch(["prompt", "風格", "style", "提示詞", "提示词", "模式"], searchText: searchState.searchText)
                    && !settingsMatchesSearch(["語氣", "tone", "語調", "语气"], searchText: searchState.searchText)
                {
                    Text(L10n.Common.noResults)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
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
                .disabled(customName.isEmpty || customBaseURL.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
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
                hasKey = true
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
        } else {
            hasKey = true
            apiKey = ""
            checkOllamaStatus()
        }
    }

    private func updateModelForProvider(_ providerID: String) {
        // Auto-update model name when switching providers
        switch providerID {
        case "openrouter":
            // OpenRouter uses prefixed model names
            if !settingsStore.selectedModel.contains("/") {
                settingsStore.selectedModel = "openai/gpt-4.1-nano"
            }
        case "openai":
            // OpenAI uses plain model names
            if settingsStore.selectedModel.contains("/") {
                // Convert "openai/gpt-4.1-nano" to "gpt-4.1-nano"
                let parts = settingsStore.selectedModel.split(separator: "/")
                if parts.count > 1 {
                    settingsStore.selectedModel = String(parts.last!)
                }
            }
            // Ensure valid OpenAI model
            if settingsStore.selectedModel.isEmpty || settingsStore.selectedModel.contains("/") {
                settingsStore.selectedModel = "gpt-4.1-nano"
            }
        case "deepseek":
            settingsStore.selectedModel = "deepseek-chat"
        case "groq":
            settingsStore.selectedModel = "llama-3.3-70b-versatile"
        case "together":
            settingsStore.selectedModel = "meta-llama/Llama-3.3-70B-Instruct-Turbo"
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
        let id = "custom-\(UUID().uuidString.prefix(8).lowercased())"
        let provider = LLMProvider.custom(id: id, name: customName, baseURL: customBaseURL)
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
        isTesting = true
        testResult = ""
        let client = OpenRouterClient()
        let provider = currentProvider
        let model = settingsStore.selectedModel
        Task {
            do {
                try await client.testConnection(model: model, provider: provider)
                await MainActor.run {
                    testResult = L10n.API.connectionSuccessModel(model)
                    isTesting = false
                    clearTestResult()
                }
            } catch {
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
        let provider = currentProvider
        isFetchingCloudModels = true
        cloudModelsError = ""
        Task {
            do {
                let models = try await LLMProvider.fetchOpenAIModels(provider: provider)
                await MainActor.run {
                    fetchedCloudModels = models
                    isFetchingCloudModels = false
                    if models.isEmpty {
                        cloudModelsError = "服務商未回傳任何模型"
                    }
                }
            } catch {
                await MainActor.run {
                    isFetchingCloudModels = false
                    fetchedCloudModels = []
                    cloudModelsError = "抓取失敗：\(error.localizedDescription)"
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

//
//  APISettingsView.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import SwiftUI

struct APISettingsView: View {
    @EnvironmentObject var settingsStore: SettingsStore
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

    private var currentProvider: LLMProvider {
        settingsStore.selectedProvider
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // MARK: - Provider 選擇
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        GlassSectionHeader(title: "API 服務商", icon: "server.rack")

                        Picker("服務商", selection: $settingsStore.selectedProviderID) {
                            ForEach(settingsStore.allProviders) { provider in
                                Text(provider.name).tag(provider.id)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: settingsStore.selectedProviderID) {
                            loadKeyForCurrentProvider()
                            testResult = ""
                            saveStatus = ""
                        }

                        if !settingsStore.customProviders.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(settingsStore.customProviders) { cp in
                                    if settingsStore.selectedProviderID == cp.id {
                                        Button {
                                            removeCustomProvider(cp)
                                        } label: {
                                            Label("移除「\(cp.name)」", systemImage: "trash")
                                        }
                                        .controlSize(.small)
                                        .buttonStyle(.bordered)
                                        .tint(.red)
                                    }
                                }
                            }
                        }

                        Button {
                            showAddCustom = true
                        } label: {
                            Label("新增自訂端點", systemImage: "plus")
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                }

                // MARK: - API Key / Ollama Status
                if currentProvider.requiresAPIKey {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            GlassSectionHeader(title: "\(currentProvider.name) API Key", icon: "key.fill")

                            HStack(spacing: 8) {
                                Group {
                                    if showKey {
                                        TextField(currentProvider.keyPlaceholder, text: $apiKey)
                                    } else {
                                        SecureField(currentProvider.keyPlaceholder, text: $apiKey)
                                    }
                                }
                                .textFieldStyle(.roundedBorder)

                                Button(showKey ? "隱藏" : "顯示") {
                                    showKey.toggle()
                                }
                                .controlSize(.small)
                                .buttonStyle(.bordered)
                            }

                            HStack(spacing: 8) {
                                Button("儲存") {
                                    do {
                                        try KeychainHelper.saveAPIKey(apiKey, for: currentProvider.id)
                                        hasKey = true
                                        showTemporaryStatus("已儲存")
                                    } catch {
                                        showTemporaryStatus("儲存失敗")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)

                                Button("清除") {
                                    KeychainHelper.deleteAPIKey(for: currentProvider.id)
                                    apiKey = ""
                                    hasKey = false
                                    showTemporaryStatus("已清除")
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
                                        Text("測試連線")
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
                                    Text(hasKey ? "已設定" : "未設定")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if !saveStatus.isEmpty {
                                Text(saveStatus)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .transition(.opacity)
                            }

                            if !testResult.isEmpty {
                                HStack(spacing: 4) {
                                    Image(systemName: testResult.starts(with: "✓") ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(testResult.starts(with: "✓") ? .green : .red)
                                    Text(testResult)
                                        .foregroundStyle(testResult.starts(with: "✓") ? .green : .red)
                                }
                                .font(.caption)
                                .transition(.opacity)
                            }
                        }
                    }
                } else {
                    // Ollama / no-key provider
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            GlassSectionHeader(title: "\(currentProvider.name) 狀態", icon: "desktopcomputer")

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
                                    Label("重新檢查", systemImage: "arrow.clockwise")
                                }
                                .controlSize(.small)
                                .buttonStyle(.bordered)

                                Button {
                                    testAPIConnection()
                                } label: {
                                    if isTesting {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Text("測試連線")
                                    }
                                }
                                .controlSize(.small)
                                .buttonStyle(.bordered)
                                .disabled(isTesting || ollamaRunning != true)
                            }

                            if !ollamaModels.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("可用模型：")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
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
                            }

                            Text("無需 API Key，請確保 Ollama 已啟動（ollama serve）")
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            if !testResult.isEmpty {
                                HStack(spacing: 4) {
                                    Image(systemName: testResult.starts(with: "✓") ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(testResult.starts(with: "✓") ? .green : .red)
                                    Text(testResult)
                                        .foregroundStyle(testResult.starts(with: "✓") ? .green : .red)
                                }
                                .font(.caption)
                                .transition(.opacity)
                            }
                        }
                    }
                }

                // MARK: - 模型選擇
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        GlassSectionHeader(title: "模型", icon: "cpu")

                        TextField("Model ID", text: $settingsStore.selectedModel)
                            .textFieldStyle(.roundedBorder)

                        if !currentProvider.modelHint.isEmpty {
                            Text("常用: \(currentProvider.modelHint)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
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
            Text("新增自訂端點")
                .font(.headline)

            TextField("名稱（如 Ollama）", text: $customName)
                .textFieldStyle(.roundedBorder)

            TextField("Base URL（如 http://localhost:11434/v1/chat/completions）", text: $customBaseURL)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("取消") {
                    showAddCustom = false
                    customName = ""
                    customBaseURL = ""
                }
                .buttonStyle(.bordered)

                Button("新增") {
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
        case .none: return "檢查中..."
        case .some(true): return "已連線 (\(ollamaModels.count) 個模型)"
        case .some(false): return "未偵測到 Ollama"
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
        } else {
            hasKey = true
            apiKey = ""
            checkOllamaStatus()
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
                    testResult = "✓ 連線成功 (\(model))"
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

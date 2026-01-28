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
                        GlassSectionHeader(title: L10n.API.provider, icon: "server.rack")

                        Picker(L10n.API.providerPicker, selection: $settingsStore.selectedProviderID) {
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
                                            Label(L10n.API.removeProvider(cp.name), systemImage: "trash")
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
                            Label(L10n.API.addCustomEndpoint, systemImage: "plus")
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
                            GlassSectionHeader(title: L10n.API.providerStatus(currentProvider.name), icon: "desktopcomputer")

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
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(L10n.API.availableModels)
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

                            Text(L10n.API.ollamaHint)
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
                        GlassSectionHeader(title: L10n.API.model, icon: "cpu")

                        TextField("Model ID", text: $settingsStore.selectedModel)
                            .textFieldStyle(.roundedBorder)

                        if !currentProvider.modelHint.isEmpty {
                            Text(L10n.API.commonModels(currentProvider.modelHint))
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

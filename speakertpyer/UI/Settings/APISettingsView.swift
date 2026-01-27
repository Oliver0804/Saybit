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

                // MARK: - API Key
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

    private func loadKeyForCurrentProvider() {
        if let key = KeychainHelper.loadAPIKey(for: currentProvider.id) {
            apiKey = key
            hasKey = true
        } else {
            apiKey = ""
            hasKey = false
        }
        showKey = false
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

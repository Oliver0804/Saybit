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

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // MARK: - API Key
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        GlassSectionHeader(title: "OpenRouter API", icon: "key.fill")

                        HStack(spacing: 8) {
                            Group {
                                if showKey {
                                    TextField("sk-or-v1-...", text: $apiKey)
                                } else {
                                    SecureField("sk-or-v1-...", text: $apiKey)
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
                                    try KeychainHelper.saveAPIKey(apiKey)
                                    hasKey = true
                                    showTemporaryStatus("已儲存")
                                } catch {
                                    showTemporaryStatus("儲存失敗")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button("清除") {
                                KeychainHelper.deleteAPIKey()
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

                        Text("常用: openai/gpt-4.1-mini · anthropic/claude-sonnet-4 · google/gemini-2.5-flash")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
        }
        .onAppear {
            if let key = KeychainHelper.loadAPIKey() {
                apiKey = key
                hasKey = true
            }
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
        Task {
            do {
                try await client.testConnection(model: settingsStore.selectedModel)
                await MainActor.run {
                    testResult = "✓ 連線成功 (\(settingsStore.selectedModel))"
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

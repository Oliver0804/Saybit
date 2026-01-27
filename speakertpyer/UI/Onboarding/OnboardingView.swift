//
//  OnboardingView.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import AppKit
import Speech
import SwiftUI

struct OnboardingView: View {
    @State private var currentStep = 0
    @State private var micGranted = false
    @State private var speechGranted = false
    @State private var accessibilityGranted = false
    @State private var apiKey = ""
    @State private var testResult: String?
    @State private var isTesting = false

    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("SpeakerTyper 設定引導")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Text("步驟 \(currentStep + 1) / 3")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()

            Divider()

            // Content
            Group {
                switch currentStep {
                case 0: permissionsStep
                case 1: apiKeyStep
                case 2: testStep
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()

            Divider()

            // Navigation
            HStack {
                if currentStep > 0 {
                    Button("上一步") {
                        currentStep -= 1
                    }
                }

                Spacer()

                if currentStep < 2 {
                    Button("下一步") {
                        currentStep += 1
                    }
                    .buttonStyle(.borderedProminent)
                    // Allow skipping permissions — user can set them later
                } else {
                    Button("開始使用") {
                        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .frame(width: 480, height: 360)
        .onAppear {
            checkPermissions()
        }
    }

    // MARK: - Step 1: Permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("權限設定")
                .font(.headline)

            Text("SpeakerTyper 需要以下權限才能正常運作。\n點擊「開啟設定」後，請在系統設定中允許 SpeakerTyper。")
                .foregroundColor(.secondary)

            VStack(spacing: 12) {
                permissionRow(
                    icon: "mic.fill",
                    title: "麥克風",
                    description: "用於錄製語音",
                    granted: micGranted
                ) {
                    // Try system API first, then open System Settings as fallback
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
                    title: "語音辨識",
                    description: "將語音轉換為文字",
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
                    title: "輔助使用",
                    description: "讀取選取文字、注入文字",
                    granted: accessibilityGranted
                ) {
                    AccessibilityManager.shared.promptIfNeeded()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        accessibilityGranted = AccessibilityManager.shared.isAuthorized
                    }
                }
            }

            Button("重新檢查權限") {
                checkPermissions()
            }
            .font(.caption)
            .foregroundColor(.accentColor)
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
                Button("開啟設定") { action() }
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
    }

    // MARK: - Step 2: API Key

    private var apiKeyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("設定 API Key")
                .font(.headline)

            Text("請輸入您的 OpenRouter API Key，用於 LLM 文字處理。")
                .foregroundColor(.secondary)

            SecureField("sk-or-...", text: $apiKey)
                .textFieldStyle(.roundedBorder)

            Button("儲存") {
                if !apiKey.isEmpty {
                    try? KeychainHelper.saveAPIKey(apiKey)
                }
            }
            .disabled(apiKey.isEmpty)

            if KeychainHelper.loadAPIKey() != nil {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("API Key 已儲存")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Link("取得 OpenRouter API Key →",
                 destination: URL(string: "https://openrouter.ai/keys")!)
                .font(.caption)
        }
    }

    // MARK: - Step 3: Test

    private var testStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("準備完成！")
                .font(.headline)

            Text("測試 API 連線是否正常，確認一切就緒。")
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                Button {
                    runAPITest()
                } label: {
                    if isTesting {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("測試中...")
                        }
                    } else {
                        Text("測試 API 連線")
                    }
                }
                .disabled(isTesting || KeychainHelper.loadAPIKey() == nil)

                if let result = testResult {
                    HStack(spacing: 4) {
                        Image(systemName: result.starts(with: "✓") ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(result.starts(with: "✓") ? .green : .red)
                        Text(result)
                            .font(.caption)
                            .foregroundColor(result.starts(with: "✓") ? .green : .red)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("使用方式")
                    .font(.subheadline)
                    .fontWeight(.medium)
                HStack {
                    Image(systemName: "keyboard")
                    Text("按住快捷鍵（預設 ⌥ Space）開始錄音")
                }
                HStack {
                    Image(systemName: "hand.raised")
                    Text("放開按鍵停止錄音，自動處理並輸入文字")
                }
                HStack {
                    Image(systemName: "text.cursor")
                    Text("可先選取文字，語音輸入會考慮上下文")
                }
                HStack {
                    Image(systemName: "command")
                    Text("支援聽寫、指令、編輯三種模式")
                }
            }
            .font(.callout)
            .foregroundColor(.secondary)
        }
    }

    private func runAPITest() {
        isTesting = true
        testResult = nil
        let client = OpenRouterClient()
        Task {
            do {
                try await client.testConnection(model: "openai/gpt-4.1-mini")
                await MainActor.run {
                    testResult = "✓ API 連線成功"
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = "✗ \(error.localizedDescription)"
                    isTesting = false
                }
            }
        }
    }

    // MARK: - Helpers

    private func checkPermissions() {
        micGranted = AVAudioApplication.shared.recordPermission == .granted
        speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
        accessibilityGranted = AccessibilityManager.shared.isAuthorized
    }
}

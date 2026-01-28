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
    @ObservedObject var settingsStore: SettingsStore
    @State private var currentStep = 0
    @State private var micGranted = false
    @State private var speechGranted = false
    @State private var accessibilityGranted = false
    @State private var apiKey = ""
    @State private var testResult: String?
    @State private var isTesting = false

    var onComplete: () -> Void
    var onStartTutorial: (() -> Void)?

    private let totalSteps = 4

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
                switch currentStep {
                case 0: languageStep
                case 1: permissionsStep
                case 2: apiKeyStep
                case 3: testStep
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()

            Divider()

            // Navigation
            HStack {
                if currentStep > 0 {
                    Button(L10n.Common.previous) {
                        withAnimation { currentStep -= 1 }
                    }
                }

                Spacer()

                if currentStep < totalSteps - 1 {
                    Button(L10n.Common.next) {
                        withAnimation { currentStep += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    HStack(spacing: 10) {
                        if onStartTutorial != nil {
                            Button(L10n.Onboarding.continueTutorial) {
                                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                                onStartTutorial?()
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        if onStartTutorial != nil {
                            Button(L10n.Common.startUsing) {
                                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                                onComplete()
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button(L10n.Common.startUsing) {
                                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                                onComplete()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .padding()
        }
        .frame(width: 520, height: 440)
        .onAppear {
            checkPermissions()
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

    // MARK: - Step 2: API Key

    private var apiKeyStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.Onboarding.apiKeyTitle)
                    .font(.headline)

                Text(L10n.Onboarding.apiKeyDesc)
                    .font(.callout)
                    .foregroundColor(.secondary)

                // Price comparison section
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.Onboarding.priceCompareTitle)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text(L10n.Onboarding.priceCompareDesc)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("• \(L10n.Onboarding.pricePerRequest)")
                        Text("• \(L10n.Onboarding.priceExample1)")
                        Text("• \(L10n.Onboarding.priceExample2)")
                        Text("• \(L10n.Onboarding.priceExample3)")
                    }
                    .font(.caption)
                    .foregroundColor(.primary.opacity(0.8))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.1)))

                Divider()

                // API Key input
                Text(L10n.Onboarding.apiKeyHint)
                    .font(.caption)
                    .foregroundColor(.secondary)

                SecureField("sk-or-... / sk-...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button(L10n.Common.save) {
                        if !apiKey.isEmpty {
                            try? KeychainHelper.saveAPIKey(apiKey)
                        }
                    }
                    .disabled(apiKey.isEmpty)

                    if KeychainHelper.loadAPIKey() != nil {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text(L10n.Onboarding.apiKeySaved)
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                }

                // Links to get API keys
                HStack(spacing: 16) {
                    Link(L10n.Onboarding.getOpenRouterKey,
                         destination: URL(string: "https://openrouter.ai/keys")!)
                        .font(.caption)

                    Link(L10n.Onboarding.getOpenAIKey,
                         destination: URL(string: "https://platform.openai.com/api-keys")!)
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - Step 3: Test

    private var testStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.Onboarding.readyTitle)
                .font(.headline)

            Text(L10n.Onboarding.readyDesc)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                Button {
                    runAPITest()
                } label: {
                    if isTesting {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(L10n.Onboarding.testing)
                        }
                    } else {
                        Text(L10n.Onboarding.testAPI)
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
        }
    }

    private func runAPITest() {
        isTesting = true
        testResult = nil
        let client = OpenRouterClient()
        Task {
            do {
                try await client.testConnection(model: "openai/gpt-4.1-nano", provider: .openRouter)
                await MainActor.run {
                    testResult = L10n.Onboarding.testSuccess
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

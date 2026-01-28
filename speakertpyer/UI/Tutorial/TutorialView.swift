//
//  TutorialView.swift
//  speakertpyer
//

import SwiftUI

struct TutorialView: View {
    @ObservedObject var settingsStore: SettingsStore
    @State private var currentPage = 0
    @State private var practiceText = ""
    @FocusState private var isTextFieldFocused: Bool
    var onDismiss: () -> Void

    // Pages: 0=Hotkey, 1=Features, 2-5=Practice 1-4
    private let totalPages = 6

    var body: some View {
        VStack(spacing: 0) {
            // Content
            TabView(selection: $currentPage) {
                hotkeyPage.tag(0)
                featuresPage.tag(1)
                practicePage(step: 1).tag(2)
                practicePage(step: 2).tag(3)
                practicePage(step: 3).tag(4)
                practicePage(step: 4).tag(5)
            }
            .tabViewStyle(.automatic)
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
                .font(.system(size: 72))
                .foregroundStyle(.blue.gradient)

            Text(L10n.Tutorial.hotkeyTitle)
                .font(.largeTitle)
                .fontWeight(.bold)

            Text(L10n.Tutorial.hotkeyDesc)
                .font(.title2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 60)

            // Current hotkey badge
            VStack(spacing: 8) {
                Text(L10n.Tutorial.currentHotkey)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(GlobalHotKeyManager.hotkeyDescription(
                    keyCode: UInt16(settingsStore.hotkeyKeyCode),
                    modifiers: CGEventFlags(rawValue: UInt64(settingsStore.hotkeyModifiers))
                ))
                .font(.system(.largeTitle, design: .rounded))
                .fontWeight(.bold)
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.accentColor.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1.5)
                )
            }

            // Trigger mode explanation
            VStack(spacing: 6) {
                Text(L10n.HotKey.triggerMode)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(L10n.hotkeyTriggerMode(settingsStore.hotkeyTriggerMode))
                    .font(.title3)
                    .fontWeight(.medium)
                Text(L10n.hotkeyTriggerModeDesc(settingsStore.hotkeyTriggerMode))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Spacer()
        }
        .padding()
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

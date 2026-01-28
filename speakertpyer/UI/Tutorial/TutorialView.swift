//
//  TutorialView.swift
//  speakertpyer
//

import SwiftUI

struct TutorialView: View {
    @ObservedObject var settingsStore: SettingsStore
    @State private var currentPage = 0
    var onDismiss: () -> Void

    private let totalPages = 5

    var body: some View {
        VStack(spacing: 0) {
            // Content
            TabView(selection: $currentPage) {
                hotkeyPage.tag(0)
                modesPage.tag(1)
                contextPage.tag(2)
                advancedPage.tag(3)
                quickRefPage.tag(4)
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
                }

                Spacer()

                // Page indicators
                HStack(spacing: 6) {
                    ForEach(0..<totalPages, id: \.self) { i in
                        Circle()
                            .fill(i == currentPage ? Color.accentColor : Color.primary.opacity(0.2))
                            .frame(width: 6, height: 6)
                    }
                }

                Spacer()

                if currentPage < totalPages - 1 {
                    HStack(spacing: 8) {
                        Button(L10n.Common.skip) {
                            onDismiss()
                        }
                        .foregroundStyle(.secondary)

                        Button(L10n.Common.next) {
                            withAnimation { currentPage += 1 }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    Button(L10n.Common.startUsing) {
                        onDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .frame(width: 560, height: 420)
    }

    // MARK: - Page 1: Hotkey

    private var hotkeyPage: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "keyboard.fill")
                .font(.system(size: 44))
                .foregroundStyle(.blue.gradient)

            Text(L10n.Tutorial.hotkeyTitle)
                .font(.title2)
                .fontWeight(.bold)

            Text(L10n.Tutorial.hotkeyDesc)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            // Current hotkey badge
            VStack(spacing: 6) {
                Text(L10n.Tutorial.currentHotkey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(GlobalHotKeyManager.hotkeyDescription(
                    keyCode: UInt16(settingsStore.hotkeyKeyCode),
                    modifiers: CGEventFlags(rawValue: UInt64(settingsStore.hotkeyModifiers))
                ))
                .font(.system(.title3, design: .rounded))
                .fontWeight(.semibold)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1)
                )
            }

            // Current trigger mode
            Text(settingsStore.hotkeyTriggerMode.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)

            Spacer()
        }
        .padding()
    }

    // MARK: - Page 2: Processing Modes

    private var modesPage: some View {
        VStack(spacing: 20) {
            Spacer()

            Text(L10n.Tutorial.modesTitle)
                .font(.title2)
                .fontWeight(.bold)

            Text(L10n.Tutorial.modesDesc)
                .font(.body)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                modeCard(
                    icon: "mic.fill",
                    name: L10n.Tutorial.dictationName,
                    desc: L10n.Tutorial.dictationDesc,
                    color: .blue
                )
                modeCard(
                    icon: "terminal.fill",
                    name: L10n.Tutorial.commandName,
                    desc: L10n.Tutorial.commandDesc,
                    color: .orange
                )
                modeCard(
                    icon: "pencil",
                    name: L10n.Tutorial.editName,
                    desc: L10n.Tutorial.editDesc,
                    color: .green
                )
            }
            .padding(.horizontal, 20)

            Spacer()
        }
        .padding()
    }

    private func modeCard(icon: String, name: String, desc: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(color)

            Text(name)
                .font(.subheadline)
                .fontWeight(.semibold)

            Text(desc)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    LinearGradient(
                        colors: [color.opacity(0.3), color.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
    }

    // MARK: - Page 3: Context & Preview

    private var contextPage: some View {
        VStack(spacing: 24) {
            Spacer()

            Text(L10n.Tutorial.contextTitle)
                .font(.title2)
                .fontWeight(.bold)

            VStack(alignment: .leading, spacing: 16) {
                featureRow(
                    icon: "text.cursor",
                    title: L10n.Tutorial.contextFeature,
                    desc: L10n.Tutorial.contextFeatureDesc,
                    color: .purple
                )
                featureRow(
                    icon: "eye.fill",
                    title: L10n.Tutorial.previewFeature,
                    desc: L10n.Tutorial.previewFeatureDesc,
                    color: .blue
                )
            }
            .padding(.horizontal, 30)

            // Visual flow
            HStack(spacing: 8) {
                flowStep(icon: "text.cursor", label: "Select")
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                flowStep(icon: "mic.fill", label: "Speak")
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                flowStep(icon: "eye", label: "Preview")
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                flowStep(icon: "text.badge.checkmark", label: "Inject")
            }
            .padding(.top, 8)

            Spacer()
        }
        .padding()
    }

    private func featureRow(icon: String, title: String, desc: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func flowStep(icon: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.accentColor)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(width: 50, height: 40)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.06))
        )
    }

    // MARK: - Page 4: Smart Send & Skills

    private var advancedPage: some View {
        VStack(spacing: 24) {
            Spacer()

            Text(L10n.Tutorial.advancedTitle)
                .font(.title2)
                .fontWeight(.bold)

            VStack(alignment: .leading, spacing: 16) {
                featureRow(
                    icon: "paperplane.fill",
                    title: L10n.Tutorial.smartSendFeature,
                    desc: L10n.Tutorial.smartSendDesc,
                    color: .cyan
                )
                featureRow(
                    icon: "sparkles",
                    title: L10n.Tutorial.voiceSkills,
                    desc: L10n.Tutorial.voiceSkillsDesc,
                    color: .orange
                )
            }
            .padding(.horizontal, 30)

            Spacer()
        }
        .padding()
    }

    // MARK: - Page 5: Quick Reference

    private var quickRefPage: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "list.bullet.clipboard.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green.gradient)

            Text(L10n.Tutorial.quickRefTitle)
                .font(.title2)
                .fontWeight(.bold)

            Text(L10n.Tutorial.quickRefDesc)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 10) {
                refRow(icon: "keyboard", text: L10n.Tutorial.tipHotkey)
                refRow(icon: "square.stack.3d.up", text: L10n.Tutorial.tipModes)
                refRow(icon: "text.cursor", text: L10n.Tutorial.tipContext)
                refRow(icon: "cursorarrow.click.2", text: L10n.Tutorial.tipOverlay)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.2), .white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
            .padding(.horizontal, 40)

            Spacer()
        }
        .padding()
    }

    private func refRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.accentColor)
                .frame(width: 20)
            Text(text)
                .font(.callout)
        }
    }
}

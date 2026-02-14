//
//  ContextRulesView.swift
//  speakertpyer
//
//  Created by Claude on 2026/2/14.
//

import SwiftUI

struct ContextRulesView: View {
    @ObservedObject var settingsStore: SettingsStore
    @State private var showAddSheet = false

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Text(L10n.General.contextRules)
                    .font(.headline)
                Spacer()
                Button {
                    showAddSheet = true
                } label: {
                    Label(L10n.General.contextRuleAddNew, systemImage: "plus.circle.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text(L10n.General.contextRulesDesc)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Rules list
            if settingsStore.contextRules.isEmpty {
                Text(L10n.Common.noResults)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(settingsStore.contextRules.enumerated()), id: \.element.id) { index, rule in
                        ContextRuleRow(
                            rule: Binding(
                                get: { settingsStore.contextRules[index] },
                                set: { settingsStore.contextRules[index] = $0 }
                            ),
                            onDelete: {
                                settingsStore.contextRules.remove(at: index)
                            }
                        )
                    }
                }
            }
        }
        .padding(20)
        .sheet(isPresented: $showAddSheet) {
            AddContextRuleSheet(settingsStore: settingsStore, isPresented: $showAddSheet)
        }
    }
}

// MARK: - Rule Row

struct ContextRuleRow: View {
    @Binding var rule: ContextRule
    var onDelete: () -> Void

    @State private var isExpanded = false

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    // App icon
                    Image(systemName: iconForApp(rule.appIdentifier))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)

                    Text(rule.appIdentifier)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)

                    Spacer()

                    // Tone badge
                    Text(ContextRule.toneDisplayName(rule.toneOverride))
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(toneColor(rule.toneOverride).opacity(0.15))
                        .foregroundStyle(toneColor(rule.toneOverride))
                        .clipShape(Capsule())

                    Toggle("", isOn: $rule.isEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                if isExpanded {
                    Divider().opacity(0.3)

                    // Tone picker
                    Picker(L10n.General.contextRuleTone, selection: Binding(
                        get: { rule.toneOverride ?? "auto" },
                        set: { rule.toneOverride = $0 == "auto" ? nil : $0 }
                    )) {
                        ForEach(ContextRule.availableTones, id: \.self) { tone in
                            Text(ContextRule.toneDisplayName(tone == "auto" ? nil : tone)).tag(tone)
                        }
                    }
                    .pickerStyle(.segmented)

                    // Additional prompt
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.General.contextRulePrompt)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField(
                            L10n.General.contextRulePromptPlaceholder,
                            text: Binding(
                                get: { rule.additionalPrompt ?? "" },
                                set: { rule.additionalPrompt = $0.isEmpty ? nil : $0 }
                            ),
                            axis: .vertical
                        )
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                    }

                    HStack {
                        Spacer()
                        Button(role: .destructive) {
                            onDelete()
                        } label: {
                            Label(L10n.Common.delete, systemImage: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .opacity(rule.isEnabled ? 1.0 : 0.6)
    }

    private func iconForApp(_ identifier: String) -> String {
        switch identifier {
        case "slack", "discord", "teams", "zoom": return "bubble.left.fill"
        case "line", "imessage", "telegram", "wechat", "messenger": return "message.fill"
        case "gmail", "outlook": return "envelope.fill"
        case "cursor", "vscode", "xcode", "intellij", "zed", "vim", "sublime": return "chevron.left.forwardslash.chevron.right"
        case "terminal", "iterm", "warp": return "terminal.fill"
        case "obsidian", "notes", "notion": return "note.text"
        case "figma", "sketch": return "paintbrush.fill"
        case "linear", "jira", "clickup", "asana": return "list.bullet.clipboard"
        case "safari", "chrome", "firefox", "arc": return "globe"
        default: return "app.fill"
        }
    }

    private func toneColor(_ tone: String?) -> Color {
        switch tone {
        case "casual": return .orange
        case "formal": return .blue
        case "technical": return .purple
        case "neutral": return .gray
        default: return .secondary
        }
    }
}

// MARK: - Add Rule Sheet

struct AddContextRuleSheet: View {
    @ObservedObject var settingsStore: SettingsStore
    @Binding var isPresented: Bool
    @State private var appIdentifier = ""
    @State private var selectedTone = "auto"

    var body: some View {
        VStack(spacing: 16) {
            Text(L10n.General.contextRuleAddNew)
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.General.contextRuleApp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("e.g. slack, gmail, vscode", text: $appIdentifier)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.General.contextRuleTone)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $selectedTone) {
                    ForEach(ContextRule.availableTones, id: \.self) { tone in
                        Text(ContextRule.toneDisplayName(tone == "auto" ? nil : tone)).tag(tone)
                    }
                }
                .pickerStyle(.segmented)
            }

            HStack {
                Button(L10n.Common.cancel) {
                    isPresented = false
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Spacer()

                Button(L10n.Common.add) {
                    let rule = ContextRule(
                        id: UUID(),
                        appIdentifier: appIdentifier.lowercased().trimmingCharacters(in: .whitespaces),
                        toneOverride: selectedTone == "auto" ? nil : selectedTone,
                        additionalPrompt: nil,
                        isEnabled: true
                    )
                    settingsStore.contextRules.append(rule)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(appIdentifier.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

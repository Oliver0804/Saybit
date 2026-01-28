//
//  MenuBarView.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status
            HStack {
                Image(systemName: "mic.fill")
                    .foregroundColor(.accentColor)
                Text("Saybit")
                    .font(.headline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Prompt Style
            Menu(L10n.Menu.promptLabel(settingsStore.promptStyle.displayName)) {
                ForEach(PromptStyle.allCases) { style in
                    Button(style.displayName) {
                        settingsStore.promptStyle = style
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            // Tone
            Menu(L10n.Menu.toneLabel(settingsStore.toneStyle.displayName)) {
                ForEach(ToneStyle.allCases) { tone in
                    Button(tone.displayName) {
                        settingsStore.toneStyle = tone
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            // Whisper Mode
            Button {
                settingsStore.enableWhisperMode.toggle()
            } label: {
                HStack {
                    Text("Whisper Mode")
                    Spacer()
                    if settingsStore.enableWhisperMode {
                        Image(systemName: "checkmark")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Divider()

            // Quick actions
            Button(L10n.Menu.reregisterHotkey(currentHotkeyLabel)) {
                GlobalHotKeyManager.shared.register(
                    keyCode: UInt16(settingsStore.hotkeyKeyCode),
                    modifiers: CGEventFlags(rawValue: UInt64(settingsStore.hotkeyModifiers))
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Divider()

            // API Key status
            HStack {
                Circle()
                    .fill(KeychainHelper.loadAPIKey() != nil ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(L10n.Menu.apiKeyStatus(KeychainHelper.loadAPIKey() != nil))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            // Accessibility status
            HStack {
                Circle()
                    .fill(AccessibilityManager.shared.isAuthorized ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(L10n.Menu.accessibilityStatus(AccessibilityManager.shared.isAuthorized))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Divider()

            // Settings
            SettingsLink {
                Text(L10n.Common.settings)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Divider()

            // Quit
            Button(L10n.Common.quit) {
                NSApplication.shared.terminate(nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .frame(width: 240)
    }

    private var currentHotkeyLabel: String {
        GlobalHotKeyManager.hotkeyDescription(
            keyCode: UInt16(settingsStore.hotkeyKeyCode),
            modifiers: CGEventFlags(rawValue: UInt64(settingsStore.hotkeyModifiers))
        )
    }
}

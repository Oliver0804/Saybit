//
//  MenuBarView.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//
//  選單列（MenuBarExtra .menu 樣式）：上面放最常用的動作，
//  只有出問題（缺權限、缺 API Key）時才顯示警示，平常保持精簡。
//

import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    let appDelegate: AppDelegate

    var body: some View {
        // 錄音
        Button(isRecording ? "停止錄音" : "開始錄音（\(currentHotkeyLabel)）") {
            appDelegate.voicePipeline?.toggleRecording()
        }
        .disabled(appDelegate.voicePipeline == nil)

        if !settingsStore.voiceModes.isEmpty {
            Menu("用語音模式錄音") {
                ForEach(settingsStore.voiceModes) { mode in
                    Button(modeLabel(mode)) {
                        appDelegate.voicePipeline?.toggleRecording(mode: mode)
                    }
                }
            }
        }

        Divider()

        // 處理方式
        Picker(L10n.Menu.promptLabel(settingsStore.promptStyle.displayName), selection: $settingsStore.promptStyle) {
            ForEach(PromptStyle.allCases) { style in
                Text(style.displayName).tag(style)
            }
        }
        Picker(L10n.Menu.toneLabel(settingsStore.toneStyle.displayName), selection: $settingsStore.toneStyle) {
            ForEach(ToneStyle.allCases) { tone in
                Text(tone.displayName).tag(tone)
            }
        }
        Toggle(L10n.General.smartSend, isOn: $settingsStore.enableSmartSend)
        Toggle(L10n.General.whisperMode, isOn: $settingsStore.enableWhisperMode)

        // 只在需要處理時才出現
        if !apiKeyReady || !AccessibilityManager.shared.isAuthorized {
            Divider()
            if !apiKeyReady {
                Button("⚠️ " + L10n.Menu.apiKeyStatus(false) + "…") {
                    OverlayWindowController.shared.openSettings(tab: .api)
                }
            }
            if !AccessibilityManager.shared.isAuthorized {
                Button("⚠️ " + L10n.Menu.accessibilityStatus(false) + "…") {
                    AccessibilityManager.shared.promptIfNeeded()
                }
            }
        }

        if !settingsStore.availableUpdateTag.isEmpty,
           let url = URL(string: settingsStore.availableUpdateURL),
           !settingsStore.availableUpdateURL.isEmpty {
            Divider()
            Link(L10n.Menu.updateAvailable(settingsStore.availableUpdateTag), destination: url)
        }

        Divider()

        Button("檔案轉錄…") {
            OverlayWindowController.shared.openSettings(tab: .transcribe)
        }
        Button("歷史紀錄…") {
            OverlayWindowController.shared.openSettings(tab: .history)
        }
        Button(L10n.Common.settings + "…") {
            OverlayWindowController.shared.openSettings()
        }
        .keyboardShortcut(",")

        Menu("疑難排解") {
            Button(L10n.Menu.reregisterHotkey(currentHotkeyLabel)) {
                GlobalHotKeyManager.shared.register(
                    keyCode: UInt16(settingsStore.hotkeyKeyCode),
                    modifiers: CGEventFlags(rawValue: UInt64(settingsStore.hotkeyModifiers))
                )
            }
            Button(L10n.Overlay.resetPosition) {
                OverlayWindowController.shared.resetPosition()
            }
            Button("日誌…") {
                OverlayWindowController.shared.openSettings(tab: .logs)
            }
        }

        Divider()

        Button(L10n.Common.quit) {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var isRecording: Bool {
        if case .recording = appDelegate.voicePipeline?.session.state { return true }
        return false
    }

    private func modeLabel(_ mode: VoiceMode) -> String {
        guard let code = mode.keyCode, mode.hasHotkey else { return mode.name }
        let hotkey = GlobalHotKeyManager.hotkeyDescription(keyCode: UInt16(code), modifiers: CGEventFlags(rawValue: mode.modifiers))
        return "\(mode.name)（\(hotkey)）"
    }

    private var currentHotkeyLabel: String {
        GlobalHotKeyManager.hotkeyDescription(
            keyCode: UInt16(settingsStore.hotkeyKeyCode),
            modifiers: CGEventFlags(rawValue: UInt64(settingsStore.hotkeyModifiers))
        )
    }

    private var apiKeyReady: Bool {
        let provider = settingsStore.selectedProvider
        if !provider.requiresAPIKey { return true }
        return KeychainHelper.loadAPIKey(for: provider.id)?.isEmpty == false
    }
}

//
//  HotKeySettingsView.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import AppKit
import CoreGraphics
import SwiftUI

struct HotKeySettingsView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var searchState: SettingsSearchState
    @State private var isRecording = false
    @State private var recordingTimeRemaining: Int = 0
    @State private var countdownTask: Task<Void, Never>?
    private let recordingTimeout = 10

    // 每張卡片的搜尋關鍵字（卡片顯示與「沒有結果」共用同一份）
    private enum Keys {
        static let hotkey = ["快捷鍵", "hotkey", "shortcut", "快捷键", "鍵盤", "keyboard", "錄製", "record"]
        static let trigger = ["觸發", "trigger", "模式", "mode", "toggle", "hold", "按住", "雙擊", "double tap", "快捷键"]
        static let voiceModes = ["語音模式", "模式", "mode", "email", "翻譯", "快捷鍵", "url", "raycast", "捷徑"]
        static let guide = ["說明", "guide", "usage", "使用", "步驟", "step", "教學"]
        static let all = [hotkey, trigger, voiceModes, guide]
    }

    private func shows(_ keys: [String]) -> Bool {
        settingsMatchesSearch(keys, searchText: searchState.searchText)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // MARK: - 快捷鍵
                if shows(Keys.hotkey) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            GlassSectionHeader(title: L10n.HotKey.hotkey, icon: "command")

                            HStack(spacing: 12) {
                                Text(L10n.HotKey.currentHotkey)
                                    .foregroundStyle(.secondary)

                                Text(currentHotkeyLabel)
                                    .font(.system(.body, design: .rounded))
                                    .fontWeight(.semibold)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(isRecording ? Color.orange.opacity(0.15) : Color.primary.opacity(0.06))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .strokeBorder(
                                                isRecording ? Color.orange.opacity(0.6) : Color.clear,
                                                lineWidth: 1
                                            )
                                    )

                                Spacer()

                                if isRecording {
                                    Text("\(recordingTimeRemaining)s")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                        .monospacedDigit()

                                    Button(L10n.Common.cancel) {
                                        cancelRecording()
                                    }
                                    .controlSize(.small)
                                    .buttonStyle(.bordered)
                                } else {
                                    Button(L10n.HotKey.recordNew) {
                                        startRecording()
                                    }
                                    .controlSize(.small)
                                    .buttonStyle(.bordered)
                                }
                            }

                            Text(isRecording
                                ? L10n.HotKey.recordingHint
                                : L10n.HotKey.requirement)
                                .font(.callout)
                                .foregroundStyle(isRecording ? .orange : .secondary)

                            if !isRecording, let conflict = currentConflict {
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                    Text(L10n.HotKey.conflictWarning(conflict.name))
                                        .font(.callout)
                                        .foregroundStyle(.orange)
                                }
                                .padding(.top, 2)
                            }
                        }
                    }
                }

                // MARK: - 觸發模式
                if shows(Keys.trigger) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            GlassSectionHeader(title: L10n.HotKey.triggerMode, icon: "hand.tap")

                            Picker("", selection: $settingsStore.hotkeyTriggerMode) {
                                ForEach(HotkeyTriggerMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.radioGroup)
                            .onChange(of: settingsStore.hotkeyTriggerMode) { _, _ in
                                if let appDelegate = NSApp.delegate as? AppDelegate {
                                    appDelegate.setupHotKey()
                                }
                            }

                            Text(settingsStore.hotkeyTriggerMode.description)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                        }
                    }
                }

                // MARK: - 語音模式
                if shows(Keys.voiceModes) {
                    VoiceModesSection()
                }

                // MARK: - 使用說明
                if shows(Keys.guide) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            GlassSectionHeader(title: L10n.HotKey.usageGuide, icon: "questionmark.circle")

                            switch settingsStore.hotkeyTriggerMode {
                            case .toggle:
                                VStack(alignment: .leading, spacing: 8) {
                                    StepRow(step: 1, text: L10n.HotKey.toggleStep1)
                                    StepRow(step: 2, text: L10n.HotKey.toggleStep2)
                                    StepRow(step: 3, text: L10n.HotKey.toggleStep3)
                                    StepRow(step: 4, text: L10n.HotKey.toggleStep4)
                                }
                            case .hold:
                                VStack(alignment: .leading, spacing: 8) {
                                    StepRow(step: 1, text: L10n.HotKey.holdStep1)
                                    StepRow(step: 2, text: L10n.HotKey.holdStep2)
                                    StepRow(step: 3, text: L10n.HotKey.holdStep3)
                                }
                            case .doubleTap:
                                VStack(alignment: .leading, spacing: 8) {
                                    StepRow(step: 1, text: L10n.HotKey.doubleTapStep1)
                                    StepRow(step: 2, text: L10n.HotKey.doubleTapStep2)
                                    StepRow(step: 3, text: L10n.HotKey.doubleTapStep3)
                                    StepRow(step: 4, text: L10n.HotKey.doubleTapStep4)
                                }
                            }
                        }
                    }
                }

                if !searchState.searchText.isEmpty && !Keys.all.contains(where: shows) {
                    SettingsNoResults()
                }
            }
            .padding(20)
        }
    }

    private var currentHotkeyLabel: String {
        if isRecording {
            return L10n.HotKey.recording
        }
        return GlobalHotKeyManager.hotkeyDescription(
            keyCode: UInt16(settingsStore.hotkeyKeyCode),
            modifiers: CGEventFlags(rawValue: UInt64(settingsStore.hotkeyModifiers))
        )
    }

    private var currentConflict: HotKeyConflictChecker.KnownShortcut? {
        HotKeyConflictChecker.conflict(
            keyCode: UInt16(settingsStore.hotkeyKeyCode),
            modifiers: CGEventFlags(rawValue: UInt64(settingsStore.hotkeyModifiers))
        )
    }

    private func startRecording() {
        isRecording = true
        recordingTimeRemaining = recordingTimeout

        GlobalHotKeyManager.shared.startRecording { keyCode, modifiers in
            settingsStore.hotkeyKeyCode = Int(keyCode)
            settingsStore.hotkeyModifiers = Int(modifiers.rawValue)
            isRecording = false
            GlobalHotKeyManager.shared.register(
                keyCode: keyCode,
                modifiers: modifiers
            )
        }
        startCountdown()
    }

    private func startCountdown() {
        // 用可取消的 Task 取代遞迴 asyncAfter，避免 view 重建時舊 closure 滯留產生多條並行倒數
        countdownTask?.cancel()
        countdownTask = Task { @MainActor in
            while recordingTimeRemaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled || !isRecording { return }
                recordingTimeRemaining -= 1
            }
            if isRecording { cancelRecording() }
        }
    }

    private func cancelRecording() {
        countdownTask?.cancel()
        countdownTask = nil
        GlobalHotKeyManager.shared.cancelRecording()
        isRecording = false
        recordingTimeRemaining = 0
    }
}

// MARK: - Step Row

private struct StepRow: View {
    let step: Int
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Text("\(step)")
                .font(.body)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor.opacity(0.7)))

            Text(text)
                .font(.callout)
        }
    }
}

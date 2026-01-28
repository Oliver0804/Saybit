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
    @State private var isRecording = false
    @State private var recordingTimeRemaining: Int = 0
    private let recordingTimeout = 10

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // MARK: - 快捷鍵
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
                            .font(.caption)
                            .foregroundStyle(isRecording ? .orange : .secondary)
                    }
                }

                // MARK: - 觸發模式
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
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                }

                // MARK: - 使用說明
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard isRecording else { return }
            recordingTimeRemaining -= 1
            if recordingTimeRemaining <= 0 {
                cancelRecording()
            } else {
                startCountdown()
            }
        }
    }

    private func cancelRecording() {
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
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor.opacity(0.7)))

            Text(text)
                .font(.body)
        }
    }
}

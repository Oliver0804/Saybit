//
//  VoiceModesSection.swift
//  speakertpyer
//
//  語音模式設定：每個模式一段指令 + 一組快捷鍵（按一下開始、再按一下停止）。
//

#if os(macOS)
import AppKit
import SwiftUI

struct VoiceModesSection: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @State private var recordingModeID: UUID?
    @State private var recordingRemaining = 0
    @State private var recordingTask: Task<Void, Never>?
    /// 剛才錄到的組合和主快捷鍵相同的模式（在該列顯示提示）
    @State private var conflictModeID: UUID?
    @State private var expandedModeID: UUID?
    @State private var modePendingDelete: VoiceMode?

    private static let recordingTimeout = 10

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    GlassSectionHeader(title: L10n.VoiceModes.title, icon: "square.stack.3d.up")
                    Spacer()
                    Button {
                        let mode = VoiceMode(name: L10n.VoiceModes.newModeName, instructions: "")
                        settingsStore.voiceModes.append(mode)
                        expandedModeID = mode.id
                    } label: {
                        Label(L10n.VoiceModes.addMode, systemImage: "plus")
                    }
                    .controlSize(.small)
                }

                SettingDescription(L10n.VoiceModes.desc)

                ForEach($settingsStore.voiceModes) { $mode in
                    modeRow($mode)
                }

                Divider().opacity(0.3)

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.VoiceModes.externalTrigger).font(.headline)
                    Text(L10n.VoiceModes.urlHelp)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                SettingToggle(title: L10n.VoiceModes.urlControlToggle, description: L10n.VoiceModes.urlControlDesc,
                              isOn: $settingsStore.enableURLSchemeControl)

                if settingsStore.enableURLSchemeControl {
                    SettingIndent {
                        HStack {
                            Text(L10n.VoiceModes.allowedSenders).font(.headline)
                            Spacer()
                            Button(L10n.VoiceModes.resetSenders) {
                                settingsStore.urlSchemeAllowedSenders = SettingsStore.defaultURLSchemeAllowedSenders
                            }
                            .controlSize(.small)
                            .disabled(settingsStore.urlSchemeAllowedSenders == SettingsStore.defaultURLSchemeAllowedSenders)
                        }
                        if settingsStore.urlSchemeAllowedSenders.isEmpty {
                            SettingDescription(L10n.VoiceModes.allowedSendersEmpty)
                        } else {
                            ForEach(settingsStore.urlSchemeAllowedSenders, id: \.self) { bundleID in
                                HStack(spacing: 8) {
                                    Text(senderDisplayName(bundleID))
                                    Text(bundleID)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                    Spacer()
                                    Button {
                                        settingsStore.urlSchemeAllowedSenders.removeAll { $0 == bundleID }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.borderless)
                                    .help(L10n.VoiceModes.removeSender)
                                    .accessibilityLabel(L10n.VoiceModes.removeSender)
                                }
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            L10n.VoiceModes.deleteConfirm(modePendingDelete?.name ?? ""),
            isPresented: Binding(get: { modePendingDelete != nil }, set: { if !$0 { modePendingDelete = nil } })
        ) {
            Button(L10n.Common.delete, role: .destructive) {
                if let id = modePendingDelete?.id {
                    settingsStore.voiceModes.removeAll { $0.id == id }
                }
                modePendingDelete = nil
            }
        } message: {
            Text(L10n.VoiceModes.deleteMessage)
        }
        .onDisappear {
            // 離開頁面時一定要結束錄製，否則 event tap 會持續吞掉全系統按鍵
            if recordingModeID != nil {
                GlobalHotKeyManager.shared.cancelRecording()
            }
            recordingTask?.cancel()
            recordingTask = nil
            recordingModeID = nil
        }
    }

    /// 已允許來源的顯示名稱：裝了的 App 用其名稱，否則顯示 bundle ID 最後一段
    private func senderDisplayName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            // Finder 顯示的名稱（已去掉 .app、含在地化），比 CFBundleName 可靠
            return FileManager.default.displayName(atPath: url.path)
        }
        return Self.knownSenderNames[bundleID] ?? bundleID
    }

    private static let knownSenderNames: [String: String] = [
        "com.apple.shortcuts": "捷徑",
        "com.raycast.macos": "Raycast",
        "com.runningwithcrayons.Alfred": "Alfred",
        "com.elgato.StreamDeck": "Stream Deck",
    ]


    @ViewBuilder
    private func modeRow(_ mode: Binding<VoiceMode>) -> some View {
        let m = mode.wrappedValue
        let isExpanded = expandedModeID == m.id
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    expandedModeID = isExpanded ? nil : m.id
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .frame(width: 14)
                }
                .buttonStyle(.borderless)
                .help(L10n.General.expand)
                .accessibilityLabel(L10n.General.expand)

                TextField(L10n.VoiceModes.namePlaceholder, text: mode.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)

                Spacer()

                hotkeyButton(m)

                if m.hasHotkey {
                    Button {
                        mode.wrappedValue.keyCode = nil
                        mode.wrappedValue.modifiers = 0
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.VoiceModes.clearHotkey)
                    .accessibilityLabel(L10n.VoiceModes.clearHotkey)
                }

                Button(role: .destructive) {
                    // 還沒寫指令的空模式直接刪；有內容的先確認
                    if m.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        settingsStore.voiceModes.removeAll { $0.id == m.id }
                    } else {
                        modePendingDelete = m
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(L10n.VoiceModes.deleteMode)
                .accessibilityLabel(L10n.VoiceModes.deleteMode)
            }

            if conflictModeID == m.id {
                Label(L10n.VoiceModes.conflictsWithMain, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            if isExpanded {
                Text(L10n.VoiceModes.instructions).font(.headline)
                TextEditor(text: mode.instructions)
                    .font(.body)
                    .frame(minHeight: 70)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                Text(L10n.VoiceModes.instructionsExample)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
    }

    private func hotkeyButton(_ m: VoiceMode) -> some View {
        let isRecording = recordingModeID == m.id
        let label: String = {
            if isRecording { return L10n.VoiceModes.pressHotkey(recordingRemaining) }
            guard let code = m.keyCode, m.hasHotkey else { return L10n.VoiceModes.setHotkey }
            return GlobalHotKeyManager.hotkeyDescription(keyCode: UInt16(code), modifiers: CGEventFlags(rawValue: m.modifiers))
        }()
        return Button(label) {
            if isRecording {
                stopHotkeyRecording()
            } else {
                beginHotkeyRecording(for: m.id)
            }
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .tint(isRecording ? .orange : nil)
        .help(isRecording ? L10n.VoiceModes.cancelRecordingHelp : L10n.VoiceModes.setHotkey)
    }

    // MARK: - Hotkey recording

    private func beginHotkeyRecording(for id: UUID) {
        if recordingModeID != nil { GlobalHotKeyManager.shared.cancelRecording() }
        recordingTask?.cancel()
        conflictModeID = nil
        recordingModeID = id
        recordingRemaining = Self.recordingTimeout

        // 只記住 id，不捕捉 Binding：回呼時列表可能已增刪重排
        GlobalHotKeyManager.shared.startRecording { keyCode, modifiers in
            if recordingModeID == id { endHotkeyRecordingUI() }
            applyHotkey(keyCode: keyCode, modifiers: modifiers, to: id)
        }

        recordingTask = Task { @MainActor in
            while recordingRemaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled || recordingModeID != id { return }
                // Esc 在 manager 內取消錄製時不會通知 UI，從旗標判斷
                if !GlobalHotKeyManager.shared.isRecordingNewHotkey {
                    endHotkeyRecordingUI()
                    return
                }
                recordingRemaining -= 1
            }
            if recordingModeID == id { stopHotkeyRecording() }
        }
    }

    /// 使用者取消或逾時：通知 manager 停止攔截按鍵
    private func stopHotkeyRecording() {
        GlobalHotKeyManager.shared.cancelRecording()
        endHotkeyRecordingUI()
    }

    private func endHotkeyRecordingUI() {
        recordingTask?.cancel()
        recordingTask = nil
        recordingModeID = nil
        recordingRemaining = 0
    }

    private func applyHotkey(keyCode: UInt16, modifiers: CGEventFlags, to id: UUID) {
        let mainCode = settingsStore.hotkeyKeyCode
        let mainMods = UInt64(settingsStore.hotkeyModifiers)
        if Int(keyCode) == mainCode && modifiers.rawValue == mainMods {
            AppLogger.shared.error("語音模式快捷鍵不能和主快捷鍵相同", category: "HotKey")
            conflictModeID = id
            return
        }
        guard settingsStore.voiceModes.contains(where: { $0.id == id }) else { return }
        // 同一組快捷鍵只能給一個模式
        for i in settingsStore.voiceModes.indices where settingsStore.voiceModes[i].id != id
            && settingsStore.voiceModes[i].keyCode == Int(keyCode)
            && settingsStore.voiceModes[i].modifiers == modifiers.rawValue {
            settingsStore.voiceModes[i].keyCode = nil
            settingsStore.voiceModes[i].modifiers = 0
        }
        guard let index = settingsStore.voiceModes.firstIndex(where: { $0.id == id }) else { return }
        settingsStore.voiceModes[index].keyCode = Int(keyCode)
        settingsStore.voiceModes[index].modifiers = modifiers.rawValue
    }
}
#endif

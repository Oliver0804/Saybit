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
    @State private var expandedModeID: UUID?
    @State private var modePendingDelete: VoiceMode?

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    GlassSectionHeader(title: "語音模式", icon: "square.stack.3d.up")
                    Spacer()
                    Button {
                        let mode = VoiceMode(name: "新模式", instructions: "")
                        settingsStore.voiceModes.append(mode)
                        expandedModeID = mode.id
                    } label: {
                        Label("新增模式", systemImage: "plus")
                    }
                    .controlSize(.small)
                }

                Text("每個模式有自己的指令和快捷鍵。用模式快捷鍵錄音時，AI 直接照該模式的指令處理（例如寫成 email、翻譯成英文），不必每次口頭交代。")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ForEach($settingsStore.voiceModes) { $mode in
                    modeRow($mode)
                }

                Divider().opacity(0.3)

                VStack(alignment: .leading, spacing: 4) {
                    Text("從其他 App 觸發（Raycast、捷徑、Stream Deck）").font(.headline)
                    Text("saybit://toggle　開始 / 停止錄音\nsaybit://start、saybit://stop、saybit://cancel\nsaybit://toggle?mode=Email　用指定模式錄音\nsaybit://settings?tab=dictionary　打開設定的指定分頁")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .confirmationDialog(
            "刪除語音模式「\(modePendingDelete?.name ?? "")」？",
            isPresented: Binding(get: { modePendingDelete != nil }, set: { if !$0 { modePendingDelete = nil } })
        ) {
            Button("刪除", role: .destructive) {
                if let id = modePendingDelete?.id {
                    settingsStore.voiceModes.removeAll { $0.id == id }
                }
                modePendingDelete = nil
            }
        } message: {
            Text("模式的指令和快捷鍵會一起移除。")
        }
    }

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

                TextField("模式名稱", text: mode.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)

                Spacer()

                hotkeyButton(mode)

                if m.hasHotkey {
                    Button {
                        mode.wrappedValue.keyCode = nil
                        mode.wrappedValue.modifiers = 0
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("清除快捷鍵")
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
                .help("刪除模式")
            }

            if isExpanded {
                Text("指令").font(.headline)
                TextEditor(text: mode.instructions)
                    .font(.body)
                    .frame(minHeight: 70)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                Text("例：「把內容寫成給客戶的正式回覆，結尾加上『敬祝 商祺』」。有選取文字時，指令會套用在選取的文字上。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
    }

    private func hotkeyButton(_ mode: Binding<VoiceMode>) -> some View {
        let m = mode.wrappedValue
        let isRecording = recordingModeID == m.id
        let label: String = {
            if isRecording { return "按下快捷鍵…" }
            guard let code = m.keyCode, m.hasHotkey else { return "設定快捷鍵" }
            return GlobalHotKeyManager.hotkeyDescription(keyCode: UInt16(code), modifiers: CGEventFlags(rawValue: m.modifiers))
        }()
        return Button(label) {
            if isRecording {
                GlobalHotKeyManager.shared.cancelRecording()
                recordingModeID = nil
                return
            }
            recordingModeID = m.id
            GlobalHotKeyManager.shared.startRecording { keyCode, modifiers in
                recordingModeID = nil
                let mainCode = settingsStore.hotkeyKeyCode
                let mainMods = UInt64(settingsStore.hotkeyModifiers)
                if Int(keyCode) == mainCode && modifiers.rawValue == mainMods {
                    AppLogger.shared.error("語音模式快捷鍵不能和主快捷鍵相同", category: "HotKey")
                    return
                }
                // 同一組快捷鍵只能給一個模式
                for i in settingsStore.voiceModes.indices where settingsStore.voiceModes[i].id != m.id
                    && settingsStore.voiceModes[i].keyCode == Int(keyCode)
                    && settingsStore.voiceModes[i].modifiers == modifiers.rawValue {
                    settingsStore.voiceModes[i].keyCode = nil
                    settingsStore.voiceModes[i].modifiers = 0
                }
                mode.wrappedValue.keyCode = Int(keyCode)
                mode.wrappedValue.modifiers = modifiers.rawValue
            }
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .tint(isRecording ? .orange : nil)
    }
}
#endif

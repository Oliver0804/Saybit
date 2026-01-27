//
//  OverlayView.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import CoreGraphics
import Speech
import SwiftUI

/// The always-visible floating bubble with expandable transcript and config panel
struct BubbleView: View {
    let session: TranscriptionSession
    @ObservedObject var settingsStore: SettingsStore

    @State private var showConfig = false
    @State private var pulseScale: CGFloat = 1.0

    // Config editing state
    @State private var apiKey = ""
    @State private var hasKey = false
    @State private var editingKey = false
    @State private var saveStatus = ""
    @State private var audioDevices: [AudioInputDevice] = []
    @State private var isRecordingHotkey = false
    @State private var liveModifiers: CGEventFlags = []
    @State private var showLogs = false
    @State private var editingModel = false

    var body: some View {
        VStack(spacing: 8) {
            if showConfig && !isActive {
                configPanel
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                Spacer()
                if isActive {
                    transcriptPanel
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }

            // Bubble circle
            bubbleCircle
                .onTapGesture {
                    if !isActive {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            showConfig.toggle()
                        }
                        if showConfig {
                            refreshConfig()
                        }
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isActive)
        .onChange(of: session.state) { _, newState in
            if newState == .recording {
                showConfig = false
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulseScale = 1.4
                }
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    pulseScale = 1.0
                }
            }
        }
    }

    // MARK: - Config Panel

    private var configPanel: some View {
        ScrollView {
            VStack(spacing: 10) {
                // Header
                HStack {
                    Text("SpeakerTyper")
                        .font(.system(.headline, design: .rounded))
                    Text("v\(appVersion)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            showConfig = false
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)

                // API Key
                glassSection("API", icon: "key.fill") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(hasKey ? Color.green : Color.red)
                            .frame(width: 8, height: 8)

                        if editingKey {
                            SecureField("sk-or-...", text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))

                            Button("儲存") {
                                do {
                                    try KeychainHelper.saveAPIKey(apiKey)
                                    hasKey = true
                                    editingKey = false
                                    saveStatus = "已儲存"
                                } catch {
                                    saveStatus = "失敗"
                                }
                            }
                            .font(.caption)
                        } else {
                            Text(hasKey ? maskedKey : "未設定")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(hasKey ? .primary : .red)

                            Spacer()

                            Button(hasKey ? "編輯" : "設定") {
                                editingKey = true
                            }
                            .font(.caption)
                        }
                    }

                    if !saveStatus.isEmpty {
                        Text(saveStatus)
                            .font(.caption2)
                            .foregroundColor(.green)
                    }

                    HStack(spacing: 4) {
                        Text("模型:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if editingModel {
                            TextField("model-id", text: $settingsStore.selectedModel)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                                .onSubmit { editingModel = false }
                        } else {
                            Text(settingsStore.selectedModel)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                            Button("更改") { editingModel = true }
                                .font(.caption2)
                        }
                    }
                }

                // Permissions
                glassSection("權限", icon: "lock.shield") {
                    permissionRow("麥克風", authorized: AudioSessionManager.isMicrophoneAuthorized)
                    permissionRow("語音辨識", authorized: SFSpeechRecognizer.authorizationStatus() == .authorized)
                    permissionRow("輔助使用", authorized: AccessibilityManager.shared.isAuthorized)
                }

                // Feature Toggles
                glassSection("功能", icon: "switch.2") {
                    Toggle("Whisper Mode", isOn: $settingsStore.enableWhisperMode)
                        .font(.caption)
                    Text("過濾背景噪音和非語音內容")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Divider().opacity(0.3)

                    Toggle("Context Awareness", isOn: $settingsStore.enableContextAwareness)
                        .font(.caption)
                    Text("讀取選取文字作為上下文")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Divider().opacity(0.3)

                    Toggle("音效回饋", isOn: $settingsStore.enableSoundFeedback)
                        .font(.caption)
                }

                // Auto-Stop Settings
                glassSection("靜音自動停止", icon: "waveform.slash") {
                    Toggle("啟用自動停止", isOn: $settingsStore.enableAutoStop)
                        .font(.caption)

                    if settingsStore.enableAutoStop {
                        HStack {
                            Text("延遲")
                                .font(.caption)
                            Slider(value: $settingsStore.silenceTimeout, in: 0.5...5.0, step: 0.5)
                            Text(String(format: "%.1fs", settingsStore.silenceTimeout))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 32, alignment: .trailing)
                        }
                        Text("說完話後靜音等待此時間即自動停止")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                // Hotkey & Trigger Mode
                glassSection("快捷鍵", icon: "command") {
                    HStack(spacing: 8) {
                        Text(currentHotkeyLabel)
                            .font(.system(.caption, design: .rounded))
                            .fontWeight(.medium)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isRecordingHotkey ? Color.orange.opacity(0.2) : Color.primary.opacity(0.06))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(isRecordingHotkey ? Color.orange.opacity(0.6) : Color.clear, lineWidth: 1)
                            )

                        if isRecordingHotkey {
                            Button("取消") {
                                GlobalHotKeyManager.shared.cancelRecording()
                                isRecordingHotkey = false
                                liveModifiers = []
                            }
                            .font(.caption)
                        } else {
                            Button("錄製") {
                                liveModifiers = []
                                isRecordingHotkey = true
                                GlobalHotKeyManager.shared.onRecordingModifiersChanged = { mods in
                                    liveModifiers = mods
                                }
                                GlobalHotKeyManager.shared.startRecording { keyCode, modifiers in
                                    settingsStore.hotkeyKeyCode = Int(keyCode)
                                    settingsStore.hotkeyModifiers = Int(modifiers.rawValue)
                                    isRecordingHotkey = false
                                    liveModifiers = []
                                    GlobalHotKeyManager.shared.onRecordingModifiersChanged = nil
                                    GlobalHotKeyManager.shared.register(
                                        keyCode: keyCode,
                                        modifiers: modifiers
                                    )
                                }
                            }
                            .font(.caption)
                        }
                    }

                    if isRecordingHotkey {
                        Text("按住修飾鍵 (⌘⌃⌥⇧) 再按一個按鍵，Esc 取消")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }

                    Divider().opacity(0.3)

                    HStack {
                        Text("觸發模式")
                            .font(.caption)
                        Spacer()
                        Picker("", selection: $settingsStore.hotkeyTriggerMode) {
                            ForEach(HotkeyTriggerMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 160)
                        .onChange(of: settingsStore.hotkeyTriggerMode) { _, _ in
                            if let appDelegate = NSApp.delegate as? AppDelegate {
                                appDelegate.setupHotKey()
                            }
                        }
                    }
                    Text(settingsStore.hotkeyTriggerMode == .toggle ? "按一下開始，說完自動停止" : "按住說話，放開停止")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // Microphone Input & Sensitivity
                glassSection("麥克風", icon: "mic.fill") {
                    if audioDevices.isEmpty {
                        Text("無可用裝置")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Picker("", selection: $settingsStore.selectedInputDeviceUID) {
                            Text("系統預設").tag("")
                            ForEach(audioDevices) { device in
                                Text(device.name).tag(device.uid)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .font(.caption)
                    }

                    Divider().opacity(0.3)

                    HStack {
                        Text("靈敏度")
                            .font(.caption)
                        Slider(value: $settingsStore.micSensitivity, in: 0.5...5.0, step: 0.5)
                        Text(String(format: "%.1fx", settingsStore.micSensitivity))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 32, alignment: .trailing)
                    }
                    Text("調高可讓音量表更靈敏，建議錄音時觀察音量條調整")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // Logs
                glassSection("日誌", icon: "doc.text") {
                    Button {
                        withAnimation { showLogs.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showLogs ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                            Text("最近 20 條（共 \(AppLogger.shared.entries.count) 條）")
                                .font(.caption)
                            Spacer()
                            if showLogs {
                                Button("清除") {
                                    AppLogger.shared.clear()
                                }
                                .font(.caption2)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    if showLogs {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(AppLogger.shared.entries.suffix(20).reversed()) { entry in
                                HStack(alignment: .top, spacing: 4) {
                                    Circle()
                                        .fill(entry.level == "ERROR" ? Color.red : entry.level == "DEBUG" ? Color.gray : Color.blue)
                                        .frame(width: 5, height: 5)
                                        .padding(.top, 4)
                                    Text(entry.formatted)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundColor(entry.level == "ERROR" ? .red : .secondary)
                                        .lineLimit(3)
                                }
                            }
                        }
                        .frame(maxHeight: 200)
                    }
                }

                // Open full settings
                Button {
                    showConfig = false
                    DispatchQueue.main.async {
                        NSApp.setActivationPolicy(.regular)
                        NSApp.activate(ignoringOtherApps: true)
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                } label: {
                    HStack {
                        Spacer()
                        Label("完整設定", systemImage: "gear")
                            .font(.caption)
                        Spacer()
                    }
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.3), .white.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
    }

    // MARK: - Transcript Panel

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                if isRecording {
                    // Audio level meter bars
                    audioLevelMeter
                }
            }

            if !displayText.isEmpty {
                Text(displayText)
                    .font(.system(.body, design: .rounded))
                    .foregroundColor(isProcessed ? .primary : .secondary)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isRecording ? Color.red.opacity(0.3) : Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - Bubble Circle

    private var bubbleCircle: some View {
        ZStack {
            if isRecording {
                Circle()
                    .fill(Color.red.opacity(0.2))
                    .frame(width: 60, height: 60)
                    .scaleEffect(pulseScale)
            }

            Circle()
                .fill(bubbleColor)
                .frame(width: 48, height: 48)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)

            Image(systemName: showConfig && !isActive ? "xmark" : bubbleIcon)
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.white)
        }
        .frame(width: 72, height: 72)
    }

    // MARK: - Config Helpers

    private var currentHotkeyLabel: String {
        if isRecordingHotkey {
            if liveModifiers.isEmpty {
                return "按下快捷鍵..."
            }
            // Show currently held modifiers in real-time
            return GlobalHotKeyManager.hotkeyDescription(keyCode: nil, modifiers: liveModifiers) + " ..."
        }
        return GlobalHotKeyManager.hotkeyDescription(
            keyCode: UInt16(settingsStore.hotkeyKeyCode),
            modifiers: CGEventFlags(rawValue: UInt64(settingsStore.hotkeyModifiers))
        )
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version)(\(build))"
    }

    private func refreshConfig() {
        if let key = KeychainHelper.loadAPIKey() {
            apiKey = key
            hasKey = true
        } else {
            apiKey = ""
            hasKey = false
        }
        editingKey = false
        saveStatus = ""
        audioDevices = AudioSessionManager.listInputDevices()
    }

    private var audioLevelMeter: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(session.audioLevel > Float(i) * 0.2 ? Color.red : Color.red.opacity(0.2))
                    .frame(width: 3, height: CGFloat(6 + i * 2))
            }
        }
        .frame(height: 16)
    }

    private var maskedKey: String {
        guard apiKey.count > 8 else { return String(repeating: "\u{2022}", count: apiKey.count) }
        let prefix = apiKey.prefix(6)
        let suffix = apiKey.suffix(3)
        return "\(prefix)\u{2022}\u{2022}\u{2022}\(suffix)"
    }

    private func glassSection<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.25), .white.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
        .padding(.horizontal, 8)
    }

    private func permissionRow(_ label: String, authorized: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: authorized ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(authorized ? .green : .red)
                .font(.caption)
            Text(label)
                .font(.caption)
            Spacer()
            Text(authorized ? "已授權" : "未授權")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - State

    private var isRecording: Bool {
        session.state == .recording
    }

    private var isActive: Bool {
        switch session.state {
        case .idle: return false
        default: return true
        }
    }

    private var isProcessed: Bool {
        switch session.state {
        case .done: return true
        case .processing: return !session.processedText.isEmpty
        default: return false
        }
    }

    private var statusColor: Color {
        switch session.state {
        case .idle: return .gray
        case .recording: return .red
        case .processing: return .orange
        case .done: return .green
        case .error: return .red
        }
    }

    private var statusLabel: String {
        switch session.state {
        case .idle: return "準備就緒"
        case .recording: return "正在聆聽..."
        case .processing: return "AI 處理中..."
        case .done: return "已輸入"
        case .error(let msg): return "錯誤: \(msg)"
        }
    }

    private var displayText: String {
        switch session.state {
        case .recording:
            return session.rawTranscript
        case .processing, .done:
            return session.processedText.isEmpty ? session.rawTranscript : session.processedText
        case .error:
            return session.rawTranscript
        default:
            return ""
        }
    }

    private var bubbleColor: Color {
        switch session.state {
        case .idle: return showConfig ? Color.accentColor : Color.gray.opacity(0.85)
        case .recording: return .red
        case .processing: return .orange
        case .done: return .green
        case .error: return .red.opacity(0.7)
        }
    }

    private var bubbleIcon: String {
        switch session.state {
        case .idle: return "mic.fill"
        case .recording: return "waveform"
        case .processing: return "ellipsis"
        case .done: return "checkmark"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}

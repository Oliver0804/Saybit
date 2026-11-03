//
//  DictationView.swift
//  SaybitiOS
//
//  主畫面：狀態標籤 + 大麥克風按鈕、即時轉錄、AI 結果與操作、鍵盤待命狀態。
//

import SwiftUI

struct DictationView: View {
    @Environment(MobileVoicePipeline.self) private var pipeline
    @State private var copied = false
    @State private var errorCopied = false

    private var session: TranscriptionSession { pipeline.session }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                KeyboardSessionCard()

                if pipeline.source == .keyboard, pipeline.isBusy {
                    returnToAppBanner
                }

                ScrollView {
                    contentArea
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .frame(maxHeight: .infinity)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))

                if case .done = session.state {
                    resultActions
                } else if case .previewing = session.state, session.pendingAction != nil {
                    actionConfirmButtons
                }

                micArea
            }
            .padding()
            .navigationTitle("Saybit")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    StyleMenu()
                }
            }
        }
    }

    // MARK: - 狀態

    private struct StatusInfo {
        let text: String
        let icon: String
        let tint: Color
    }

    private var status: StatusInfo {
        switch session.state {
        case .idle, .listening:
            StatusInfo(text: "待命", icon: "mic", tint: .secondary)
        case .recording:
            StatusInfo(text: "錄音中", icon: "waveform", tint: .red)
        case .processing:
            StatusInfo(text: "AI 處理中", icon: "sparkles", tint: .accentColor)
        case .done, .confirming:
            StatusInfo(text: "完成", icon: "checkmark.circle.fill", tint: .green)
        case .previewing:
            StatusInfo(text: "等你確認", icon: "questionmark.circle.fill", tint: .accentColor)
        case .error:
            StatusInfo(text: "發生問題", icon: "exclamationmark.triangle.fill", tint: .orange)
        }
    }

    private var statusBadge: some View {
        let s = status
        return Label(s.text, systemImage: s.icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(s.tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(s.tint.opacity(0.12), in: Capsule())
            .accessibilityLabel("狀態：\(s.text)")
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        switch session.state {
        case .idle, .listening:
            VStack(alignment: .leading, spacing: 12) {
                Text("點下方麥克風開始說話")
                    .font(.title3.weight(.semibold))
                Text("說完會自動停止，AI 會去除贅字、加上標點，並依你的設定調整語氣。也可以直接說指令，例如「幫我寫一封請假信」、「明天下午三點提醒我開會」。")
                    .foregroundStyle(.secondary)
            }
        case .recording:
            VStack(alignment: .leading, spacing: 8) {
                Label("聆聽中…", systemImage: "waveform")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(session.rawTranscript.isEmpty ? "請開始說話" : session.rawTranscript)
                    .font(.title3)
                    .foregroundStyle(session.rawTranscript.isEmpty ? .secondary : .primary)
            }
        case .processing:
            VStack(alignment: .leading, spacing: 8) {
                Label("AI 整理中…", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(.tint)
                if !session.processedText.isEmpty {
                    Text(session.processedText).font(.title3)
                } else {
                    Text(session.rawTranscript).foregroundStyle(.secondary)
                }
            }
        case .done, .confirming:
            VStack(alignment: .leading, spacing: 12) {
                Text(session.processedText)
                    .font(.title3)
                    .textSelection(.enabled)
                if !session.rawTranscript.isEmpty, session.rawTranscript != session.processedText {
                    DisclosureGroup("原始轉錄") {
                        Text(session.rawTranscript)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.subheadline)
                }
                if session.totalTokens > 0 {
                    Text("\(session.modelName) · \(session.totalTokens) tokens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .previewing:
            VStack(alignment: .leading, spacing: 8) {
                Label("確認建立", systemImage: "calendar.badge.plus")
                    .font(.headline)
                Text(session.processedText).font(.title3)
            }
        case .error(let message):
            errorCard(message)
        }
    }

    /// 錯誤完整顯示（不截斷），並提供重試與複製訊息
    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("這次沒有成功", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !session.rawTranscript.isEmpty {
                DisclosureGroup("已辨識的內容") {
                    Text(session.rawTranscript)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.subheadline)
            }
            HStack(spacing: 12) {
                if session.lastErrorContext != nil {
                    Button("重試", systemImage: "arrow.clockwise") { pipeline.retryLastAction() }
                        .buttonStyle(.borderedProminent)
                }
                Button(errorCopied ? "已複製" : "複製訊息",
                       systemImage: errorCopied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = message
                    errorCopied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        errorCopied = false
                    }
                }
                .buttonStyle(.bordered)
            }
            .frame(minHeight: 44)
        }
    }

    private var returnToAppBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("說完後可直接回到剛剛的 App")
                    .font(.subheadline.weight(.semibold))
                Text("點左上角「◀︎ 返回」或在底部橫條向右滑，結果會由 Saybit 鍵盤自動輸入。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Actions

    private var resultActions: some View {
        HStack(spacing: 12) {
            Button {
                UIPasteboard.general.string = session.processedText
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Label(copied ? "已複製" : "複製", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)

            ShareLink(item: session.processedText) {
                Label("分享", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.bordered)

            Menu {
                Button("重新生成", systemImage: "arrow.triangle.2.circlepath") { pipeline.regenerate() }
                Button("清除結果", systemImage: "xmark", role: .destructive) { pipeline.dismissResult() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("更多動作")
        }
        .controlSize(.large)
    }

    private var actionConfirmButtons: some View {
        HStack(spacing: 12) {
            Button("取消", role: .cancel) { pipeline.dismissResult() }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            Button("建立") { pipeline.confirmPendingAction() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
    }

    private var micArea: some View {
        VStack(spacing: 10) {
            statusBadge
            HStack {
                Spacer()
                cancelButton
                Spacer()
                MicButton(
                    state: session.state,
                    level: session.audioLevel,
                    action: { pipeline.toggleRecording() }
                )
                Spacer()
                // 右側佔位，讓麥克風保持在正中央
                Color.clear.frame(width: 56, height: 56)
                Spacer()
            }
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var cancelButton: some View {
        if pipeline.isBusy {
            Button {
                pipeline.cancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .frame(width: 56, height: 56)
                    .background(.thinMaterial, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("取消這次錄音")
        } else {
            Color.clear.frame(width: 56, height: 56)
        }
    }
}

// MARK: - Mic Button

struct MicButton: View {
    let state: TranscriptionSession.State
    let level: Float
    let action: () -> Void

    /// 隨 Dynamic Type 放大，但有上限，避免擠掉其他內容
    @ScaledMetric(relativeTo: .largeTitle) private var diameter: CGFloat = 84

    private var isRecording: Bool { state == .recording }
    private var isProcessing: Bool { state == .processing }

    private var clampedDiameter: CGFloat { min(max(diameter, 84), 120) }

    private var hint: String {
        if isProcessing { return "處理中…" }
        return isRecording ? "再按一下結束" : "按一下開始說話"
    }

    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(isRecording ? Color.red.opacity(0.18) : Color.accentColor.opacity(0.12))
                        .frame(width: clampedDiameter * 1.34, height: clampedDiameter * 1.34)
                        .scaleEffect(isRecording ? 1 + CGFloat(min(level, 1)) * 0.35 : 1)
                        .animation(.easeOut(duration: 0.1), value: level)
                    Circle()
                        .fill(isRecording ? Color.red : Color.accentColor)
                        .frame(width: clampedDiameter, height: clampedDiameter)
                        .shadow(color: (isRecording ? Color.red : Color.accentColor).opacity(0.35), radius: 12, y: 4)
                    if isProcessing {
                        ProgressView().tint(.white).controlSize(.large)
                    } else {
                        Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: clampedDiameter * 0.4, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isProcessing)
            .accessibilityLabel(isRecording ? "停止錄音" : "開始錄音")
            .accessibilityHint(isProcessing ? "AI 正在處理，請稍候" : "")
            .sensoryFeedback(.impact, trigger: isRecording)

            Text(hint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Keyboard Session Card

struct KeyboardSessionCard: View {
    @Environment(MobileVoicePipeline.self) private var pipeline
    @EnvironmentObject private var mobileSettings: MobileSettings

    var body: some View {
        let ks = pipeline.keyboardSession
        HStack(spacing: 12) {
            Image(systemName: ks.isActive ? "keyboard.badge.waveform.fill" : "keyboard")
                .font(.title2)
                .foregroundStyle(ks.isActive ? Color.green : Color.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(ks.isActive ? "鍵盤待命中" : "鍵盤待命已關閉")
                    .font(.subheadline.weight(.semibold))
                Text(ks.isActive
                     ? "剩 \(Self.format(ks.remaining))，在任何 App 的 Saybit 鍵盤都能直接說話"
                     : "開啟後，Saybit 鍵盤不必跳回 App 就能錄音")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(ks.isActive ? "停止" : "啟動") {
                if ks.isActive {
                    ks.deactivate()
                } else {
                    ks.activate(minutes: mobileSettings.keyboardSessionMinutes)
                }
            }
            .buttonStyle(.bordered)
            .tint(ks.isActive ? .red : .accentColor)
            .frame(minHeight: 44)
            .accessibilityLabel(ks.isActive ? "停止鍵盤待命" : "啟動鍵盤待命")
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Style Menu

struct StyleMenu: View {
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        Menu {
            Picker("處理風格", selection: $settingsStore.promptStyle) {
                ForEach(PromptStyle.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("語氣", selection: $settingsStore.toneStyle) {
                ForEach(ToneStyle.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("輸出語言", selection: $settingsStore.languagePreference) {
                ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .accessibilityLabel("處理風格與語氣")
    }
}

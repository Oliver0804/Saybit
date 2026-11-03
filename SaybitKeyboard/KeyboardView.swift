//
//  KeyboardView.swift
//  SaybitKeyboard
//

import SwiftUI
import UIKit

struct KeyboardView: View {
    @Bindable var model: KeyboardModel
    let needsGlobe: Bool
    let globeAction: (UIView, UIEvent) -> Void

    var body: some View {
        VStack(spacing: 10) {
            statusBar
            micRow
            bottomRow
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Status

    private var statusBar: some View {
        HStack(spacing: 8) {
            switch model.phase {
            case .ready where model.pendingResult != nil:
                Button { model.insertPendingResult() } label: {
                    Label("插入剛才的結果", systemImage: "text.insert")
                        .font(.footnote)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                Spacer(minLength: 0)
                Button { model.dismissPendingResult() } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("忽略剛才的結果")
            case .ready:
                Image(systemName: model.sessionAlive ? "dot.radiowaves.left.and.right" : "mic")
                    .foregroundStyle(model.sessionAlive ? .green : .secondary)
                Text(model.sessionAlive ? "待命中，按麥克風直接說話" : "按麥克風開始說話")
                    .foregroundStyle(.secondary)
            case .launching:
                ProgressView().controlSize(.small)
                Text("啟動 Saybit…").foregroundStyle(.secondary)
            case .recording:
                Image(systemName: "waveform").foregroundStyle(.red)
                Text(model.partialText.isEmpty ? "聆聽中…" : model.partialText)
                    .lineLimit(2)
                    .truncationMode(.head)
            case .processing:
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text("AI 整理中…").foregroundStyle(.secondary)
            case .inserted:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("已輸入").foregroundStyle(.secondary)
                Spacer()
                Button { model.undoInsert() } label: {
                    Label("復原", systemImage: "arrow.uturn.backward")
                        .font(.footnote)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            case .message(let text):
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                // 錯誤 / 提示通常是一整句操作指示，必須完整看得懂，不能壓成一行
                Text(text)
                    .font(.footnote)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Button { model.dismissMessage() } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("關閉提示")
            }
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .frame(minHeight: 44)
        .padding(.horizontal, 6)
    }

    // MARK: - Mic

    private var isRecording: Bool { model.phase == .recording }
    private var isBusy: Bool { model.phase == .processing || model.phase == .launching }

    private var micAccessibilityLabel: String {
        switch model.phase {
        case .recording: "停止並輸入"
        case .launching: "正在啟動 Saybit"
        case .processing: "AI 整理中"
        default: "開始語音輸入"
        }
    }

    private var micRow: some View {
        HStack {
            KeyButton(width: 64) {
                model.insertCharacter("，")
            } label: { Text("，") }
            KeyButton(width: 64) {
                model.insertCharacter("。")
            } label: { Text("。") }

            Spacer()

            Button(action: model.micTapped) {
                ZStack {
                    Circle()
                        .fill(isRecording ? Color.red.opacity(0.2) : Color.accentColor.opacity(0.15))
                        .frame(width: 96, height: 96)
                        .scaleEffect(isRecording ? 1 + CGFloat(min(model.level, 1)) * 0.3 : 1)
                        .animation(.easeOut(duration: 0.15), value: model.level)
                    Circle()
                        .fill(isRecording ? Color.red : Color.accentColor)
                        .frame(width: 72, height: 72)
                    if isBusy {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(micAccessibilityLabel)

            Spacer()

            KeyButton(width: 64) {
                model.insertCharacter("？")
            } label: { Text("？") }
            if isRecording || isBusy {
                KeyButton(width: 64) {
                    model.cancelTapped()
                } label: { Image(systemName: "xmark") }
            } else {
                KeyButton(width: 64) {
                    model.insertCharacter("！")
                } label: { Text("！") }
            }
        }
        .frame(height: 104)
    }

    // MARK: - Bottom Row

    private var bottomRow: some View {
        HStack(spacing: 6) {
            if needsGlobe {
                GlobeKey(action: globeAction)
                    .frame(width: 44, height: 44)
                    .background(Color(.systemGray4), in: RoundedRectangle(cornerRadius: 8))
            }
            KeyButton {
                model.insertCharacter(" ")
            } label: { Text("空白").foregroundStyle(.primary) }
            .frame(maxWidth: .infinity)
            RepeatingKey(action: model.deleteBackward) {
                Image(systemName: "delete.left")
            }
            .frame(width: 56)
            KeyButton(width: 76, prominent: true) {
                model.returnKey()
            } label: { Text(model.returnKeyTitle) }
        }
        .frame(height: 44)
    }
}

// MARK: - Keys

struct KeyButton<Label: View>: View {
    var width: CGFloat? = nil
    var prominent = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .font(.title3)
                .frame(maxWidth: width ?? .infinity, minHeight: 44)
                .frame(width: width)
                .background(
                    prominent ? Color.accentColor : Color(.systemGray4),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .foregroundStyle(prominent ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

/// 長按會連續觸發（刪除鍵）
struct RepeatingKey<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        label()
            .font(.title3)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Color(.systemGray4), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.4, maximumDistance: 40) {
                // 長按成立後由 pressing 迴圈處理
            } onPressingChanged: { pressing in
                if pressing {
                    action()
                    repeatTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        while !Task.isCancelled {
                            action()
                            try? await Task.sleep(for: .milliseconds(80))
                        }
                    }
                } else {
                    repeatTask?.cancel()
                    repeatTask = nil
                }
            }
            .accessibilityLabel("刪除")
            .accessibilityAddTraits(.isButton)
    }
}

/// 系統規定的切換鍵盤鍵：必須把 UIView 和 UIEvent 交給 handleInputModeList(from:with:)
struct GlobeKey: UIViewRepresentable {
    let action: (UIView, UIEvent) -> Void

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "globe"), for: .normal)
        button.tintColor = .label
        button.addTarget(context.coordinator, action: #selector(Coordinator.handle(_:event:)), for: .allTouchEvents)
        button.accessibilityLabel = "切換鍵盤"
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: (UIView, UIEvent) -> Void
        init(action: @escaping (UIView, UIEvent) -> Void) { self.action = action }
        @objc func handle(_ sender: UIButton, event: UIEvent) { action(sender, event) }
    }
}

//
//  OverlayView.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import Combine
import SwiftUI

// MARK: - Waveform View

struct WaveformView: View {
    let audioLevel: Float

    @State private var levels: [CGFloat] = Array(repeating: 0, count: 20)

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<levels.count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 2, height: max(2, levels[i] * 20))
            }
        }
        .onChange(of: audioLevel) { _, newLevel in
            withAnimation(.linear(duration: 0.08)) {
                levels.removeFirst()
                levels.append(CGFloat(newLevel))
            }
        }
    }
}

// MARK: - Capsule Bar View

struct CapsuleBarView: View {
    let session: TranscriptionSession
    @ObservedObject var settingsStore: SettingsStore

    // Preview action closures
    var onConfirmInject: (() -> Void)?
    var onRegenerate: (() -> Void)?
    var onCancelPreview: (() -> Void)?
    var onRetry: (() -> Void)?

    @State private var capsuleWidth: CGFloat = 120
    @State private var capsuleHeight: CGFloat = 36
    @State private var pulseScale: CGFloat = 1.0
    @State private var breatheOpacity: Double = 1.0

    private var scale: CGFloat { settingsStore.capsuleScale }

    private var isPreviewing: Bool {
        if case .previewing = session.state { return true }
        return false
    }

    var body: some View {
        Group {
            if isPreviewing {
                previewLayout
                    .scaleEffect(scale)
                    .frame(minWidth: capsuleWidth * scale, minHeight: capsuleHeight * scale)
                    .fixedSize()
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(.ultraThinMaterial)
                            .environment(\.colorScheme, .dark)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(innerGlowColor, lineWidth: 6)
                            .blur(radius: 8)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(borderGradient, lineWidth: 1.5)
                    )
                    .shadow(color: .blue.opacity(0.3), radius: 14, y: 3)
            } else {
                defaultLayout
                    .scaleEffect(scale)
                    .frame(minWidth: capsuleWidth * scale, minHeight: capsuleHeight * scale)
                    .fixedSize()
                    .background(
                        Capsule()
                            .fill(.ultraThinMaterial)
                            .environment(\.colorScheme, .dark)
                    )
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(innerGlowColor, lineWidth: 6)
                            .blur(radius: 8)
                            .clipShape(Capsule())
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(borderGradient, lineWidth: 1.5)
                    )
                    .shadow(color: outerGlowColor, radius: outerGlowRadius, y: 3)
            }
        }
        .fixedSize()
        // 保留空間給 .shadow 渲染，避免被 hostingView frame 裁切（scale 2x + radius 14 約需 30）
        .padding(30)
        .animation(.easeInOut(duration: 0.2), value: settingsStore.capsuleScale)
        .onChange(of: session.state) { oldState, newState in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                updateDimensions(for: newState)
            }
            handleAnimations(from: oldState, to: newState)
        }
    }

    // MARK: - Layouts

    private var defaultLayout: some View {
        HStack(spacing: 8) {
            stateIcon
            stateContent
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var previewLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "eye.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.blue)
                Text(session.processedText.isEmpty ? session.rawTranscript : session.processedText)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .truncationMode(.tail)
            }

            Divider().opacity(0.2)

            HStack(spacing: 10) {
                Spacer()
                Button {
                    onConfirmInject?()
                } label: {
                    Label(L10n.Overlay.inject, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .controlSize(.small)

                Button {
                    onRegenerate?()
                } label: {
                    Label(L10n.Overlay.regenerate, systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .controlSize(.small)

                Button {
                    onCancelPreview?()
                } label: {
                    Label(L10n.Common.cancel, systemImage: "xmark.circle")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .tint(.gray)
                .controlSize(.small)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - State Icon

    @ViewBuilder
    private var stateIcon: some View {
        switch session.state {
        case .idle:
            Image(systemName: "mic.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
        case .listening:
            Image(systemName: "mic.badge.xmark")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.orange)
                .scaleEffect(pulseScale)
        case .recording:
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .scaleEffect(pulseScale)
        case .processing:
            ProgressView()
                .scaleEffect(0.55)
                .tint(.white)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.green)
        case .previewing:
            EmptyView()
        case .confirming(let remaining):
            Text("\(remaining)")
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .foregroundStyle(.cyan)
                .opacity(breatheOpacity)
                .scaleEffect(pulseScale)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
        }
    }

    // MARK: - State Content

    @ViewBuilder
    private var stateContent: some View {
        switch session.state {
        case .idle:
            Text("Saybit")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
        case .listening:
            HStack(spacing: 6) {
                WaveformView(audioLevel: session.audioLevel)
                    .frame(width: 40, height: 16)
                    .clipped()
                Text(L10n.Overlay.listening)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.orange.opacity(0.8))
            }
        case .recording:
            HStack(spacing: 6) {
                WaveformView(audioLevel: session.audioLevel)
                    .frame(width: 80, height: 20)
                Text(formattedDuration)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                if !session.rawTranscript.isEmpty {
                    Text("\(session.rawTranscript.count) \(L10n.Overlay.chars)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        case .processing:
            HStack(spacing: 4) {
                Text(L10n.Overlay.processing)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                TypingDotsView()
            }
        case .done:
            if session.smartSendCancelled {
                Text(L10n.Overlay.cancelled)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.orange)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.processedText.isEmpty ? session.rawTranscript : session.processedText)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    if session.totalTokens > 0 {
                        Text("\(session.totalTokens) tokens")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }
            }
        case .previewing:
            EmptyView()
        case .confirming:
            Text(session.processedText.isEmpty ? session.rawTranscript : session.processedText)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.white.opacity(breatheOpacity * 0.7 + 0.3))
                .lineLimit(2)
                .truncationMode(.tail)
        case .error(let msg):
            HStack(spacing: 6) {
                Text(msg)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.red.opacity(0.9))
                    .lineLimit(1)
                if session.lastErrorContext != nil {
                    Button {
                        onRetry?()
                    } label: {
                        Label(L10n.Overlay.retry, systemImage: "arrow.clockwise")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .controlSize(.mini)
                }
            }
        }
    }

    // MARK: - Background & Border

    private var borderGradient: LinearGradient {
        let colors: [Color] = {
            switch session.state {
            case .idle:
                return [.white.opacity(0.2), .white.opacity(0.05)]
            case .listening:
                return [.orange.opacity(0.5), .orange.opacity(0.15)]
            case .recording:
                return [.red.opacity(0.6), .red.opacity(0.2)]
            case .processing:
                return [.orange.opacity(0.5), .orange.opacity(0.15)]
            case .done:
                return [.green.opacity(0.5), .green.opacity(0.1)]
            case .previewing:
                return [.blue.opacity(0.5), .blue.opacity(0.15)]
            case .confirming:
                return [.cyan.opacity(0.6), .blue.opacity(0.2)]
            case .error:
                return [.red.opacity(0.5), .red.opacity(0.1)]
            }
        }()
        return LinearGradient(
            colors: colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Inner Glow

    private var innerGlowColor: Color {
        switch session.state {
        case .listening:
            return .orange.opacity(0.6)
        case .recording:
            return .red.opacity(0.5)
        case .confirming:
            return .cyan.opacity(0.6 * breatheOpacity)
        case .previewing:
            return .blue.opacity(0.5)
        default:
            return .clear
        }
    }

    // MARK: - Outer Glow

    private var outerGlowColor: Color {
        switch session.state {
        case .listening:
            return .orange.opacity(0.4)
        case .recording:
            return .red.opacity(0.35)
        case .confirming:
            return .cyan.opacity(0.4 * breatheOpacity)
        case .previewing:
            return .blue.opacity(0.3)
        default:
            return .black.opacity(0.3)
        }
    }

    private var outerGlowRadius: CGFloat {
        switch session.state {
        case .listening, .recording, .confirming, .previewing:
            return 14
        default:
            return 10
        }
    }

    // MARK: - Dimensions

    private func updateDimensions(for state: TranscriptionSession.State) {
        switch state {
        case .idle:
            capsuleWidth = 120
            capsuleHeight = 36
        case .listening:
            capsuleWidth = 200
            capsuleHeight = 36
        case .recording:
            capsuleWidth = session.rawTranscript.isEmpty ? 200 : 240
            capsuleHeight = 36
        case .processing:
            capsuleWidth = 160
            capsuleHeight = 36
        case .done:
            if session.smartSendCancelled {
                capsuleWidth = 160
                capsuleHeight = 36
            } else {
                let text = session.processedText.isEmpty ? session.rawTranscript : session.processedText
                let charWidth: CGFloat = text.unicodeScalars.allSatisfy({ $0.isASCII }) ? 7 : 13
                let estimatedWidth = min(400, max(160, CGFloat(text.count) * charWidth + 60))
                capsuleWidth = estimatedWidth
                let hasTokens = session.totalTokens > 0
                capsuleHeight = text.count > 25 ? (hasTokens ? 68 : 56) : (hasTokens ? 50 : 36)
            }
        case .previewing:
            capsuleWidth = 340
            capsuleHeight = 80
        case .confirming:
            let text = session.processedText.isEmpty ? session.rawTranscript : session.processedText
            let charWidth: CGFloat = text.unicodeScalars.allSatisfy({ $0.isASCII }) ? 7 : 13
            let estimatedWidth = min(400, max(180, CGFloat(text.count) * charWidth + 80))
            capsuleWidth = estimatedWidth
            capsuleHeight = text.count > 25 ? 56 : 36
        case .error:
            capsuleWidth = session.lastErrorContext != nil ? 320 : 260
            capsuleHeight = 36
        }
    }

    // MARK: - Animations

    private func handleAnimations(from oldState: TranscriptionSession.State, to newState: TranscriptionSession.State) {
        switch newState {
        case .listening:
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulseScale = 1.3
            }
            withAnimation(.easeInOut(duration: 0.2)) {
                breatheOpacity = 1.0
            }
        case .recording:
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                pulseScale = 1.4
            }
            withAnimation(.easeInOut(duration: 0.2)) {
                breatheOpacity = 1.0
            }
        case .confirming:
            // Only start breathing animation on first entry, not on remaining count changes
            if case .confirming = oldState { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulseScale = 1.3
                breatheOpacity = 0.4
            }
        default:
            withAnimation(.easeInOut(duration: 0.2)) {
                pulseScale = 1.0
                breatheOpacity = 1.0
            }
        }
    }

    // MARK: - Helpers

    private var formattedDuration: String {
        let duration = session.duration
        let seconds = Int(duration) % 60
        let minutes = Int(duration) / 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Typing Dots Animation

struct TypingDotsView: View {
    @State private var dotCount = 0

    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(String(repeating: ".", count: dotCount + 1))
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.5))
            .frame(width: 20, alignment: .leading)
            .onReceive(timer) { _ in
                dotCount = (dotCount + 1) % 3
            }
    }
}

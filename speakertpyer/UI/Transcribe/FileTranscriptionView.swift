//
//  FileTranscriptionView.swift
//  speakertpyer
//
//  檔案轉錄：拖入音檔 / 影片 → SenseVoice 本機轉逐字稿（附時間戳）→ 可複製、存檔、交給 AI 整理成筆記。
//

#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileTranscriptionView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @State private var models = SherpaModelManager.shared

    @State private var fileURL: URL?
    @State private var segments: [SherpaFileTranscriber.Segment] = []
    @State private var progress: Double = 0
    @State private var isTranscribing = false
    @State private var errorMessage: String?
    @State private var elapsed: TimeInterval = 0
    @State private var showTimestamps = true
    @State private var isDropTargeted = false
    @State private var job: Task<Void, Never>?

    @State private var notes = ""
    @State private var isSummarizing = false

    private static let types: [UTType] = [.audio, .movie, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .aiff, .mpeg4Audio]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !models.isInstalled {
                    GlassCard {
                        Label("檔案轉錄使用 SenseVoice 離線模型，請先到「一般 › 語音辨識引擎」選 SenseVoice 並下載模型。",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                dropZone
                if isTranscribing || !segments.isEmpty || errorMessage != nil {
                    transcriptCard
                }
                if !notes.isEmpty || isSummarizing {
                    notesCard
                }
            }
            .padding(20)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("檔案轉錄").font(.title.bold())
            Text("把會議錄音、語音備忘錄、影片拖進來，在這台 Mac 上轉成逐字稿，不上傳音訊。")
                .foregroundStyle(.secondary)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 36))
                .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
            if let fileURL {
                Text(fileURL.lastPathComponent).font(.headline)
            } else {
                Text("拖入音檔或影片").font(.headline)
            }
            Text("m4a · mp3 · wav · aiff · mov · mp4").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("選擇檔案…") { chooseFile() }
                if isTranscribing {
                    Button("停止", role: .cancel) { job?.cancel() }
                }
            }
            .disabled(!models.isInstalled)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard models.isInstalled, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in start(url) } }
            }
            return true
        }
    }

    private var transcriptCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    GlassSectionHeader(title: "逐字稿", icon: "text.alignleft")
                    Spacer()
                    Toggle("時間戳", isOn: $showTimestamps).toggleStyle(.checkbox)
                }
                if isTranscribing {
                    ProgressView(value: progress) {
                        Text("轉錄中 \(Int(progress * 100))%（已 \(Int(elapsed)) 秒）").font(.caption)
                    }
                } else if let errorMessage {
                    Label(errorMessage, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                } else if !segments.isEmpty {
                    Text("完成：\(segments.count) 段，花費 \(String(format: "%.1f", elapsed)) 秒")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Text(plainText(timestamps: showTimestamps))
                    .textSelection(.enabled)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !isTranscribing, !segments.isEmpty {
                    HStack {
                        Button("複製") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(plainText(timestamps: showTimestamps), forType: .string)
                        }
                        Button("存成文字檔…") { save(plainText(timestamps: showTimestamps), suffix: "逐字稿") }
                        Spacer()
                        Button {
                            summarize()
                        } label: {
                            Label("AI 整理成筆記", systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSummarizing)
                    }
                }
            }
        }
    }

    private var notesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                GlassSectionHeader(title: "AI 筆記", icon: "sparkles")
                if isSummarizing && notes.isEmpty {
                    ProgressView().controlSize(.small)
                }
                Text(notes)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !isSummarizing, !notes.isEmpty {
                    HStack {
                        Button("複製") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(notes, forType: .string)
                        }
                        Button("存成 Markdown…") { save(notes, suffix: "筆記", ext: "md") }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.types
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { start(url) }
    }

    private func start(_ url: URL) {
        job?.cancel()
        fileURL = url
        segments = []
        notes = ""
        errorMessage = nil
        progress = 0
        elapsed = 0
        isTranscribing = true
        let paths = SherpaFileTranscriber.ModelPaths(model: models.modelPath, tokens: models.tokensPath, vad: models.vadPath)
        let toTraditional = settingsStore.languagePreference == AppLanguage.zhTW.rawValue
        let began = Date()
        AppLogger.shared.info("檔案轉錄開始: \(url.lastPathComponent)", category: "STT")

        job = Task {
            let ticker = Task { @MainActor in
                while !Task.isCancelled {
                    elapsed = Date().timeIntervalSince(began)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { ticker.cancel() }
            do {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let result = try await Task.detached(priority: .userInitiated) {
                    try await SherpaFileTranscriber.transcribe(
                        url: url, paths: paths, toTraditional: toTraditional,
                        onSegment: { seg in Task { @MainActor in segments.append(seg) } },
                        onProgress: { p in Task { @MainActor in progress = p } }
                    )
                }.value
                segments = result
                elapsed = Date().timeIntervalSince(began)
                AppLogger.shared.info("檔案轉錄完成: \(result.count) 段, \(String(format: "%.1f", elapsed))s", category: "STT")
            } catch is CancellationError {
                errorMessage = "已停止"
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.shared.error("檔案轉錄失敗: \(error.localizedDescription)", category: "STT")
            }
            isTranscribing = false
        }
    }

    private func summarize() {
        let transcript = plainText(timestamps: true)
        isSummarizing = true
        notes = ""
        let provider = settingsStore.selectedProvider
        let model = settingsStore.selectedModel
        let language = settingsStore.languagePreference
        Task { @MainActor in
            defer { isSummarizing = false }
            let prompt = """
            You turn a raw speech transcript (with [mm:ss] timestamps, possibly containing recognition errors) into clean meeting / voice notes.
            Write in the language indicated by language_preference (zh-TW means Traditional Chinese, Taiwan wording).
            Output Markdown with these sections:
            ## 摘要 — 3–5 sentences
            ## 重點 — bullet points, each with the [mm:ss] timestamp where it was discussed
            ## 待辦事項 — action items with owner if mentioned (omit section if none)
            Fix obvious recognition errors using context. Do not invent facts that are not in the transcript.
            """
            let payload = LLMPayload(
                transcript: transcript, context: nil, mode: nil, tone: nil,
                languagePreference: language, personalDictionary: nil, snippets: nil,
                screenContext: nil, whisperMode: nil, existingText: nil
            )
            do {
                for try await event in await OpenRouterClient().sendStreaming(
                    systemPrompt: prompt, payload: payload, model: model, temperature: 0.3, provider: provider
                ) {
                    if case .text(let chunk) = event { notes += chunk }
                }
            } catch {
                notes = "AI 整理失敗：\(TextRefiner.friendlyErrorMessage(error))"
            }
        }
    }

    private func plainText(timestamps: Bool) -> String {
        segments.map { seg in
            timestamps ? "[\(SherpaFileTranscriber.timestamp(seg.start))] \(seg.text)" : seg.text
        }.joined(separator: timestamps ? "\n" : "")
    }

    private func save(_ text: String, suffix: String, ext: String = "txt") {
        let panel = NSSavePanel()
        let base = fileURL?.deletingPathExtension().lastPathComponent ?? "Saybit"
        panel.nameFieldStringValue = "\(base)-\(suffix).\(ext)"
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
#endif

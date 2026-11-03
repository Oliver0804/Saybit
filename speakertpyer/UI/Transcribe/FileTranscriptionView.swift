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
    /// 轉錄狀態由 SettingsView 持有，切分頁回來仍在
    @Bindable var model: FileTranscriptionModel
    @State private var isDropTargeted = false

    private static let types: [UTType] = [.audio, .movie, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .aiff, .mpeg4Audio]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !models.isInstalled {
                    GlassCard {
                        Label(L10n.Transcribe.modelMissing, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                dropZone
                if model.isTranscribing || !model.segments.isEmpty || model.errorMessage != nil {
                    transcriptCard
                }
                if !model.notes.isEmpty || model.isSummarizing {
                    notesCard
                }
            }
            .padding(20)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.Transcribe.title).font(.title.bold())
            Text(L10n.Transcribe.subtitle)
                .foregroundStyle(.secondary)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 36))
                .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
            if let fileURL = model.fileURL {
                Text(fileURL.lastPathComponent).font(.headline)
            } else {
                Text(L10n.Transcribe.dropHint).font(.headline)
            }
            Text("m4a · mp3 · wav · aiff · mov · mp4").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L10n.Transcribe.chooseFile) { chooseFile() }
                if model.isTranscribing {
                    Button(L10n.Transcribe.stop, role: .cancel) { model.stop() }
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
                    GlassSectionHeader(title: L10n.Transcribe.transcript, icon: "text.alignleft")
                    Spacer()
                    Toggle(L10n.Transcribe.timestamps, isOn: $model.showTimestamps).toggleStyle(.checkbox)
                }
                if model.isTranscribing {
                    ProgressView(value: model.progress) {
                        Text(L10n.Transcribe.progress(Int(model.progress * 100), Int(model.elapsed))).font(.caption)
                    }
                } else if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                } else if !model.segments.isEmpty {
                    Text(L10n.Transcribe.finished(model.segments.count, String(format: "%.1f", model.elapsed)))
                        .font(.caption).foregroundStyle(.secondary)
                }

                Text(model.plainText(timestamps: model.showTimestamps))
                    .textSelection(.enabled)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !model.isTranscribing, !model.segments.isEmpty {
                    HStack {
                        Button(L10n.Transcribe.copy) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.plainText(timestamps: model.showTimestamps), forType: .string)
                        }
                        Button(L10n.Transcribe.saveText) {
                            save(model.plainText(timestamps: model.showTimestamps), suffix: L10n.Transcribe.transcriptSuffix)
                        }
                        Spacer()
                        Button {
                            model.summarize(provider: settingsStore.selectedProvider,
                                            model: settingsStore.selectedModel,
                                            language: settingsStore.languagePreference)
                        } label: {
                            Label(L10n.Transcribe.summarize, systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isSummarizing)
                    }
                }
            }
        }
    }

    private var notesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                GlassSectionHeader(title: L10n.Transcribe.notes, icon: "sparkles")
                if model.isSummarizing && model.notes.isEmpty {
                    ProgressView().controlSize(.small)
                }
                Text(model.notes)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !model.isSummarizing, !model.notes.isEmpty {
                    HStack {
                        Button(L10n.Transcribe.copy) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.notes, forType: .string)
                        }
                        Button(L10n.Transcribe.saveMarkdown) {
                            save(model.notes, suffix: L10n.Transcribe.notesSuffix, ext: "md")
                        }
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
        let paths = SherpaFileTranscriber.ModelPaths(model: models.modelPath, tokens: models.tokensPath, vad: models.vadPath)
        let toTraditional = settingsStore.languagePreference == AppLanguage.zhTW.rawValue
        model.start(url: url, paths: paths, toTraditional: toTraditional)
    }

    private func save(_ text: String, suffix: String, ext: String = "txt") {
        let panel = NSSavePanel()
        let base = model.fileURL?.deletingPathExtension().lastPathComponent ?? "Saybit"
        panel.nameFieldStringValue = "\(base)-\(suffix).\(ext)"
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
#endif

//
//  FileTranscriptionModel.swift
//  speakertpyer
//
//  檔案轉錄的狀態與任務。由 SettingsView 持有，切換分頁時 view 會被銷毀，但轉錄進度與結果保留在這裡。
//

#if os(macOS)
import Foundation
import Observation

@MainActor
@Observable
final class FileTranscriptionModel {
    var fileURL: URL?
    var segments: [SherpaFileTranscriber.Segment] = []
    var progress: Double = 0
    var isTranscribing = false
    var errorMessage: String?
    var elapsed: TimeInterval = 0
    var showTimestamps = true

    var notes = ""
    var isSummarizing = false

    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var summarizeJob: Task<Void, Never>?
    /// 每次開始新檔案就 +1；舊任務排進主執行緒的回呼若世代不符就丟掉，避免段落混進新檔
    @ObservationIgnored private var generation = 0

    // MARK: - Transcription

    func start(url: URL, paths: SherpaFileTranscriber.ModelPaths, toTraditional: Bool) {
        job?.cancel()
        summarizeJob?.cancel()
        generation += 1
        let gen = generation

        fileURL = url
        segments = []
        notes = ""
        isSummarizing = false
        errorMessage = nil
        progress = 0
        elapsed = 0
        isTranscribing = true
        AppLogger.shared.info("檔案轉錄開始: \(url.lastPathComponent)", category: "STT")

        let began = Date()
        let onSegment: @Sendable (SherpaFileTranscriber.Segment) -> Void = { [weak self] seg in
            Task { @MainActor [weak self] in self?.append(seg, gen: gen) }
        }
        let onProgress: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor [weak self] in self?.setProgress(p, gen: gen) }
        }
        job = Task { [weak self] in
            let ticker = Task { [weak self] in
                while !Task.isCancelled {
                    self?.tick(gen: gen, began: began)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { ticker.cancel() }

            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                // 直接 await（結構化），stop() 取消 job 時會傳遞到轉錄迴圈的 checkCancellation
                let result = try await Self.transcribeOffMain(
                    url: url, paths: paths, toTraditional: toTraditional,
                    onSegment: onSegment, onProgress: onProgress
                )
                self?.finish(result, gen: gen, began: began)
            } catch {
                self?.fail(error, gen: gen)
            }
        }
    }

    func stop() {
        job?.cancel()
    }

    /// SherpaFileTranscriber.transcribe 是 nonisolated async，在 approachable concurrency 下會跑在呼叫端（主執行緒）；
    /// 用 @concurrent 確保解碼在背景執行緒，且仍是同一個 Task 的子呼叫（取消可傳遞）。
    @concurrent
    nonisolated private static func transcribeOffMain(
        url: URL,
        paths: SherpaFileTranscriber.ModelPaths,
        toTraditional: Bool,
        onSegment: @escaping @Sendable (SherpaFileTranscriber.Segment) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [SherpaFileTranscriber.Segment] {
        try await SherpaFileTranscriber.transcribe(
            url: url, paths: paths, toTraditional: toTraditional,
            onSegment: onSegment, onProgress: onProgress
        )
    }

    private func tick(gen: Int, began: Date) {
        guard gen == generation, isTranscribing else { return }
        elapsed = Date().timeIntervalSince(began)
    }

    private func append(_ seg: SherpaFileTranscriber.Segment, gen: Int) {
        guard gen == generation, isTranscribing else { return }
        segments.append(seg)
    }

    private func setProgress(_ p: Double, gen: Int) {
        guard gen == generation, isTranscribing else { return }
        progress = p
    }

    private func finish(_ result: [SherpaFileTranscriber.Segment], gen: Int, began: Date) {
        guard gen == generation else { return }
        segments = result
        elapsed = Date().timeIntervalSince(began)
        isTranscribing = false
        AppLogger.shared.info("檔案轉錄完成: \(result.count) 段, \(String(format: "%.1f", elapsed))s", category: "STT")
    }

    private func fail(_ error: Error, gen: Int) {
        guard gen == generation else { return }
        if error is CancellationError || Task.isCancelled {
            errorMessage = L10n.Transcribe.stopped
        } else {
            errorMessage = error.localizedDescription
            AppLogger.shared.error("檔案轉錄失敗: \(error.localizedDescription)", category: "STT")
        }
        isTranscribing = false
    }

    // MARK: - Summarize

    func summarize(provider: LLMProvider, model: String, language: String) {
        summarizeJob?.cancel()
        let transcript = plainText(timestamps: true)
        let gen = generation
        isSummarizing = true
        notes = ""
        summarizeJob = Task { [weak self] in
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
                    try Task.checkCancellation()
                    guard let self, self.generation == gen else { return }
                    if case .text(let chunk) = event { self.notes += chunk }
                }
            } catch {
                if Task.isCancelled { return }
                guard let self, self.generation == gen else { return }
                self.notes = L10n.Transcribe.summarizeFailed(TextRefiner.friendlyErrorMessage(error))
            }
            guard let self, self.generation == gen else { return }
            self.isSummarizing = false
        }
    }

    func plainText(timestamps: Bool) -> String {
        segments.map { seg in
            timestamps ? "[\(SherpaFileTranscriber.timestamp(seg.start))] \(seg.text)" : seg.text
        }.joined(separator: timestamps ? "\n" : "")
    }
}
#endif

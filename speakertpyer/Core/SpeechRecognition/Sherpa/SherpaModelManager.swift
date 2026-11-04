//
//  SherpaModelManager.swift
//  speakertpyer + SaybitiOS
//
//  離線辨識模型（SenseVoice int8 + Silero VAD，約 240MB）的下載 / 刪除。
//  放在 Application Support，排除 iCloud 備份。
//

import Foundation
import Observation

@Observable
final class SherpaModelManager {
    static let shared = SherpaModelManager()

    enum State: Equatable {
        case notInstalled
        case downloading(progress: Double)
        case installed
        case failed(String)
    }

    struct ModelFile {
        let name: String
        let url: URL
        let size: Int64
    }

    static let modelID = "sense-voice-zh-en-ja-ko-yue-int8-2025-09-09"
    private static let hf = "https://huggingface.co/csukuangfj/sherpa-onnx-\(modelID)/resolve/main"
    static let files: [ModelFile] = [
        ModelFile(name: "model.int8.onnx", url: URL(string: "\(hf)/model.int8.onnx")!, size: 237_115_547),
        ModelFile(name: "tokens.txt", url: URL(string: "\(hf)/tokens.txt")!, size: 315_894),
        ModelFile(name: "silero_vad.onnx",
                  url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx")!,
                  size: 643_854),
    ]
    static var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    private(set) var state: State = .notInstalled
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    /// 目前下載的識別碼：取消後立刻再下載時，舊 Task 的收尾不能清掉 / 覆寫新下載的狀態
    @ObservationIgnored private var downloadToken: UUID?
    @ObservationIgnored private let log = AppLogger.shared

    let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if os(macOS)
        let root = "Saybit/SherpaModels"   // ~/Library/Application Support/Saybit/SherpaModels
        #else
        let root = "SherpaModels"
        #endif
        return base.appendingPathComponent("\(root)/\(SherpaModelManager.modelID)", isDirectory: true)
    }()

    var modelPath: String { directory.appendingPathComponent("model.int8.onnx").path }
    var tokensPath: String { directory.appendingPathComponent("tokens.txt").path }
    var vadPath: String { directory.appendingPathComponent("silero_vad.onnx").path }

    private init() {
        state = checkInstalled() ? .installed : .notInstalled
    }

    var isInstalled: Bool { state == .installed }

    private func checkInstalled() -> Bool {
        Self.files.allSatisfy { file in
            let path = directory.appendingPathComponent(file.name).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil
            return size == file.size
        }
    }

    // MARK: - Download

    func download() {
        guard downloadTask == nil, !isInstalled else { return }
        state = .downloading(progress: 0)
        let token = UUID()
        downloadToken = token
        downloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.downloadToken == token {
                    self.downloadTask = nil
                    self.downloadToken = nil
                }
            }
            do {
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                var done: Int64 = 0
                for file in Self.files {
                    let dest = self.directory.appendingPathComponent(file.name)
                    if let size = try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64,
                       size == file.size {
                        done += file.size
                        continue
                    }
                    let base = done
                    try await Self.fetch(file.url, to: dest) { written in
                        Task { @MainActor [weak self] in
                            guard let self, self.downloadToken == token,
                                  case .downloading = self.state else { return }
                            self.state = .downloading(progress: Double(base + written) / Double(Self.totalSize))
                        }
                    }
                    done += file.size
                }
                var dir = self.directory
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? dir.setResourceValues(values)

                try Task.checkCancellation()
                guard self.checkInstalled() else { throw URLError(.cannotDecodeContentData) }
                guard self.downloadToken == token else { return }
                self.state = .installed
                self.log.info("離線模型下載完成", category: "STT")
            } catch {
                // 已被取消 / 被新的下載取代：狀態由 cancelDownload 或新下載負責，不要覆寫
                guard self.downloadToken == token else { return }
                // URLSession 被取消拋的是 URLError(.cancelled)，不是 CancellationError
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self.state = self.checkInstalled() ? .installed : .notInstalled
                    self.log.info("離線模型下載已取消", category: "STT")
                } else {
                    self.log.error("離線模型下載失敗: \(error.localizedDescription)", category: "STT")
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadToken = nil
        state = checkInstalled() ? .installed : .notInstalled
    }

    func delete() {
        cancelDownload()
        try? FileManager.default.removeItem(at: directory)
        state = .notInstalled
        log.info("離線模型已刪除", category: "STT")
    }

    private static func fetch(_ url: URL, to dest: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let delegate = ProgressDelegate(onProgress: progress)
        let (tmp, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }
}

nonisolated private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Int64) -> Void
    init(onProgress: @escaping @Sendable (Int64) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

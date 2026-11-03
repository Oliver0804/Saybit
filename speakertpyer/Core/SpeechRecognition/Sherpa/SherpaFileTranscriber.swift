//
//  SherpaFileTranscriber.swift
//  speakertpyer + SaybitiOS
//
//  音檔 / 影片 → 逐字稿（SenseVoice 離線辨識 + VAD 切句，附時間戳）。
//  用 AVAssetReader 直接解出 16kHz 單聲道 PCM，支援 m4a、mp3、wav、aiff、mov、mp4 等。
//  使用獨立的 recognizer 實例，不影響即時聽寫用的常駐模型。
//

import AVFoundation
import Foundation

nonisolated enum SherpaFileTranscriber {
    struct Segment: Identifiable, Sendable {
        let id = UUID()
        let start: Double
        let end: Double
        let text: String
    }

    enum TranscribeError: LocalizedError {
        case modelMissing
        case loadFailed
        case noAudioTrack
        case readFailed(String)

        var errorDescription: String? {
            switch self {
            case .modelMissing: return SherpaSTTError.modelMissing.errorDescription
            case .loadFailed: return SherpaSTTError.loadFailed.errorDescription
            case .noAudioTrack: return "這個檔案沒有音訊軌"
            case .readFailed(let msg): return "讀取音訊失敗：\(msg)"
            }
        }
    }

    struct ModelPaths: Sendable {
        let model: String
        let tokens: String
        let vad: String
    }

    /// - Parameters:
    ///   - onSegment: 每辨識完一段就回呼（背景執行緒）
    ///   - onProgress: 0...1（背景執行緒）
    static func transcribe(
        url: URL,
        paths: ModelPaths,
        toTraditional: Bool,
        onSegment: @escaping @Sendable (Segment) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [Segment] {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw TranscribeError.noAudioTrack }
        let duration = try await asset.load(.duration).seconds

        guard let recognizer = SherpaOfflineRecognizer(modelPath: paths.model, tokensPath: paths.tokens, numThreads: 4),
              let vad = SherpaVAD(modelPath: paths.vad, minSilence: 0.6, maxSpeech: 25) else {
            throw TranscribeError.loadFailed
        }
        try Task.checkCancellation()

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw TranscribeError.readFailed(error.localizedDescription) }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(SherpaOfflineRecognizer.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { throw TranscribeError.readFailed("不支援的音訊格式") }
        reader.add(output)
        guard reader.startReading() else {
            throw TranscribeError.readFailed(reader.error?.localizedDescription ?? "未知錯誤")
        }

        let rate = Double(SherpaOfflineRecognizer.sampleRate)
        let window = SherpaVAD.windowSize
        var pending: [Float] = []
        var fed = 0
        var segments: [Segment] = []

        func drain() throws {
            for seg in vad.popSegments() {
                try Task.checkCancellation()
                let raw = recognizer.decode(seg.samples[...])
                guard !raw.isEmpty else { continue }
                let text = toTraditional ? (raw.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? raw) : raw
                let s = Segment(start: Double(seg.start) / rate,
                                end: Double(seg.start + seg.samples.count) / rate,
                                text: text)
                segments.append(s)
                if Task.isCancelled { throw CancellationError() }
                onSegment(s)
            }
        }

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length, dataPointerOut: &ptr) == noErr,
                  let ptr else { continue }
            let count = length / MemoryLayout<Float>.size
            ptr.withMemoryRebound(to: Float.self, capacity: count) {
                pending.append(contentsOf: UnsafeBufferPointer(start: $0, count: count))
            }
            var offset = 0
            while pending.count - offset >= window {
                vad.accept(pending[offset ..< offset + window])
                offset += window
            }
            pending.removeFirst(offset)
            fed += offset
            try drain()
            if duration > 0 { onProgress(min(Double(fed) / rate / duration, 0.99)) }
        }

        if reader.status == .failed {
            throw TranscribeError.readFailed(reader.error?.localizedDescription ?? "未知錯誤")
        }
        if !pending.isEmpty { vad.accept(pending[...]) }
        vad.flush()
        try drain()
        onProgress(1)
        return segments
    }

    static func timestamp(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

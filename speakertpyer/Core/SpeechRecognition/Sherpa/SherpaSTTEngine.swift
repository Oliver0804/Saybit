//
//  SherpaSTTEngine.swift
//  speakertpyer + SaybitiOS
//
//  離線 STT：sherpa-onnx SenseVoice + Silero VAD。
//  SenseVoice 不是串流模型，所以用 VAD 切句：每句講完就辨識並定稿；
//  講話中每 ~0.8 秒把「尚未定稿」的音訊重新辨識一次當即時字幕（SenseVoice 很快，負擔不大）。
//  按停止時 flush VAD，把剩下的句子辨識完回傳。
//

import AVFoundation
import Foundation
import Observation

nonisolated enum SherpaSTTError: LocalizedError {
    case modelMissing
    case loadFailed

    var errorDescription: String? {
        switch self {
        case .modelMissing: return "尚未下載離線辨識模型，請到「設定 › 辨識引擎與收音」下載"
        case .loadFailed: return "離線辨識模型載入失敗，請到設定刪除後重新下載"
        }
    }
}

@Observable
final class SherpaSTTEngine: AudioBufferConsumer {
    let consumerID = "SherpaSTTEngine"

    private(set) var transcript = ""
    private(set) var audioLevel: Float = 0
    private(set) var isListening = false
    var micGain: Float = 2.0

    var onSilenceTimeout: (() -> Void)? {
        get { silenceDetector.onSilenceTimeout }
        set { silenceDetector.onSilenceTimeout = newValue }
    }
    var silenceTimeoutDuration: TimeInterval {
        get { silenceDetector.silenceTimeoutDuration }
        set { silenceDetector.silenceTimeoutDuration = newValue }
    }

    @ObservationIgnored private let silenceDetector = SilenceDetector()
    @ObservationIgnored private let audioLevelThrottler = MainThreadThrottler(intervalMs: 50)
    @ObservationIgnored private let worker = SherpaWorker()
    @ObservationIgnored private let log = AppLogger.shared

    func startListening(languagePreference: String) throws {
        let models = SherpaModelManager.shared
        guard models.isInstalled else { throw SherpaSTTError.modelMissing }

        transcript = ""
        worker.onTranscript = { [weak self] text in
            DispatchQueue.main.async { self?.transcript = text }
        }
        worker.onSpeech = { [weak self] in
            DispatchQueue.main.async { self?.silenceDetector.update(rawLevel: 1) }
        }
        worker.begin(
            paths: .init(model: models.modelPath, tokens: models.tokensPath, vad: models.vadPath),
            toTraditional: languagePreference == AppLanguage.zhTW.rawValue
        )
        silenceDetector.start()
        audioLevelThrottler.reset()
        isListening = true
        SharedAudioEngine.shared.addConsumer(self, replayPreBuffer: true)
        log.info("Sherpa 開始錄音", category: "STT")
    }

    /// 停止收音並等最後一段辨識完成
    func stopListening() async throws -> String {
        SharedAudioEngine.shared.removeConsumer(self)
        isListening = false
        silenceDetector.reset()
        audioLevel = 0
        let start = Date()
        let text: String = try await withCheckedThrowingContinuation { cont in
            worker.finish { cont.resume(with: $0) }
        }
        transcript = text
        log.info("Sherpa 辨識完成 (收尾 \(String(format: "%.2f", Date().timeIntervalSince(start)))s)", category: "STT")
        return text
    }

    func cancel() {
        SharedAudioEngine.shared.removeConsumer(self)
        isListening = false
        silenceDetector.reset()
        audioLevel = 0
        transcript = ""
        worker.cancel()
    }

    /// 預先載入模型（macOS 常駐用），讓第一次錄音不用等 ~1 秒載入
    func preloadModel() {
        let models = SherpaModelManager.shared
        guard models.isInstalled else {
            log.info("Sherpa 模型未安裝，略過預載 (\(models.directory.path))", category: "STT")
            return
        }
        worker.preload(paths: .init(model: models.modelPath, tokens: models.tokensPath, vad: models.vadPath))
    }

    /// 釋放模型記憶體（約 250MB）；下次錄音會重新載入（~1 秒，音訊會先排隊不會遺失）
    func unloadModel() {
        worker.unload()
    }

    // MARK: - AudioBufferConsumer（render thread）

    func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        if let copy = buffer.copy() as? AVAudioPCMBuffer {
            worker.append(copy)
        }
        guard let rms = AudioUtils.rms(from: buffer) else { return }
        let displayLevel = AudioUtils.normalizedLevel(rms: rms, multiplier: 5.0 * micGain)
        audioLevelThrottler.dispatch { [weak self] in
            self?.audioLevel = displayLevel
        }
        silenceDetector.update(rawLevel: AudioUtils.normalizedLevel(rms: rms))
    }
}

// MARK: - Worker（serial queue，持有所有 sherpa 物件）

nonisolated final class SherpaWorker: @unchecked Sendable {
    struct Paths: Equatable {
        let model: String
        let tokens: String
        let vad: String
    }

    private static let rate = Int(SherpaOfflineRecognizer.sampleRate)
    private static let partialInterval = rate * 8 / 10        // 每 0.8 秒新音訊更新一次字幕
    private static let maxPartialWindow = rate * 25           // 字幕最多重算最後 25 秒

    /// 在 worker queue 上呼叫
    var onTranscript: (@Sendable (String) -> Void)?
    /// VAD 判定正在講話時呼叫（worker queue）；小聲說話時音量門檻抓不到，用它防止被誤判靜音而停止
    var onSpeech: (@Sendable () -> Void)?

    private let queue = DispatchQueue(label: "com.bashcat.saybit.sherpa", qos: .userInitiated)
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate),
                                          channels: 1, interleaved: false)!

    // 以下只在 queue 上存取
    private var loadedPaths: Paths?
    private var recognizer: SherpaOfflineRecognizer?
    private var vad: SherpaVAD?
    private var converter: AVAudioConverter?
    private var active = false
    private var toTraditional = false
    private var samples: [Float] = []
    private var vadFed = 0
    private var committed: [String] = []
    private var committedEnd = 0
    private var lastPartialAt = 0
    private var partial = ""

    func preload(paths: Paths) {
        queue.async { [self] in loadIfNeeded(paths) }
    }

    /// queue 上呼叫
    private func loadIfNeeded(_ paths: Paths) {
        guard loadedPaths != paths || recognizer == nil || vad == nil else { return }
        let t = Date()
        recognizer = SherpaOfflineRecognizer(modelPath: paths.model, tokensPath: paths.tokens)
        vad = SherpaVAD(modelPath: paths.vad)
        loadedPaths = (recognizer != nil && vad != nil) ? paths : nil
        let msg = "Sherpa 模型載入\(loadedPaths != nil ? "成功" : "失敗") (\(String(format: "%.2f", Date().timeIntervalSince(t)))s)"
        DispatchQueue.main.async { AppLogger.shared.info(msg, category: "STT") }
    }

    func begin(paths: Paths, toTraditional: Bool) {
        queue.async { [self] in
            loadIfNeeded(paths)
            vad?.reset()
            converter = nil
            samples.removeAll(keepingCapacity: true)
            vadFed = 0
            committed = []
            committedEnd = 0
            lastPartialAt = 0
            partial = ""
            self.toTraditional = toTraditional
            active = true
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            guard active, recognizer != nil else { return }
            convert(buffer)
            process(final: false)
        }
    }

    func finish(_ completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        queue.async { [self] in
            guard let recognizer, active else {
                active = false
                completion(.failure(SherpaSTTError.loadFailed))
                return
            }
            process(final: true)
            // VAD 什麼都沒切到（例如很小聲）→ 整段直接辨識一次
            // 但幾乎沒聲音時不辨識，否則 SenseVoice 會對著底噪吐出「嗯」之類的字
            let tail = samples.suffix(Self.rate * 30)
            if committed.isEmpty, tail.count > Self.rate * 3 / 10, Self.rms(tail) > 0.004 {
                let text = recognizer.decode(tail)
                if !text.isEmpty { committed = [text] }
            }
            active = false
            let text = render(committed)
            samples.removeAll()
            completion(.success(text))
        }
    }

    func cancel() {
        queue.async { [self] in
            active = false
            samples.removeAll()
            committed = []
        }
    }

    func unload() {
        queue.async { [self] in
            guard !active else { return }
            recognizer = nil
            vad = nil
            loadedPaths = nil
        }
    }

    // MARK: - Private (queue)

    private func convert(_ buffer: AVAudioPCMBuffer) {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outFormat)
        }
        guard let converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let ch = out.floatChannelData?[0], out.frameLength > 0 else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
    }

    private func process(final: Bool) {
        guard let recognizer, let vad else { return }
        let window = SherpaVAD.windowSize
        while samples.count - vadFed >= window {
            vad.accept(samples[vadFed ..< vadFed + window])
            vadFed += window
        }
        if final {
            if vadFed < samples.count {
                vad.accept(samples[vadFed...])
                vadFed = samples.count
            }
            vad.flush()
        }

        var changed = false
        for seg in vad.popSegments() {
            let text = recognizer.decode(seg.samples[...])
            if !text.isEmpty { committed.append(text) }
            committedEnd = max(committedEnd, seg.start + seg.samples.count)
            partial = ""
            lastPartialAt = samples.count
            changed = true
        }

        if !final, vad.isSpeaking { onSpeech?() }

        if !final, vad.isSpeaking, samples.count - lastPartialAt >= Self.partialInterval {
            lastPartialAt = samples.count
            let from = max(committedEnd, samples.count - Self.maxPartialWindow)
            if from < samples.count {
                partial = recognizer.decode(samples[from...])
                changed = true
            }
        }

        if changed, !final {
            onTranscript?(render(committed + (partial.isEmpty ? [] : [partial])))
        }
    }

    private static func rms(_ x: ArraySlice<Float>) -> Float {
        guard !x.isEmpty else { return 0 }
        var sum: Float = 0
        for v in x { sum += v * v }
        return (sum / Float(x.count)).squareRoot()
    }

    private func render(_ parts: [String]) -> String {
        var out = ""
        // 這版 SenseVoice 不一定輸出標點：句與句之間補分隔，讓 LLM 看得出斷句
        for part in parts {
            if let last = out.last, let first = part.first, !last.isPunctuation {
                out += (last.isASCII && first.isASCII) ? " " : "，"
            }
            out += part
        }
        if toTraditional {
            out = out.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? out
        }
        return out
    }
}

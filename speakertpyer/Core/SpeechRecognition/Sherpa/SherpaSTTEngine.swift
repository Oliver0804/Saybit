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
    /// 每次 start/stop/cancel 遞增；舊 session 排隊中的字幕更新比對不符就丟棄
    @ObservationIgnored private var sessionToken: UInt64 = 0
    /// render thread 讀取的 micGain 快照
    @ObservationIgnored private let renderMicGain = LockedValue<Float>(2.0)

    func startListening(languagePreference: String) throws {
        let models = SherpaModelManager.shared
        guard models.isInstalled else { throw SherpaSTTError.modelMissing }

        transcript = ""
        sessionToken &+= 1
        let token = sessionToken
        worker.onTranscript = { [weak self] text in
            DispatchQueue.main.async {
                guard let self, self.sessionToken == token, self.isListening else { return }
                self.transcript = text
            }
        }
        // SilenceDetector 內部有鎖，可直接在 worker queue 上更新
        let detector = silenceDetector
        worker.onSpeech = { detector.update(rawLevel: 1) }
        renderMicGain.withLock { $0 = micGain }
        silenceDetector.start()
        audioLevelThrottler.reset()
        // 先開放 ring 收音（pre-buffer 回放要寫得進去），再排 begin，最後註冊 consumer 回放
        worker.openInput()
        worker.begin(
            paths: .init(model: models.modelPath, tokens: models.tokensPath, vad: models.vadPath),
            toTraditional: languagePreference == AppLanguage.zhTW.rawValue
        )
        isListening = true
        SharedAudioEngine.shared.addConsumer(self, replayPreBuffer: true)
        log.info("Sherpa 開始錄音", category: "STT")
    }

    /// 停止收音並等最後一段辨識完成
    func stopListening() async throws -> String {
        SharedAudioEngine.shared.removeConsumer(self)
        worker.closeInput()
        isListening = false
        sessionToken &+= 1
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
        worker.closeInput()
        isListening = false
        sessionToken &+= 1
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
        // memcpy 進 worker 預配置的 ring，再以 DispatchSource 通知（不 copy buffer、不配置閉包）
        guard worker.enqueue(buffer) else { return }
        guard let rms = AudioUtils.rms(from: buffer) else { return }
        let gain = renderMicGain.withLock { $0 }
        let displayLevel = AudioUtils.normalizedLevel(rms: rms, multiplier: 5.0 * gain)
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
    private static let maxPartialWindow = rate * 8            // 字幕最多重算最後 8 秒（長句不會越算越慢）
    private static let partialMinWallNanos: UInt64 = 800_000_000
    /// 一次 drain 超過這麼多（原生取樣率秒數）代表 worker 落後 → 這輪跳過字幕重算，先追上
    private static let behindThresholdSeconds: Double = 1.0

    /// 在 worker queue 上呼叫
    var onTranscript: (@Sendable (String) -> Void)?
    /// VAD 判定正在講話時呼叫（worker queue）；小聲說話時音量門檻抓不到，用它防止被誤判靜音而停止
    var onSpeech: (@Sendable () -> Void)?

    private let queue = DispatchQueue(label: "com.bashcat.saybit.sherpa", qos: .userInitiated)
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate),
                                          channels: 1, interleaved: false)!

    /// render thread → worker 的預配置 ring（mono Float，裝置原生取樣率）
    private let ring = SherpaInputRing(capacitySamples: 48_000 * 20)
    /// render thread 寫入後 `add(data:)` 通知 worker queue drain（合併通知、不配置記憶體）
    private let drainSource: DispatchSourceUserDataAdd

    init() {
        drainSource = DispatchSource.makeUserDataAddSource(queue: queue)
        drainSource.setEventHandler { [weak self] in self?.drainAndProcess() }
        drainSource.activate()
    }

    deinit {
        drainSource.cancel()
    }

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
    private var lastPartialWallNanos: UInt64 = 0
    private var partial = ""
    private var drainScratch: [Float] = []

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
            lastPartialWallNanos = 0
            partial = ""
            self.toTraditional = toTraditional
            active = true
        }
    }

    /// main：清空 ring 並開始接受音訊（在 begin 與註冊 consumer 之前呼叫）
    func openInput() {
        ring.reset(accepting: true)
    }

    /// main：停止接受新音訊（已寫入的仍會在 finish 時處理）
    func closeInput() {
        ring.setAccepting(false)
    }

    /// render thread：把 buffer memcpy 進 ring 並通知 worker；未開放收音時回傳 false
    func enqueue(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard ring.write(buffer) else { return false }
        drainSource.add(data: 1)
        return true
    }

    /// queue 上呼叫：把 ring 內容搬出、轉 16k 後送 VAD / 字幕
    private func drainAndProcess() {
        // 尚未 begin（或已 cancel）時不動 ring：資料留給下一個 begin 之後的 drain，
        // ring 本身由 openInput / cancel 在 main 清空，不會混到別的 session
        guard active, recognizer != nil else { return }
        let rate = ring.drain(into: &drainScratch)
        guard !drainScratch.isEmpty else { return }
        let behind = rate > 0 && Double(drainScratch.count) / rate > Self.behindThresholdSeconds
        convert(drainScratch, sampleRate: rate)
        drainScratch.removeAll(keepingCapacity: true)
        process(final: false, allowPartial: !behind)
    }

    func finish(_ completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        queue.async { [self] in
            // 收尾前把 ring 裡剩下的音訊處理完
            if active, recognizer != nil {
                let rate = ring.drain(into: &drainScratch)
                if !drainScratch.isEmpty { convert(drainScratch, sampleRate: rate) }
            }
            drainScratch.removeAll(keepingCapacity: true)
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
        ring.reset(accepting: false)
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

    private func convert(_ input: [Float], sampleRate: Double) {
        guard sampleRate > 0,
              let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                           channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(input.count)),
              let dst = buffer.floatChannelData?[0] else { return }
        input.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { dst.update(from: base, count: input.count) }
        }
        buffer.frameLength = AVAudioFrameCount(input.count)

        if converter == nil || converter?.inputFormat != inFormat {
            converter = AVAudioConverter(from: inFormat, to: outFormat)
        }
        guard let converter else { return }
        let ratio = outFormat.sampleRate / inFormat.sampleRate
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

    private func process(final: Bool, allowPartial: Bool = true) {
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

        let now = DispatchTime.now().uptimeNanoseconds
        if !final, allowPartial, vad.isSpeaking,
           samples.count - lastPartialAt >= Self.partialInterval,
           now &- lastPartialWallNanos >= Self.partialMinWallNanos {
            lastPartialAt = samples.count
            lastPartialWallNanos = now
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

// MARK: - Render → worker ring

/// 預配置的 mono Float 環形緩衝區：render thread 只做下混 + memcpy，worker queue 取出。
/// 容量用完（worker 卡住超過 ~20 秒）時丟掉新音訊並計數，不在 render thread 擴容。
nonisolated final class SherpaInputRing: @unchecked Sendable {
    private let lock = UnfairLock()
    private var storage: [Float]
    private var readIndex = 0
    private var count = 0
    private var sampleRate: Double = 0
    private var accepting = false
    private var dropped = 0

    init(capacitySamples: Int) {
        storage = [Float](repeating: 0, count: max(1, capacitySamples))
    }

    func reset(accepting: Bool) {
        lock.withLock {
            readIndex = 0
            count = 0
            sampleRate = 0
            dropped = 0
            self.accepting = accepting
        }
    }

    func setAccepting(_ value: Bool) {
        lock.withLock { accepting = value }
    }

    /// render thread
    func write(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let channels = buffer.floatChannelData else { return false }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        lock.lock()
        defer { lock.unlock() }
        guard accepting else { return false }
        guard frames > 0, channelCount > 0 else { return true }
        let rate = buffer.format.sampleRate
        if sampleRate != rate {
            // 裝置取樣率改變（切換輸入裝置）：舊取樣率的資料已無法一起轉換，丟掉重來
            if count > 0 { dropped += count }
            readIndex = 0
            count = 0
            sampleRate = rate
        }
        let capacity = storage.count
        let writable = min(frames, capacity - count)
        if writable < frames { dropped += frames - writable }
        guard writable > 0 else { return true }
        let scale = 1 / Float(channelCount)
        storage.withUnsafeMutableBufferPointer { dst in
            var w = (readIndex + count) % capacity
            for i in 0..<writable {
                var v = channels[0][i]
                if channelCount > 1 {
                    for ch in 1..<channelCount { v += channels[ch][i] }
                    v *= scale
                }
                dst[w] = v
                w += 1
                if w == capacity { w = 0 }
            }
        }
        count += writable
        return true
    }

    /// worker queue：取出全部內容（append 到 out），回傳取樣率
    func drain(into out: inout [Float]) -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else { return sampleRate }
        let capacity = storage.count
        let first = min(count, capacity - readIndex)
        out.append(contentsOf: storage[readIndex ..< readIndex + first])
        if first < count {
            out.append(contentsOf: storage[0 ..< (count - first)])
        }
        readIndex = (readIndex + count) % capacity
        count = 0
        return sampleRate
    }
}

nonisolated private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = UnfairLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

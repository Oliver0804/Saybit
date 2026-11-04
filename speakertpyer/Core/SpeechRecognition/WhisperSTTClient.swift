//
//  WhisperSTTClient.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/28.
//

import AVFoundation
import Foundation

/// Whisper API STT — 錄音後上傳 OpenAI Whisper API 取得轉錄
@Observable
class WhisperSTTClient: AudioBufferConsumer {
    let consumerID = "WhisperSTTClient"

    var isRecording = false
    var audioLevel: Float = 0.0

    // Silence detection
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

    var micGain: Float = 2.0

    /// render thread 寫入的錄音資料（mono Float，裝置原生取樣率），由 captureLock 保護。
    /// 開始錄音時在 main 預留容量，render thread 只做 memcpy（超過預留長度才會擴容）。
    @ObservationIgnored private let captureLock = UnfairLock()
    @ObservationIgnored private var capturedSamples: [Float] = []
    @ObservationIgnored private var capturedSampleRate: Double = 0
    @ObservationIgnored private var captureAccepting = false
    @ObservationIgnored private var captureMicGain: Float = 2.0
    /// 預留 60 秒（48kHz mono ≈ 11.5MB）；更長的錄音會在 render thread 擴容一次
    private static let reservedSeconds: Double = 60

    @ObservationIgnored private let log = AppLogger.shared

    // MARK: - Recording

    func startRecording() throws {
        silenceDetector.start()

        let rate = SharedAudioEngine.shared.inputFormat?.sampleRate ?? 48_000
        var storage: [Float] = []
        storage.reserveCapacity(Int(rate * Self.reservedSeconds))
        let gain = micGain
        // 必須先開放收音，否則 pre-buffer 回放時 handleAudioBuffer 會被 guard 擋掉
        captureLock.withLock {
            capturedSamples = storage
            capturedSampleRate = 0
            captureAccepting = true
            captureMicGain = gain
        }
        isRecording = true
        audioLevelThrottler.reset()
        SharedAudioEngine.shared.addConsumer(self, replayPreBuffer: true)
        log.info("WhisperSTTClient 開始錄音", category: "STT")
    }

    func stopRecording() -> Data? {
        SharedAudioEngine.shared.removeConsumer(self)
        let (samples, rate): ([Float], Double) = captureLock.withLock {
            captureAccepting = false
            let taken = (capturedSamples, capturedSampleRate)
            capturedSamples = []
            return taken
        }
        isRecording = false
        silenceDetector.reset()
        audioLevel = 0.0
        log.info("WhisperSTTClient 停止錄音 (samples=\(samples.count), rate=\(Int(rate)))", category: "STT")

        guard !samples.isEmpty, rate > 0 else { return nil }
        return convertToWAV(samples: samples, sampleRate: rate)
    }

    // MARK: - AudioBufferConsumer

    func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return }

        captureLock.lock()
        guard captureAccepting else {
            captureLock.unlock()
            return
        }
        let micGain = captureMicGain
        if capturedSampleRate == 0 { capturedSampleRate = buffer.format.sampleRate }
        // 下混成 mono 後 memcpy 進預留空間（不呼叫 buffer.copy()，不做 Obj-C 配置）
        if channelCount == 1 {
            capturedSamples.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: frames))
        } else {
            let base = capturedSamples.count
            capturedSamples.append(contentsOf: repeatElement(0, count: frames))
            let scale = 1 / Float(channelCount)
            capturedSamples.withUnsafeMutableBufferPointer { dst in
                for ch in 0..<channelCount {
                    let src = channels[ch]
                    for i in 0..<frames { dst[base + i] += src[i] * scale }
                }
            }
        }
        captureLock.unlock()

        // RMS 計算
        guard let rms = AudioUtils.rms(from: buffer) else { return }
        let displayLevel = AudioUtils.normalizedLevel(rms: rms, multiplier: 5.0 * micGain)
        let rawLevel = AudioUtils.normalizedLevel(rms: rms)

        // Audio tap 在 render thread；節流到 ~20Hz 派發到 main
        audioLevelThrottler.dispatch { [weak self] in
            self?.audioLevel = displayLevel
        }

        // 靜音偵測（SilenceDetector 內部有鎖）
        silenceDetector.update(rawLevel: rawLevel)
    }

    // MARK: - Whisper API

    func transcribe(audioData: Data, model: String = "whisper-1", language: String? = "zh") async throws -> String {
        guard let apiKey = KeychainHelper.loadAPIKey(for: "whisper_api"), !apiKey.isEmpty else {
            throw WhisperError.noAPIKey
        }

        let url = URL(staticString: "https://api.openai.com/v1/audio/transcriptions")
        let boundary = UUID().uuidString

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        var body = Data()
        // file field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        // model field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model)\r\n".data(using: .utf8)!)
        // language field (omit for auto-detection)
        if let language, !language.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(language)\r\n".data(using: .utf8)!)
        }
        // response_format field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("json\r\n".data(using: .utf8)!)
        // closing boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        log.info("Whisper API 請求 (model=\(model), language=\(language ?? "auto"), audioSize=\(audioData.count) bytes)", category: "STT")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WhisperError.invalidResponse(0)
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            log.error("Whisper API 錯誤 (\(httpResponse.statusCode)): \(errorBody.prefix(200))", category: "STT")
            throw WhisperError.invalidResponse(httpResponse.statusCode)
        }

        let result = try JSONDecoder().decode(WhisperResponse.self, from: data)
        log.info("Whisper API 轉錄完成 (\(result.text.count) 字)", category: "STT")
        return result.text
    }

    /// Quick API key validation
    func testConnection() async throws {
        guard let apiKey = KeychainHelper.loadAPIKey(for: "whisper_api"), !apiKey.isEmpty else {
            throw WhisperError.noAPIKey
        }

        // Send a minimal request to validate the key
        let url = URL(staticString: "https://api.openai.com/v1/models")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw WhisperError.invalidResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    // MARK: - WAV Conversion

    private func convertToWAV(samples: [Float], sampleRate: Double) -> Data? {
        // Target: 16kHz mono 16-bit PCM WAV (optimal for Whisper)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ), let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            log.error("無法建立音訊格式轉換器", category: "STT")
            return nil
        }

        let totalFrames = samples.count
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(totalFrames)),
              let inputData = inputBuffer.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { inputData.update(from: base, count: totalFrames) }
        }
        inputBuffer.frameLength = AVAudioFrameCount(totalFrames)

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let estimatedOutputFrames = AVAudioFrameCount(Double(totalFrames) * ratio) + 1024

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: estimatedOutputFrames) else {
            return nil
        }

        var consumed = false
        var error: NSError?

        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if let error {
            log.error("音訊格式轉換失敗: \(error.localizedDescription)", category: "STT")
            return nil
        }

        // Build WAV file in memory
        return buildWAVData(from: outputBuffer)
    }

    private func buildWAVData(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let int16Data = buffer.int16ChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let sampleRate = Int(buffer.format.sampleRate)
        let bytesPerSample = 2 // 16-bit
        let dataSize = frameCount * channelCount * bytesPerSample

        var data = Data()
        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(UInt32(36 + dataSize).littleEndianBytes)
        data.append(contentsOf: "WAVE".utf8)
        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(UInt32(16).littleEndianBytes) // chunk size
        data.append(UInt16(1).littleEndianBytes)  // PCM format
        data.append(UInt16(channelCount).littleEndianBytes)
        data.append(UInt32(sampleRate).littleEndianBytes)
        data.append(UInt32(sampleRate * channelCount * bytesPerSample).littleEndianBytes) // byte rate
        data.append(UInt16(channelCount * bytesPerSample).littleEndianBytes) // block align
        data.append(UInt16(bytesPerSample * 8).littleEndianBytes) // bits per sample
        // data chunk
        data.append(contentsOf: "data".utf8)
        data.append(UInt32(dataSize).littleEndianBytes)
        // PCM samples
        let rawPointer = UnsafeBufferPointer(start: int16Data[0], count: frameCount * channelCount)
        data.append(UnsafeBufferPointer(start: rawPointer.baseAddress, count: rawPointer.count))

        return data
    }
}

// MARK: - Errors

enum WhisperError: LocalizedError {
    case noAPIKey
    case invalidResponse(Int)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "未設定 Whisper API Key"
        case .invalidResponse(let code):
            switch code {
            case 401: return "Whisper API Key 無效"
            case 429: return "Whisper API 請求過於頻繁"
            default: return "Whisper API 錯誤 (\(code))"
            }
        case .emptyResult: return "Whisper API 未回傳任何文字"
        }
    }
}

// MARK: - Response

private struct WhisperResponse: Decodable {
    let text: String
}

// MARK: - Helpers

private extension UInt32 {
    var littleEndianBytes: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: 4)
    }
}

private extension UInt16 {
    var littleEndianBytes: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: 2)
    }
}

private extension Data {
    mutating func append(_ bufferPointer: UnsafeBufferPointer<Int16>) {
        bufferPointer.baseAddress.map { ptr in
            self.append(UnsafeBufferPointer(start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self),
                                            count: bufferPointer.count * 2))
        }
    }

    mutating func append(_ bufferPointer: UnsafeBufferPointer<UInt8>) {
        guard let baseAddress = bufferPointer.baseAddress, bufferPointer.count > 0 else {
            return
        }
        self.append(baseAddress, count: bufferPointer.count)
    }
}

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
    private let silenceDetector = SilenceDetector()

    private var audioBuffers: [AVAudioPCMBuffer] = []
    private var recordingFormat: AVAudioFormat?
    var micGain: Float = 2.0

    private let log = AppLogger.shared

    // MARK: - Recording

    func startRecording() throws {
        audioBuffers = []
        silenceDetector.start()

        recordingFormat = SharedAudioEngine.shared.inputFormat

        // 必須先設定 isRecording，否則 pre-buffer 回放時 handleAudioBuffer 會被 guard 擋掉
        isRecording = true
        SharedAudioEngine.shared.addConsumer(self, replayPreBuffer: true)
        log.info("WhisperSTTClient 開始錄音", category: "STT")
    }

    func stopRecording() -> Data? {
        SharedAudioEngine.shared.removeConsumer(self)
        isRecording = false
        silenceDetector.reset()
        audioLevel = 0.0
        log.info("WhisperSTTClient 停止錄音 (buffers=\(audioBuffers.count))", category: "STT")

        guard !audioBuffers.isEmpty, let format = recordingFormat else { return nil }
        return convertToWAV(buffers: audioBuffers, format: format)
    }

    // MARK: - AudioBufferConsumer

    func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard isRecording else { return }

        // 存儲 buffer 副本
        if let copy = buffer.copy() as? AVAudioPCMBuffer {
            audioBuffers.append(copy)
        }

        // RMS 計算
        guard let rms = AudioUtils.rms(from: buffer) else { return }
        let displayLevel = AudioUtils.normalizedLevel(rms: rms, multiplier: 5.0 * micGain)
        let rawLevel = AudioUtils.normalizedLevel(rms: rms)

        DispatchQueue.main.async { [weak self] in
            self?.audioLevel = displayLevel
        }

        // 靜音偵測
        silenceDetector.update(rawLevel: rawLevel)
    }

    // MARK: - Whisper API

    func transcribe(audioData: Data, model: String = "whisper-1", language: String? = "zh") async throws -> String {
        guard let apiKey = KeychainHelper.loadAPIKey(for: "whisper_api"), !apiKey.isEmpty else {
            throw WhisperError.noAPIKey
        }

        let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
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
        log.info("Whisper API 轉錄結果: \(result.text.prefix(100))", category: "STT")
        return result.text
    }

    /// Quick API key validation
    func testConnection() async throws {
        guard let apiKey = KeychainHelper.loadAPIKey(for: "whisper_api"), !apiKey.isEmpty else {
            throw WhisperError.noAPIKey
        }

        // Send a minimal request to validate the key
        let url = URL(string: "https://api.openai.com/v1/models")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw WhisperError.invalidResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    // MARK: - WAV Conversion

    private func convertToWAV(buffers: [AVAudioPCMBuffer], format: AVAudioFormat) -> Data? {
        // Target: 16kHz mono 16-bit PCM WAV (optimal for Whisper)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else { return nil }

        guard let converter = AVAudioConverter(from: format, to: targetFormat) else {
            log.error("無法建立音訊格式轉換器", category: "STT")
            return nil
        }

        // Calculate total frame count
        let totalFrames = buffers.reduce(0) { $0 + Int($1.frameLength) }
        let ratio = targetFormat.sampleRate / format.sampleRate
        let estimatedOutputFrames = AVAudioFrameCount(Double(totalFrames) * ratio) + 1024

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: estimatedOutputFrames) else {
            return nil
        }

        var bufferIndex = 0
        var inputBufferOffset: AVAudioFramePosition = 0
        var error: NSError?

        converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
            guard bufferIndex < buffers.count else {
                outStatus.pointee = .endOfStream
                return nil
            }

            let currentBuffer = buffers[bufferIndex]
            let remainingFrames = AVAudioFrameCount(Int(currentBuffer.frameLength) - Int(inputBufferOffset))

            if remainingFrames > 0 {
                outStatus.pointee = .haveData

                let framesToCopy = min(inNumPackets, remainingFrames)
                guard let slice = AVAudioPCMBuffer(pcmFormat: currentBuffer.format, frameCapacity: framesToCopy) else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                slice.frameLength = framesToCopy

                if let srcData = currentBuffer.floatChannelData, let dstData = slice.floatChannelData {
                    for ch in 0..<Int(currentBuffer.format.channelCount) {
                        let src = srcData[ch].advanced(by: Int(inputBufferOffset))
                        dstData[ch].update(from: src, count: Int(framesToCopy))
                    }
                }

                inputBufferOffset += AVAudioFramePosition(framesToCopy)
                if inputBufferOffset >= currentBuffer.frameLength {
                    bufferIndex += 1
                    inputBufferOffset = 0
                }

                return slice
            } else {
                bufferIndex += 1
                inputBufferOffset = 0
                if bufferIndex < buffers.count {
                    outStatus.pointee = .haveData
                    return nil
                } else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
            }
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

//
//  WhisperSTTClient.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/28.
//

import AudioToolbox
import AVFoundation
import Foundation

/// Whisper API STT — 錄音後上傳 OpenAI Whisper API 取得轉錄
@Observable
class WhisperSTTClient {
    var isRecording = false
    var audioLevel: Float = 0.0

    // Silence detection (mirrors SpeechRecognizer logic)
    var onSilenceTimeout: (() -> Void)?
    var silenceTimeoutDuration: TimeInterval = 2.0

    private let audioEngine = AVAudioEngine()
    private var audioBuffers: [AVAudioPCMBuffer] = []
    private var recordingFormat: AVAudioFormat?

    private let silenceThreshold: Float = 0.08
    private let speechThreshold: Float = 0.15
    private let noSpeechTimeout: TimeInterval = 3.0
    private var silenceStartTime: Date?
    private var recordingStartTime: Date?
    private var silenceTimeoutFired = false
    private var hasDetectedSpeech = false
    var micGain: Float = 2.0

    private let log = AppLogger.shared

    // MARK: - Recording

    func startRecording(inputDeviceUID: String? = nil) throws {
        audioBuffers = []
        silenceStartTime = nil
        recordingStartTime = Date()
        silenceTimeoutFired = false
        hasDetectedSpeech = false

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)

        // Set specific input device if requested
        if let uid = inputDeviceUID, !uid.isEmpty,
           let deviceID = AudioSessionManager.deviceID(forUID: uid),
           let audioUnit = inputNode.audioUnit
        {
            var devID = deviceID
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        let format = inputNode.outputFormat(forBus: 0)
        let tapFormat = format.channelCount > 0 ? format : nil
        recordingFormat = tapFormat ?? format

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            guard let self, self.isRecording else { return }

            // Store audio buffer for later upload
            if let copy = buffer.copy() as? AVAudioPCMBuffer {
                self.audioBuffers.append(copy)
            }

            // Calculate audio level (RMS)
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<frameLength {
                sum += channelData[i] * channelData[i]
            }
            let rms = sqrtf(sum / Float(frameLength))
            let gain = self.micGain
            let displayLevel = max(0, min(1, rms * 5 * gain))
            let rawLevel = max(0, min(1, rms * 5))

            DispatchQueue.main.async {
                self.audioLevel = displayLevel
            }

            // Silence detection using rawLevel (unaffected by gain)
            if rawLevel >= self.speechThreshold {
                self.hasDetectedSpeech = true
                self.silenceStartTime = nil
                self.silenceTimeoutFired = false
            } else if self.hasDetectedSpeech, rawLevel < self.silenceThreshold {
                if self.silenceStartTime == nil {
                    self.silenceStartTime = Date()
                }
                if let start = self.silenceStartTime,
                   Date().timeIntervalSince(start) >= self.silenceTimeoutDuration,
                   !self.silenceTimeoutFired
                {
                    self.silenceTimeoutFired = true
                    DispatchQueue.main.async {
                        self.onSilenceTimeout?()
                    }
                }
            } else if !self.hasDetectedSpeech, rawLevel < self.silenceThreshold {
                if let recStart = self.recordingStartTime,
                   Date().timeIntervalSince(recStart) >= self.noSpeechTimeout,
                   !self.silenceTimeoutFired
                {
                    self.silenceTimeoutFired = true
                    DispatchQueue.main.async {
                        self.onSilenceTimeout?()
                    }
                }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true
        log.info("WhisperSTTClient 開始錄音", category: "STT")
    }

    func stopRecording() -> Data? {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRecording = false
        silenceStartTime = nil
        recordingStartTime = nil
        silenceTimeoutFired = false
        onSilenceTimeout = nil
        audioLevel = 0.0
        log.info("WhisperSTTClient 停止錄音 (buffers=\(audioBuffers.count))", category: "STT")

        guard !audioBuffers.isEmpty, let format = recordingFormat else { return nil }
        return convertToWAV(buffers: audioBuffers, format: format)
    }

    // MARK: - Whisper API

    func transcribe(audioData: Data, model: String = "whisper-1", language: String = "zh") async throws -> String {
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
        // language field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(language)\r\n".data(using: .utf8)!)
        // response_format field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("json\r\n".data(using: .utf8)!)
        // closing boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        log.info("Whisper API 請求 (model=\(model), language=\(language), audioSize=\(audioData.count) bytes)", category: "STT")

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
        self.append(bufferPointer.baseAddress!, count: bufferPointer.count)
    }
}

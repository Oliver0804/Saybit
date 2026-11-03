//
//  SherpaOnnx.swift
//  speakertpyer + SaybitiOS
//
//  sherpa-onnx C API 的最小 Swift 封裝：SenseVoice 離線辨識 + Silero VAD。
//  兩個類別都不是 thread-safe，只能在同一條 serial queue 上使用（見 SherpaSTTEngine）。
//

import Foundation

/// C 字串在 Create* 呼叫期間必須有效；用 strdup 保存、呼叫後一次釋放。
nonisolated private final class CStrings {
    private var pointers: [UnsafeMutablePointer<CChar>] = []

    func make(_ s: String) -> UnsafePointer<CChar> {
        let p = strdup(s)!
        pointers.append(p)
        return UnsafePointer(p)
    }

    deinit { pointers.forEach { free($0) } }
}

// MARK: - Offline Recognizer (SenseVoice)

nonisolated final class SherpaOfflineRecognizer {
    static let sampleRate: Int32 = 16_000
    private let recognizer: OpaquePointer

    /// - Parameter language: SenseVoice 語言提示：auto / zh / en / ja / ko / yue
    init?(modelPath: String, tokensPath: String, language: String = "auto", numThreads: Int32 = 2) {
        let strings = CStrings()
        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = Self.sampleRate
        config.feat_config.feature_dim = 80
        config.model_config.sense_voice.model = strings.make(modelPath)
        config.model_config.sense_voice.language = strings.make(language)
        config.model_config.sense_voice.use_itn = 1   // 加標點、數字正規化
        config.model_config.tokens = strings.make(tokensPath)
        config.model_config.num_threads = numThreads
        config.model_config.provider = strings.make("cpu")
        config.model_config.debug = 0
        config.decoding_method = strings.make("greedy_search")

        guard let r = SherpaOnnxCreateOfflineRecognizer(&config) else { return nil }
        recognizer = r
    }

    deinit { SherpaOnnxDestroyOfflineRecognizer(recognizer) }

    func decode(_ samples: ArraySlice<Float>) -> String {
        guard !samples.isEmpty, let stream = SherpaOnnxCreateOfflineStream(recognizer) else { return "" }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        samples.withUnsafeBufferPointer { buf in
            SherpaOnnxAcceptWaveformOffline(stream, Self.sampleRate, buf.baseAddress, Int32(buf.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { return "" }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        guard let text = result.pointee.text else { return "" }
        return String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Voice Activity Detector (Silero)

nonisolated final class SherpaVAD {
    static let windowSize = 512
    private let vad: OpaquePointer

    struct Segment {
        let start: Int
        let samples: [Float]
    }

    init?(modelPath: String, minSilence: Float = 0.5, maxSpeech: Float = 20) {
        let strings = CStrings()
        var config = SherpaOnnxVadModelConfig()
        config.silero_vad.model = strings.make(modelPath)
        config.silero_vad.threshold = 0.5
        config.silero_vad.min_silence_duration = minSilence
        config.silero_vad.min_speech_duration = 0.25
        config.silero_vad.window_size = Int32(Self.windowSize)
        config.silero_vad.max_speech_duration = maxSpeech
        config.sample_rate = SherpaOfflineRecognizer.sampleRate
        config.num_threads = 1
        config.provider = strings.make("cpu")
        config.debug = 0

        guard let v = SherpaOnnxCreateVoiceActivityDetector(&config, 120) else { return nil }
        vad = v
    }

    deinit { SherpaOnnxDestroyVoiceActivityDetector(vad) }

    func accept(_ samples: ArraySlice<Float>) {
        samples.withUnsafeBufferPointer { buf in
            SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, buf.baseAddress, Int32(buf.count))
        }
    }

    var isSpeaking: Bool { SherpaOnnxVoiceActivityDetectorDetected(vad) == 1 }

    /// 取出所有已完成的語音段
    func popSegments() -> [Segment] {
        var out: [Segment] = []
        while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
            if let seg = SherpaOnnxVoiceActivityDetectorFront(vad) {
                let n = Int(seg.pointee.n)
                let samples = Array(UnsafeBufferPointer(start: seg.pointee.samples, count: n))
                out.append(Segment(start: Int(seg.pointee.start), samples: samples))
                SherpaOnnxDestroySpeechSegment(seg)
            }
            SherpaOnnxVoiceActivityDetectorPop(vad)
        }
        return out
    }

    func flush() { SherpaOnnxVoiceActivityDetectorFlush(vad) }
    func reset() { SherpaOnnxVoiceActivityDetectorReset(vad) }
}

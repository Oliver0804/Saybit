//
//  SpeechRecognizer.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import AVFoundation
import Speech

@Observable
class SpeechRecognizer: AudioBufferConsumer {
    let consumerID = "SpeechRecognizer"

    enum RecognizerError: LocalizedError {
        case notAuthorized
        case notAvailable
        case recognitionFailed(Error)

        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "語音辨識未授權"
            case .notAvailable: return "語音辨識不可用"
            case .recognitionFailed(let error): return "辨識失敗: \(error.localizedDescription)"
            }
        }
    }

    var transcript: String = ""
    var isListening: Bool = false
    var error: RecognizerError?
    var audioLevel: Float = 0.0
    var micGain: Float = 2.0

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
    private let audioLevelThrottler = MainThreadThrottler(intervalMs: 50)

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    init(locale: Locale = Locale(identifier: "zh-TW")) {
        speechRecognizer = SFSpeechRecognizer(locale: locale)
    }

    /// 動態切換語言（在 startListening 前呼叫）
    func updateLocale(_ locale: Locale) {
        guard !isListening else { return }
        speechRecognizer = SFSpeechRecognizer(locale: locale)
    }

    func startListening(onDeviceOnly: Bool = true) throws {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw RecognizerError.notAuthorized
        }

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw RecognizerError.notAvailable
        }

        // Cancel any ongoing task
        recognitionTask?.cancel()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // 個人字典的偏好寫法當辨識提示（人名、產品名更容易辨識對）
        request.contextualStrings = DictionaryHints.contextualStrings
        if onDeviceOnly {
            request.requiresOnDeviceRecognition = true
        }
        self.recognitionRequest = request

        // 必須先設定 isListening，否則 pre-buffer 回放時 handleAudioBuffer 會被 guard 擋掉
        isListening = true
        transcript = ""
        silenceDetector.start()
        audioLevelThrottler.reset()

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                self.transcript = result.bestTranscription.formattedString
            }

            if let error {
                self.error = .recognitionFailed(error)
                _ = self.stopListening()
            }

            if result?.isFinal == true {
                _ = self.stopListening()
            }
        }

        // 在 isListening = true 且 recognitionTask 就緒後，才註冊消費者並回放 pre-buffer
        SharedAudioEngine.shared.addConsumer(self, replayPreBuffer: true)
    }

    func stopListening() -> String {
        SharedAudioEngine.shared.removeConsumer(self)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isListening = false
        silenceDetector.reset()
        return transcript
    }

    // MARK: - AudioBufferConsumer

    func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard isListening else { return }

        // 餵給 Speech framework
        recognitionRequest?.append(buffer)

        // RMS 計算
        guard let rms = AudioUtils.rms(from: buffer) else { return }
        let displayLevel = AudioUtils.normalizedLevel(rms: rms, multiplier: 5.0 * micGain)
        let rawLevel = AudioUtils.normalizedLevel(rms: rms)

        // Audio tap 在 render thread；節流到 ~20Hz 後再回 main thread 更新 @Observable
        audioLevelThrottler.dispatch { [weak self] in
            self?.audioLevel = displayLevel
        }

        // 靜音偵測（內部已 thread-safe）
        silenceDetector.update(rawLevel: rawLevel)
    }
}

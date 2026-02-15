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
        if onDeviceOnly {
            request.requiresOnDeviceRecognition = true
        }
        self.recognitionRequest = request

        // 向共享 engine 註冊，回放 pre-buffer 補回開頭語音
        SharedAudioEngine.shared.addConsumer(self, replayPreBuffer: true)

        isListening = true
        transcript = ""
        silenceDetector.start()

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

        DispatchQueue.main.async { [weak self] in
            self?.audioLevel = displayLevel
        }

        // 靜音偵測
        silenceDetector.update(rawLevel: rawLevel)
    }
}

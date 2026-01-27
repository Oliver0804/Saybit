//
//  SpeechRecognizer.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import AudioToolbox
import AVFoundation
import Speech

@Observable
class SpeechRecognizer {
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
    var onSilenceTimeout: (() -> Void)?
    private var silenceStartTime: Date?
    private var recordingStartTime: Date?
    private let silenceThreshold: Float = 0.08
    private let speechThreshold: Float = 0.15
    var silenceTimeoutDuration: TimeInterval = 2.0
    private let noSpeechTimeout: TimeInterval = 3.0
    private var silenceTimeoutFired = false
    private var hasDetectedSpeech = false

    private let speechRecognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    init(locale: Locale = Locale(identifier: "zh-TW")) {
        speechRecognizer = SFSpeechRecognizer(locale: locale)
    }

    func startListening(onDeviceOnly: Bool = true, inputDeviceUID: String? = nil) throws {
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

        let inputNode = audioEngine.inputNode

        // Remove any existing tap
        inputNode.removeTap(onBus: 0)

        // Set specific input device if requested
        if let uid = inputDeviceUID, !uid.isEmpty,
           let deviceID = AudioSessionManager.deviceID(forUID: uid),
           let audioUnit = inputNode.audioUnit {
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

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        let tapFormat = recordingFormat.channelCount > 0 ? recordingFormat : nil

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
            request.append(buffer)

            // Calculate audio level (RMS)
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<frameLength {
                sum += channelData[i] * channelData[i]
            }
            let rms = sqrtf(sum / Float(frameLength))
            let gain = self?.micGain ?? 2.0
            let displayLevel = max(0, min(1, rms * 5 * gain)) // UI display (amplified)
            let rawLevel = max(0, min(1, rms * 5)) // Raw level for silence detection (no gain)
            DispatchQueue.main.async {
                self?.audioLevel = displayLevel
            }

            // Silence detection using rawLevel (unaffected by gain)
            if rawLevel >= self?.speechThreshold ?? 0.15 {
                self?.hasDetectedSpeech = true
                self?.silenceStartTime = nil
                self?.silenceTimeoutFired = false
            } else if self?.hasDetectedSpeech == true,
                      rawLevel < self?.silenceThreshold ?? 0.08 {
                // Speech was detected before, now silence
                if self?.silenceStartTime == nil {
                    self?.silenceStartTime = Date()
                }
                if let start = self?.silenceStartTime,
                   let timeout = self?.silenceTimeoutDuration,
                   Date().timeIntervalSince(start) >= timeout,
                   self?.silenceTimeoutFired == false {
                    self?.silenceTimeoutFired = true
                    DispatchQueue.main.async {
                        self?.onSilenceTimeout?()
                    }
                }
            } else if self?.hasDetectedSpeech == false,
                      rawLevel < self?.silenceThreshold ?? 0.08 {
                // No speech ever detected — auto-cancel after noSpeechTimeout
                if let recStart = self?.recordingStartTime,
                   let noSpeechLimit = self?.noSpeechTimeout,
                   Date().timeIntervalSince(recStart) >= noSpeechLimit,
                   self?.silenceTimeoutFired == false {
                    self?.silenceTimeoutFired = true
                    DispatchQueue.main.async {
                        self?.onSilenceTimeout?()
                    }
                }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()

        isListening = true
        transcript = ""
        silenceStartTime = nil
        recordingStartTime = Date()
        silenceTimeoutFired = false
        hasDetectedSpeech = false

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
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isListening = false
        silenceStartTime = nil
        recordingStartTime = nil
        silenceTimeoutFired = false
        onSilenceTimeout = nil
        return transcript
    }
}

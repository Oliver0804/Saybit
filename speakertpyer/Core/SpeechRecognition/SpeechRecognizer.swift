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
    /// Speech task 在使用者停止「之前」自己結束（isFinal / error，例如超過時長上限、網路錯誤）時呼叫（main）。
    /// 參數為錯誤（isFinal 時為 nil）。consumer 已移除，呼叫端應決定要收尾處理或報錯。
    /// 由使用者呼叫 stopListening / finishListening 造成的結束不會觸發。
    @ObservationIgnored var onSessionEnded: ((Error?) -> Void)?

    @ObservationIgnored private let silenceDetector = SilenceDetector()
    @ObservationIgnored private let audioLevelThrottler = MainThreadThrottler(intervalMs: 50)

    @ObservationIgnored private var speechRecognizer: SFSpeechRecognizer?
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    /// 每次 startListening 遞增；舊 task 的回呼（例如 cancel 造成的 error）比對不符直接忽略
    @ObservationIgnored private var sessionID: UInt64 = 0
    /// finishListening 等待 final 結果中
    @ObservationIgnored private var finalWaiter: CheckedContinuation<Void, Never>?

    /// render thread 讀取的狀態（request 參考 + 是否收音），由 renderLock 保護
    @ObservationIgnored private let renderLock = UnfairLock()
    @ObservationIgnored private var renderRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var renderAccepting = false
    @ObservationIgnored private var renderMicGain: Float = 2.0

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

        // 結束任何進行中的 session（含 finishListening 的等待）
        teardown()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // 個人字典的偏好寫法當辨識提示（人名、產品名更容易辨識對）
        request.contextualStrings = DictionaryHints.contextualStrings
        if onDeviceOnly {
            request.requiresOnDeviceRecognition = true
        }
        self.recognitionRequest = request
        sessionID &+= 1
        let thisSession = sessionID

        // 必須先開放收音，否則 pre-buffer 回放時 handleAudioBuffer 會被 guard 擋掉
        isListening = true
        transcript = ""
        error = nil
        silenceDetector.start()
        audioLevelThrottler.reset()
        let gain = micGain
        renderLock.withLock {
            renderRequest = request
            renderAccepting = true
            renderMicGain = gain
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            // SFSpeechRecognizer 預設在 main OperationQueue 回呼
            guard let self, thisSession == self.sessionID else { return }

            if let result {
                self.transcript = result.bestTranscription.formattedString
            }

            let isFinal = result?.isFinal == true
            guard error != nil || isFinal else { return }
            if let error {
                self.error = .recognitionFailed(error)
            }

            if self.finalWaiter != nil {
                // 使用者已要求停止，正在等 final → 喚醒 finishListening
                self.resumeFinalWaiter()
            } else if self.isListening {
                // task 自己結束（使用者還在講）：收掉 consumer，通知 pipeline 決定怎麼辦
                self.teardown()
                self.onSessionEnded?(error)
            }
        }

        // 在收音開放且 recognitionTask 就緒後，才註冊消費者並回放 pre-buffer
        SharedAudioEngine.shared.addConsumer(self, replayPreBuffer: true)
    }

    /// 立即停止並回傳目前（可能是 partial）的轉錄。取消路徑用；需要完整結果請用 `finishListening`。
    func stopListening() -> String {
        teardown()
        return transcript
    }

    /// 停止收音，送出 endAudio 後等 Speech 給出 final 結果（最多 `timeout` 秒），避免最後一兩個字遺失
    func finishListening(timeout: TimeInterval = 1.0) async -> String {
        guard isListening, recognitionTask != nil else {
            teardown()
            return transcript
        }
        SharedAudioEngine.shared.removeConsumer(self)
        renderLock.withLock {
            renderAccepting = false
            renderRequest = nil
        }
        silenceDetector.reset()
        recognitionRequest?.endAudio()

        let waitingSession = sessionID
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            finalWaiter = cont
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, self.sessionID == waitingSession else { return }
                self.resumeFinalWaiter()
            }
        }
        // 等待期間若已開始新的 session，不要拆掉它
        if sessionID == waitingSession {
            teardown()
        }
        return transcript
    }

    private func resumeFinalWaiter() {
        let waiter = finalWaiter
        finalWaiter = nil
        waiter?.resume()
    }

    /// 移除 consumer、結束 request/task；不觸發 onSessionEnded
    private func teardown() {
        if isListening || recognitionTask != nil {
            SharedAudioEngine.shared.removeConsumer(self)
        }
        renderLock.withLock {
            renderAccepting = false
            renderRequest = nil
        }
        // 先換 sessionID，cancel() 造成的 error 回呼才會被忽略
        sessionID &+= 1
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isListening = false
        silenceDetector.reset()
        resumeFinalWaiter()
    }

    // MARK: - AudioBufferConsumer

    func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        renderLock.lock()
        let accepting = renderAccepting
        let request = renderRequest
        let micGain = renderMicGain
        renderLock.unlock()
        guard accepting else { return }

        // 餵給 Speech framework
        request?.append(buffer)

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

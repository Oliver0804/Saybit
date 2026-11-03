//
//  BackgroundSTTEngine.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/2/15.
//

import AVFoundation
import Speech

/// 持續背景 STT 引擎 — SpeechRecognizer 常駐運行，按快捷鍵時直接截取已辨識文字
///
/// Rolling session 機制（每 50 秒重啟一次）避免 Apple 的 60 秒限制。
/// 僅適用 Apple Speech（SFSpeechRecognizer）。
@Observable
class BackgroundSTTEngine: AudioBufferConsumer {
    let consumerID = "BackgroundSTTEngine"

    private(set) var isRunning = false
    private(set) var isCapturing = false

    /// 當前 session 的即時轉錄（供 UI 顯示）
    private(set) var currentTranscript = ""
    /// 當前 session 的音量（供 UI 顯示）
    private(set) var audioLevel: Float = 0.0

    /// 節流 audio→main 的音量更新（比照 SpeechRecognizer，避免每 21ms 派發一次）
    private let audioLevelThrottler = MainThreadThrottler(intervalMs: 50)

    // MARK: - Speech Recognition

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    /// 遞增，每次 startSession 自增一次；用於在 recognitionTask callback 裡
    /// 判斷當前 callback 是否屬於最新 session，避免舊 session 的 cancellation
    /// 觸發級聯重啟。
    private var sessionID: UInt64 = 0

    // MARK: - Rolling Session

    private var rollingTimer: Task<Void, Never>?
    private let maxSessionDuration: TimeInterval = 50
    private var sessionLocale: Locale = Locale(identifier: "zh-TW")
    private var sessionOnDeviceOnly: Bool = true

    // MARK: - Capture State

    private var captureStartTranscript = ""
    private var capturedSegments: [String] = []

    // MARK: - Silence Detection (for capture mode)

    private let silenceDetector = SilenceDetector()
    var onSilenceTimeout: (() -> Void)? {
        get { silenceDetector.onSilenceTimeout }
        set { silenceDetector.onSilenceTimeout = newValue }
    }
    var silenceTimeoutDuration: TimeInterval {
        get { silenceDetector.silenceTimeoutDuration }
        set { silenceDetector.silenceTimeoutDuration = newValue }
    }

    var micGain: Float = 2.0

    private let log = AppLogger.shared

    // MARK: - Lifecycle

    func start(locale: Locale, onDeviceOnly: Bool) {
        guard !isRunning else { return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            log.error("BackgroundSTT: 語音辨識未授權", category: "BackgroundSTT")
            return
        }

        sessionLocale = locale
        sessionOnDeviceOnly = onDeviceOnly
        isRunning = true

        startSession()
        scheduleRolling()

        SharedAudioEngine.shared.addConsumer(self)
        log.info("BackgroundSTT 啟動 (locale=\(locale.identifier), onDevice=\(onDeviceOnly))", category: "BackgroundSTT")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        isCapturing = false

        rollingTimer?.cancel()
        rollingTimer = nil

        endCurrentSession()
        SharedAudioEngine.shared.removeConsumer(self)

        currentTranscript = ""
        capturedSegments = []
        audioLevel = 0.0
        silenceDetector.reset()

        log.info("BackgroundSTT 已停止", category: "BackgroundSTT")
    }

    /// 動態切換語言
    func updateLocale(_ locale: Locale) {
        guard isRunning, !isCapturing else { return }
        sessionLocale = locale
        // 重啟 session 以套用新語言
        rollSession()
        log.info("BackgroundSTT 切換語言: \(locale.identifier)", category: "BackgroundSTT")
    }

    // MARK: - Capture (用戶按快捷鍵時)

    /// 開始擷取 — 暫停 rolling，保留已辨識文字（用戶可能在按快捷鍵前就開始說話）
    func startCapture() {
        guard isRunning else { return }
        isCapturing = true
        // 不扣除已辨識的文字 — 用戶通常在按快捷鍵前就開始說話，
        // 那些開頭的字已經在 currentTranscript 裡，必須保留
        captureStartTranscript = ""
        capturedSegments = []
        silenceDetector.start()

        // 暫停 rolling timer，讓當前 session 繼續到用戶停止
        rollingTimer?.cancel()
        rollingTimer = nil

        log.info("BackgroundSTT 開始擷取 (currentTranscript=\(currentTranscript.prefix(40)))", category: "BackgroundSTT")
    }

    /// 停止擷取 — 提取新文字，重啟 rolling
    func stopCapture() -> String {
        guard isCapturing else { return "" }
        isCapturing = false
        silenceDetector.reset()
        audioLevel = 0.0

        // 提取擷取期間的文字
        var result: String

        if capturedSegments.isEmpty {
            // 沒有跨 session：直接比較
            result = extractNewText(full: currentTranscript, prefix: captureStartTranscript)
        } else {
            // 有跨 session 的 segments：合併
            capturedSegments.append(currentTranscript)
            result = capturedSegments
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        capturedSegments = []
        captureStartTranscript = ""

        // 重啟 session 和 rolling timer
        endCurrentSession()
        startSession()
        scheduleRolling()

        log.info("BackgroundSTT 擷取完成: \(result.prefix(80))", category: "BackgroundSTT")
        return result
    }

    // MARK: - AudioBufferConsumer

    func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard isRunning else { return }

        // 餵給 Speech framework
        recognitionRequest?.append(buffer)

        // RMS 計算（僅 capture 模式時更新 UI 音量）
        if isCapturing {
            guard let rms = AudioUtils.rms(from: buffer) else { return }
            let displayLevel = AudioUtils.normalizedLevel(rms: rms, multiplier: 5.0 * micGain)
            let rawLevel = AudioUtils.normalizedLevel(rms: rms)

            audioLevelThrottler.dispatch { [weak self] in
                self?.audioLevel = displayLevel
            }

            silenceDetector.update(rawLevel: rawLevel)
        }
    }

    // MARK: - Session Management

    private func startSession() {
        speechRecognizer = SFSpeechRecognizer(locale: sessionLocale)

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            log.error("BackgroundSTT: SFSpeechRecognizer 不可用", category: "BackgroundSTT")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // 個人字典的偏好寫法當辨識提示（人名、產品名更容易辨識對）
        request.contextualStrings = DictionaryHints.contextualStrings
        if sessionOnDeviceOnly {
            request.requiresOnDeviceRecognition = true
        }
        self.recognitionRequest = request

        currentTranscript = ""
        sessionID &+= 1
        let thisSessionID = sessionID

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            // 舊 session 的 callback（被 endCurrentSession 取消後才送達）直接忽略，
            // 避免一個 cancellation 觸發 handleSessionEndDuringCapture → 再取消
            // 下一個 session → 無限級聯
            guard thisSessionID == self.sessionID else { return }

            if let result {
                self.currentTranscript = result.bestTranscription.formattedString
            }

            if let error {
                self.log.error("BackgroundSTT session 錯誤: \(error.localizedDescription)", category: "BackgroundSTT")
                if self.isCapturing {
                    self.handleSessionEndDuringCapture()
                } else if self.isRunning {
                    self.startSession()
                }
                return
            }

            if result?.isFinal == true {
                if self.isCapturing {
                    self.handleSessionEndDuringCapture()
                } else if self.isRunning {
                    self.startSession()
                }
            }
        }
    }

    private func endCurrentSession() {
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    /// Capture 期間 session 超時：保存當前文字並重啟
    private func handleSessionEndDuringCapture() {
        let text = extractNewText(full: currentTranscript, prefix: captureStartTranscript)
        if !text.isEmpty {
            capturedSegments.append(text)
        }
        // 重新啟動 session（capture 繼續）
        captureStartTranscript = ""
        endCurrentSession()
        startSession()
        log.info("BackgroundSTT: Capture 期間 session 重啟 (segments=\(capturedSegments.count))", category: "BackgroundSTT")
    }

    // MARK: - Rolling Timer

    private func scheduleRolling() {
        rollingTimer?.cancel()
        rollingTimer = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(self?.maxSessionDuration ?? 50))
                } catch {
                    return
                }
                await MainActor.run {
                    self?.rollSession()
                }
            }
        }
    }

    private func rollSession() {
        guard isRunning, !isCapturing else { return }

        let oldTranscript = currentTranscript
        endCurrentSession()
        startSession()

        if !oldTranscript.isEmpty {
            log.debug("BackgroundSTT session roll (prev=\(oldTranscript.prefix(40)))", category: "BackgroundSTT")
        }
    }

    // MARK: - Text Extraction

    /// 從完整 transcript 中提取 capture 後新增的部分
    private func extractNewText(full: String, prefix: String) -> String {
        guard !prefix.isEmpty else { return full }
        // Apple STT 的 partial results 可能會重新格式化前綴
        // 嘗試精確前綴匹配
        if full.hasPrefix(prefix) {
            let newPart = String(full.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
            return newPart
        }
        // 前綴不匹配（STT 重新格式化了），回傳整個 transcript
        return full
    }
}

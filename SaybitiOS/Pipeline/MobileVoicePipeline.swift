//
//  MobileVoicePipeline.swift
//  SaybitiOS
//
//  iOS 版流程協調器（對應 macOS 的 VoicePipeline）：
//    錄音（SharedAudioEngine + Apple Speech / Whisper）→ TextRefiner（共用 LLM 核心）
//    → 結果：App 內顯示 + 自動複製；若由鍵盤發起則透過 KeyboardBridge 回傳給鍵盤插字。
//

import Foundation
import Observation
import Speech
import UIKit

@Observable
final class MobileVoicePipeline {
    enum Source: String {
        case app
        case keyboard
        case shortcut
    }

    let session = TranscriptionSession()
    let keyboardSession = KeyboardSessionController()
    private(set) var source: Source = .app
    /// 非錯誤的提示（自動停止錄音、被中斷等），顯示在主畫面，使用者可關閉
    private(set) var notice: String?

    /// 單次錄音最長時間；到了自動停止並送出處理（避免忘記停止、記憶體無上限成長）
    @ObservationIgnored var maxRecordingDuration: TimeInterval = 5 * 60
    /// 鍵盤待命中錄完後，閒置多久釋放離線模型
    @ObservationIgnored private let modelIdleUnloadDelay: Duration = .seconds(60)

    @ObservationIgnored let settingsStore: SettingsStore
    @ObservationIgnored let mobileSettings: MobileSettings
    @ObservationIgnored private let speechRecognizer = SpeechRecognizer()
    @ObservationIgnored private let whisperClient = WhisperSTTClient()
    @ObservationIgnored private let sherpaEngine = SherpaSTTEngine()
    @ObservationIgnored private let refiner: TextRefiner
    @ObservationIgnored private let records = RecordsRepository()
    @ObservationIgnored private let bridge = KeyboardBridge.shared
    @ObservationIgnored private let log = AppLogger.shared

    @ObservationIgnored private var transcriptObserveTask: Task<Void, Never>?
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var lastHandledCommandID: String?
    @ObservationIgnored private var commandObserver: UUID?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var maxDurationTask: Task<Void, Never>?
    @ObservationIgnored private var modelUnloadTask: Task<Void, Never>?
    /// 目前等待確認的行事曆 / 提醒動作；確認完成時比對，避免套用到之後的新結果
    @ObservationIgnored private var pendingActionID: UUID?
    /// 錄音時使用者在鍵盤選取的文字（edit 模式：翻譯 / 改寫選取內容）
    @ObservationIgnored private var selectedText: String?

    init(settingsStore: SettingsStore, mobileSettings: MobileSettings) {
        self.settingsStore = settingsStore
        self.mobileSettings = mobileSettings
        self.refiner = TextRefiner(settingsStore: settingsStore)

        SharedAudioEngine.shared.setEchoCancellationEnabled(settingsStore.enableEchoCancellation)
        SharedAudioEngine.shared.setVoiceBandpassEnabled(settingsStore.enableVoiceBandpass)

        keyboardSession.isBusy = { [weak self] in self?.isBusy ?? false }

        // 冷啟動時把既有指令視為已處理，避免執行鍵盤很久以前送的指令
        lastHandledCommandID = bridge.currentCommandID()
        commandObserver = DarwinNotificationCenter.shared.addObserver(KeyboardBridge.Notify.command) { [weak self] in
            MainActor.assumeIsolated { self?.handleBridgeCommand() }
        }
        SharedAudioEngine.shared.onInterruptionBegan = { [weak self] in
            self?.handleAudioInterruption()
        }
    }

    var isBusy: Bool {
        switch session.state {
        case .recording, .processing: return true
        default: return false
        }
    }

    var isRecording: Bool {
        if case .recording = session.state { return true }
        return false
    }

    // MARK: - Keyboard Bridge

    private func handleBridgeCommand() {
        guard let (command, selected) = bridge.takeCommand(lastHandledID: &lastHandledCommandID) else { return }
        log.info("收到鍵盤指令: \(command.rawValue)", category: "Bridge")
        switch command {
        case .start:
            startRecording(source: .keyboard, selectedText: selected)
        case .stop:
            stopRecordingAndProcess()
        case .cancel:
            cancel()
        }
    }

    /// 由 `saybit://dictate?source=keyboard` 冷 / 熱啟動。
    /// URL 任何 App 都能開，所以只有在鍵盤最近 5 秒內確實送過 start 指令時，
    /// 才開背景待命 + 以鍵盤來源錄音；否則當一般 dictate（前景錄音、不開待命）。
    func handleKeyboardLaunch() {
        guard let start = bridge.takeRecentStartCommand(within: 5) else {
            log.info("source=keyboard 但沒有近期的鍵盤指令，改為一般口述", category: "Bridge")
            if !isBusy { startRecording(source: .app) }
            return
        }
        // 標記為已處理，避免 Darwin 通知再觸發一次
        lastHandledCommandID = start.id
        keyboardSession.activate(minutes: mobileSettings.keyboardSessionMinutes)
        if !isBusy {
            startRecording(source: .keyboard, selectedText: start.selectedText)
        }
    }

    // MARK: - Recording

    func toggleRecording(source: Source = .app) {
        if isRecording {
            stopRecordingAndProcess()
        } else if !isBusy {
            startRecording(source: source)
        }
    }

    func startRecording(source: Source, selectedText: String? = nil) {
        guard !isBusy else { return }
        processingTask?.cancel()
        modelUnloadTask?.cancel()
        pendingActionID = nil
        notice = nil
        self.source = source
        self.selectedText = selectedText

        // ── 前置檢查 ──
        let provider = settingsStore.selectedProvider
        if provider.requiresAPIKey, KeychainHelper.loadAPIKey(for: provider.id) == nil {
            fail(L10n.Errors.noAPIKey(provider.name))
            return
        }
        if settingsStore.sttEngine == .whisperAPI,
           (KeychainHelper.loadAPIKey(for: "whisper_api") ?? "").isEmpty {
            fail(L10n.Errors.noWhisperKey)
            return
        }
        if settingsStore.sttEngine == .sherpaSenseVoice, !SherpaModelManager.shared.isInstalled {
            fail(SherpaSTTError.modelMissing.localizedDescription)
            return
        }
        guard AudioSessionManager.isMicrophoneAuthorized else {
            fail("尚未允許麥克風權限，請到「設定 › Saybit」開啟")
            return
        }

        // ── 啟動 audio engine（鍵盤 session 期間已在運行）──
        SharedAudioEngine.shared.start()
        guard SharedAudioEngine.shared.isRunning else {
            fail("無法啟動麥克風，請確認沒有其他 App 正在通話或錄音")
            return
        }

        DictionaryHints.refresh(records: records)
        session.reset()
        session.appContext = AppContext(
            appName: source == .keyboard ? "iOS 鍵盤" : "Saybit",
            bundleIdentifier: nil,
            selectedText: selectedText
        )
        session.state = .recording
        session.startTime = Date()

        let micGain = Float(settingsStore.micSensitivity)
        do {
            switch settingsStore.sttEngine {
            case .appleSpeech:
                speechRecognizer.micGain = micGain
                speechRecognizer.updateLocale(Locale(identifier: settingsStore.languagePreference))
                try speechRecognizer.startListening(onDeviceOnly: settingsStore.enableOnDeviceSTT)
            case .whisperAPI:
                whisperClient.micGain = micGain
                try whisperClient.startRecording()
            case .sherpaSenseVoice:
                sherpaEngine.micGain = micGain
                try sherpaEngine.startListening(languagePreference: settingsStore.languagePreference)
            }
        } catch {
            log.error("語音辨識啟動失敗: \(error.localizedDescription)", category: "STT")
            fail(error.localizedDescription)
            return
        }

        log.info("iOS 開始錄音 (source=\(source.rawValue), engine=\(settingsStore.sttEngine.rawValue))", category: "STT")
        enableSilenceAutoStop()
        scheduleMaxDurationStop()
        playFeedback(.start)
        if source == .keyboard {
            bridge.publish(state: .recording, partial: "")
            keyboardSession.touch(minutes: mobileSettings.keyboardSessionMinutes)
        }
        observeTranscript()
    }

    private func enableSilenceAutoStop() {
        let handler: (() -> Void)? = settingsStore.enableAutoStop ? { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.isRecording else { return }
                self.log.info("靜音偵測觸發自動停止", category: "Pipeline")
                self.stopRecordingAndProcess()
            }
        } : nil
        switch settingsStore.sttEngine {
        case .appleSpeech:
            speechRecognizer.silenceTimeoutDuration = settingsStore.silenceTimeout
            speechRecognizer.onSilenceTimeout = handler
        case .whisperAPI:
            whisperClient.silenceTimeoutDuration = settingsStore.silenceTimeout
            whisperClient.onSilenceTimeout = handler
        case .sherpaSenseVoice:
            sherpaEngine.silenceTimeoutDuration = settingsStore.silenceTimeout
            sherpaEngine.onSilenceTimeout = handler
        }
    }

    private func scheduleMaxDurationStop() {
        maxDurationTask?.cancel()
        let limit = maxRecordingDuration
        guard limit > 0 else { return }
        let startedAt = session.startTime
        maxDurationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard let self, !Task.isCancelled, self.isRecording, self.session.startTime == startedAt else { return }
            self.log.info("錄音達上限 \(Int(limit))s，自動停止", category: "Pipeline")
            self.notice = "已錄音 \(Int(limit / 60)) 分鐘，自動停止並開始整理。"
            self.stopRecordingAndProcess()
        }
    }

    /// 來電 / Siri 等中斷音訊 session：engine 已停，把中斷前的內容先送處理
    private func handleAudioInterruption() {
        guard isRecording else { return }
        log.info("錄音被系統中斷，處理中斷前的內容", category: "Pipeline")
        notice = "錄音被來電或其他 App 中斷，已先整理中斷前的內容。"
        stopRecordingAndProcess()
    }

    func clearNotice() {
        notice = nil
    }

    /// 日誌只記長度與開頭片段，不落盤完整口述內容
    private static func logSnippet(_ text: String) -> String {
        guard !text.isEmpty else { return "(空)" }
        return text.count > 20 ? "\(text.count) 字「\(text.prefix(20))…」" : "\(text.count) 字「\(text)」"
    }

    private func observeTranscript() {
        transcriptObserveTask?.cancel()
        transcriptObserveTask = Task { @MainActor [weak self] in
            var tick = 0
            while let self, self.isRecording, !Task.isCancelled {
                let (t, lv): (String, Float) = switch self.settingsStore.sttEngine {
                case .appleSpeech: (self.speechRecognizer.transcript, self.speechRecognizer.audioLevel)
                case .whisperAPI: (self.session.rawTranscript, self.whisperClient.audioLevel)
                case .sherpaSenseVoice: (self.sherpaEngine.transcript, self.sherpaEngine.audioLevel)
                }
                if self.session.rawTranscript != t { self.session.rawTranscript = t }
                if self.session.audioLevel != lv { self.session.audioLevel = lv }
                // 鍵盤端 ~3Hz 更新即可，降低跨 process / 落盤寫入
                tick += 1
                if self.source == .keyboard, tick % 6 == 0 {
                    self.bridge.publish(partial: t, level: lv)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func stopRecordingAndProcess() {
        guard isRecording else { return }
        transcriptObserveTask?.cancel()
        maxDurationTask?.cancel()
        session.endTime = Date()
        session.audioLevel = 0
        playFeedback(.stop)
        beginBackgroundWork()

        switch settingsStore.sttEngine {
        case .appleSpeech:
            let transcript = speechRecognizer.stopListening()
            session.rawTranscript = transcript
            log.info("錄音結束 (\(String(format: "%.1f", session.duration))s): \(Self.logSnippet(transcript))", category: "STT")
            guard !transcript.isEmpty else {
                finishEmpty()
                return
            }
            process()

        case .whisperAPI:
            let audio = whisperClient.stopRecording()
            guard let audio, !audio.isEmpty else {
                finishEmpty()
                return
            }
            setProcessing()
            processingTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let lang: String? = self.settingsStore.enableAutoLanguageDetection
                        ? nil : Self.whisperLanguageCode(self.settingsStore.languagePreference)
                    let transcript = try await self.whisperClient.transcribe(
                        audioData: audio, model: self.settingsStore.whisperModel, language: lang
                    )
                    guard !Task.isCancelled else { return }
                    self.log.info("Whisper 轉錄完成: \(Self.logSnippet(transcript))", category: "STT")
                    guard !transcript.isEmpty else {
                        self.finishEmpty()
                        return
                    }
                    self.session.rawTranscript = transcript
                    self.process()
                } catch {
                    // 使用者取消：URLSession 拋的是 URLError(.cancelled)，不是 CancellationError
                    if Task.isCancelled || Self.isCancellation(error) { return }
                    self.fail(error.localizedDescription)
                }
            }

        case .sherpaSenseVoice:
            // 收尾只剩最後一句要辨識（通常 <0.3 秒），期間顯示「處理中」
            setProcessing()
            processingTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let transcript = try await self.sherpaEngine.stopListening()
                    guard !Task.isCancelled else { return }
                    self.session.rawTranscript = transcript
                    self.log.info("錄音結束 (\(String(format: "%.1f", self.session.duration))s): \(Self.logSnippet(transcript))", category: "STT")
                    guard !transcript.isEmpty else {
                        self.finishEmpty()
                        return
                    }
                    self.process()
                } catch {
                    if Task.isCancelled || Self.isCancellation(error) { return }
                    self.fail(error.localizedDescription)
                }
            }
        }
    }

    /// 取消錄音 / 處理，不產生結果
    func cancel() {
        transcriptObserveTask?.cancel()
        maxDurationTask?.cancel()
        processingTask?.cancel()
        pendingActionID = nil
        if isRecording {
            switch settingsStore.sttEngine {
            case .appleSpeech: _ = speechRecognizer.stopListening()
            case .whisperAPI: _ = whisperClient.stopRecording()
            case .sherpaSenseVoice: sherpaEngine.cancel()
            }
        }
        session.reset()
        playFeedback(.cancel)
        if source == .keyboard {
            bridge.clearContent()
            bridge.publish(state: .idle, partial: "")
        }
        releaseEngineIfIdle()
        endBackgroundWork()
    }

    // MARK: - LLM

    private func setProcessing() {
        session.state = .processing
        if source == .keyboard { bridge.publish(state: .processing) }
    }

    private func process() {
        setProcessing()
        session.modelName = settingsStore.selectedModel
        let request = RefineRequest(
            transcript: session.rawTranscript,
            selectedText: selectedText,
            contextIdentifier: ""
        )
        processingTask = Task { @MainActor [weak self] in
            await self?.runRefine(request)
        }
    }

    private func runRefine(_ request: RefineRequest) async {
        do {
            let outcome = try await refiner.refine(
                request,
                onPartial: { [weak self] text in
                    guard let self else { return }
                    self.session.processedText = text
                },
                onUsage: { [weak self] usage in
                    self?.session.promptTokens = usage.promptTokens
                    self?.session.completionTokens = usage.completionTokens
                    self?.session.totalTokens = usage.totalTokens
                }
            )
            guard !Task.isCancelled else { return }
            switch outcome {
            case .text(let text):
                finish(with: text)
            case .action(let action, let confirmation):
                session.processedText = confirmation
                session.pendingAction = action
                pendingActionID = UUID()
                session.state = .previewing
                if source == .keyboard {
                    bridge.publish(state: .error, errorMessage: "行事曆 / 提醒需回到 Saybit App 確認建立")
                }
                endBackgroundWork()
            case .needsSelection(let hint):
                fail(hint)
            }
        } catch {
            // 取消後串流會提早結束（emptyResponse）或拋 URLError(.cancelled)：都不是失敗，
            // 且 session 已被 cancel() 重設，不能再改成 .error
            guard !Task.isCancelled, !Self.isCancellation(error) else { return }
            handleRefineError(error, request: request)
        }
    }

    private func handleRefineError(_ error: Error, request: RefineRequest) {
        switch error {
        case RefinerError.actionFailed(let msg):
            fail(msg)
        case RefinerError.emptyResponse:
            fail(L10n.Errors.llmNoResponse)
        default:
            let msg = TextRefiner.friendlyErrorMessage(error)
            log.error("LLM 錯誤: \(msg) (\(error))", category: "LLM")
            session.lastErrorContext = ErrorContext(
                transcript: request.transcript,
                selectedText: request.selectedText,
                appContext: session.appContext
            )
            fail(msg)
        }
    }

    /// URLError(.cancelled) 只在本 Task 被取消時才算取消（呼叫端已先檢查 Task.isCancelled）；
    /// 其他來源的 .cancelled 仍當失敗，避免 session 卡在「處理中」
    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError
    }

    /// - Parameter publishToKeyboard: false 時不把文字當成鍵盤結果送出（例如行事曆確認文字）
    private func finish(with text: String, publishToKeyboard: Bool = true) {
        session.processedText = text
        session.state = .done
        records.saveTranscription(
            rawTranscript: session.rawTranscript,
            processedText: text,
            appName: session.appContext.appName,
            durationSec: session.duration,
            modelName: session.modelName,
            promptTokens: session.promptTokens,
            completionTokens: session.completionTokens,
            totalTokens: session.totalTokens
        )
        switch source {
        case .keyboard:
            if publishToKeyboard {
                bridge.publish(result: text)
            } else {
                bridge.publish(state: .idle, partial: "")
            }
            keyboardSession.touch(minutes: mobileSettings.keyboardSessionMinutes)
        case .app, .shortcut:
            if mobileSettings.autoCopyResult {
                UIPasteboard.general.string = text
            }
        }
        playFeedback(.success)
        releaseEngineIfIdle()
        endBackgroundWork()
    }

    private func finishEmpty() {
        log.info("轉錄為空，跳過 LLM", category: "Pipeline")
        session.state = .idle
        if source == .keyboard {
            bridge.clearContent()
            bridge.publish(state: .idle, partial: "")
        }
        releaseEngineIfIdle()
        endBackgroundWork()
    }

    private func fail(_ message: String) {
        log.error(message, category: "Pipeline")
        session.state = .error(message)
        if source == .keyboard {
            bridge.clearContent()
            bridge.publish(state: .error, errorMessage: message)
        }
        playFeedback(.failure)
        releaseEngineIfIdle()
        endBackgroundWork()
    }

    // MARK: - User Actions (App UI)

    func retryLastAction() {
        guard let ctx = session.lastErrorContext, !isBusy else { return }
        resetSourceIfKeyboardGone()
        session.rawTranscript = ctx.transcript
        selectedText = ctx.selectedText
        session.lastErrorContext = nil
        beginBackgroundWork()
        process()
    }

    func regenerate() {
        guard !session.rawTranscript.isEmpty, !isBusy else { return }
        resetSourceIfKeyboardGone()
        session.processedText = ""
        beginBackgroundWork()
        process()
    }

    /// App 內重新生成 / 重試：鍵盤待命已結束時，結果不該再送去鍵盤插進當下的輸入框
    private func resetSourceIfKeyboardGone() {
        if source == .keyboard, !keyboardSession.isActive {
            source = .app
        }
    }

    func confirmPendingAction() {
        guard let action = session.pendingAction, let actionID = pendingActionID else { return }
        processingTask?.cancel()
        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.refiner.execute(action)
                guard !Task.isCancelled, self.pendingActionID == actionID else { return }
                self.session.pendingAction = nil
                self.pendingActionID = nil
                // 確認文字不是鍵盤要插入的內容
                self.finish(with: self.session.processedText, publishToKeyboard: false)
            } catch {
                guard !Task.isCancelled, self.pendingActionID == actionID else { return }
                self.session.pendingAction = nil
                self.pendingActionID = nil
                self.fail(error.localizedDescription)
            }
        }
    }

    func dismissResult() {
        pendingActionID = nil
        session.reset()
        if source == .keyboard {
            bridge.clearContent()
            bridge.publish(state: .idle, partial: "")
        }
    }

    // MARK: - Standalone (App Intents)

    /// 不經錄音，直接把一段文字交給 LLM 潤飾（捷徑「用 Saybit 潤飾文字」）
    func refineStandalone(_ text: String) async throws -> String {
        let outcome = try await refiner.refine(
            RefineRequest(transcript: text, selectedText: nil, contextIdentifier: ""),
            onPartial: { _ in },
            onUsage: { _ in }
        )
        switch outcome {
        case .text(let result):
            records.saveTranscription(
                rawTranscript: text, processedText: result, appName: "捷徑",
                durationSec: 0, modelName: settingsStore.selectedModel,
                promptTokens: 0, completionTokens: 0, totalTokens: 0
            )
            return result
        case .action(_, let confirmation):
            return confirmation
        case .needsSelection(let hint):
            throw RefinerError.actionFailed(hint)
        }
    }

    // MARK: - Lifecycle

    /// App 進背景：非鍵盤來源的錄音直接停止並送出處理；沒有鍵盤 session 也沒在忙 → 釋放麥克風
    func sceneDidEnterBackground() {
        if isRecording, source != .keyboard, !keyboardSession.isActive {
            log.info("App 進背景，停止 App 內錄音", category: "Pipeline")
            stopRecordingAndProcess()
            return
        }
        releaseEngineIfIdle()
    }

    private func releaseEngineIfIdle() {
        guard !isBusy else { return }
        if keyboardSession.isActive {
            // 待命中 engine 要保持運行，但離線模型（~250MB）不必常駐：閒置一段時間後釋放
            scheduleModelUnload()
            return
        }
        modelUnloadTask?.cancel()
        SharedAudioEngine.shared.shutdown()
        // 沒在待命就釋放離線模型（~250MB），避免在背景被系統優先回收
        sherpaEngine.unloadModel()
    }

    private func scheduleModelUnload() {
        modelUnloadTask?.cancel()
        let delay = modelIdleUnloadDelay
        modelUnloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, !self.isBusy else { return }
            self.sherpaEngine.unloadModel()
            self.log.info("待命閒置，釋放離線模型", category: "Pipeline")
        }
    }

    /// 處理期間（LLM 網路請求）若 audio engine 已關閉，App 在背景可能被暫停 → 申請背景時間
    private func beginBackgroundWork() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SaybitProcessing") { [weak self] in
            self?.endBackgroundWork()
        }
    }

    private func endBackgroundWork() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func playFeedback(_ event: FeedbackPlayer.Event) {
        FeedbackPlayer.play(
            event,
            sound: settingsStore.enableSoundFeedback,
            haptic: mobileSettings.hapticFeedback
        )
    }

    private static func whisperLanguageCode(_ preference: String) -> String {
        switch preference {
        case "en-US": return "en"
        case "ja-JP": return "ja"
        default: return "zh"
        }
    }
}

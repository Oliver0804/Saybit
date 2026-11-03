//
//  VoicePipeline.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import AppKit
import Combine
import CoreData
import Foundation

@Observable
class VoicePipeline {
    let session = TranscriptionSession()
    let speechRecognizer = SpeechRecognizer()
    let whisperClient = WhisperSTTClient()
    let sherpaEngine = SherpaSTTEngine()

    private let refiner: TextRefiner
    private let settingsStore: SettingsStore
    private let log = AppLogger.shared
    private var overlayConfigured = false
    private var audioLevelMonitor: AudioLevelMonitor?
    private var listeningMonitor: AudioLevelMonitor?
    private var smartSendTask: Task<Void, Never>?
    private var previewAutoConfirmTask: Task<Void, Never>?
    /// 聆聽模式開關（持續偵測，直到使用者點擊關閉）
    private var isListeningModeEnabled = false
    /// 在按下快捷鍵時預先擷取的選取文字與上下文（async Task）
    private var contextCaptureTask: Task<AppContext, Never>?
    /// autoResetState 的可取消 Task，避免多次重置競爭
    private var autoResetTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// 下一次錄音要用的語音模式（模式快捷鍵 / URL scheme 設定）
    private var pendingMode: VoiceMode?
    /// 本次錄音的語音模式（nil = 一般聽寫）
    private(set) var activeMode: VoiceMode?
    /// 錄音開始時並行擷取的螢幕文字（OCR）
    private var screenContextTask: Task<String?, Never>?

    /// 持續背景 STT 引擎（enableContinuousSTT 開啟時啟用）
    private var backgroundSTT: BackgroundSTTEngine?
    /// 標記本次錄音是否使用持續 STT 模式
    private var isUsingContinuousSTT = false

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        self.refiner = TextRefiner(settingsStore: settingsStore)
        log.info("VoicePipeline 初始化", category: "Pipeline")
        log.info("模型: \(settingsStore.selectedModel)", category: "Pipeline")
        log.info("Prompt 風格: \(settingsStore.promptStyle.rawValue)", category: "Pipeline")
        log.info("辨識引擎: \(settingsStore.sttEngine.rawValue)", category: "Pipeline")

        // 先套用回音消除狀態（須在 engine 啟動前設定，才能在首次啟動就生效）
        SharedAudioEngine.shared.setEchoCancellationEnabled(settingsStore.enableEchoCancellation)

        // 啟動全域共享 audio engine（一次性）
        SharedAudioEngine.shared.start(inputDeviceUID: settingsStore.selectedInputDeviceUID)

        // 套用人聲帶通降噪當前設定
        SharedAudioEngine.shared.setVoiceBandpassEnabled(settingsStore.enableVoiceBandpass)

        // 監聽輸入裝置變更
        settingsStore.$selectedInputDeviceUID
            .dropFirst()
            .sink { uid in
                SharedAudioEngine.shared.switchInputDevice(uid: uid)
            }
            .store(in: &cancellables)

        // 監聽降噪開關
        settingsStore.$enableVoiceBandpass
            .dropFirst()
            .sink { enabled in
                SharedAudioEngine.shared.setVoiceBandpassEnabled(enabled)
            }
            .store(in: &cancellables)

        // 監聽回音消除開關
        settingsStore.$enableEchoCancellation
            .dropFirst()
            .sink { enabled in
                SharedAudioEngine.shared.setEchoCancellationEnabled(enabled)
            }
            .store(in: &cancellables)

        DictionaryHints.refresh(records: records)

        SystemAudioDucker.restorePendingIfNeeded()

        // 啟動持續背景 STT（若已啟用且為 Apple Speech）
        if settingsStore.enableContinuousSTT && settingsStore.sttEngine == .appleSpeech {
            startBackgroundSTT()
        }

        // 監聽持續 STT 設定變更
        settingsStore.$enableContinuousSTT
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled && self.settingsStore.sttEngine == .appleSpeech {
                    self.startBackgroundSTT()
                } else {
                    self.stopBackgroundSTT()
                }
            }
            .store(in: &cancellables)

        // 監聽 STT 引擎切換
        settingsStore.$sttEngine
            .dropFirst()
            .sink { [weak self] engine in
                guard let self else { return }
                if engine == .appleSpeech && self.settingsStore.enableContinuousSTT {
                    self.startBackgroundSTT()
                } else {
                    self.stopBackgroundSTT()
                }
                if engine == .sherpaSenseVoice {
                    self.sherpaEngine.preloadModel()
                } else {
                    self.sherpaEngine.unloadModel()
                }
            }
            .store(in: &cancellables)

        // SenseVoice 模型常駐記憶體，按快捷鍵時不用等載入
        if settingsStore.sttEngine == .sherpaSenseVoice {
            sherpaEngine.preloadModel()
        }

        configureOverlay()
        // Show bubble immediately on launch
        OverlayWindowController.shared.show()
    }

    private func configureOverlay() {
        OverlayWindowController.shared.configure(session: session, settingsStore: settingsStore, pipeline: self)
        overlayConfigured = true
    }

    // MARK: - Click to Listen

    func startListening() {
        guard case .idle = session.state else { return }

        isListeningModeEnabled = true
        log.info("進入聆聽模式（持續），等待語音觸發", category: "Pipeline")
        session.state = .listening
        session.audioLevel = 0.0

        let monitor = AudioLevelMonitor()
        monitor.onAudioLevel = { [weak self] level in
            self?.session.audioLevel = level
        }
        monitor.onSpeechDetected = { [weak self] in
            guard let self, case .listening = self.session.state else { return }
            self.log.info("聆聽模式偵測到語音，自動開始錄音", category: "Pipeline")
            self.cleanupListening()
            self.startRecording()
            self.enableSilenceAutoStop()
        }
        monitor.startMonitoring()
        listeningMonitor = monitor

        if settingsStore.enableSoundFeedback {
            NSSound(named: .init("Morse"))?.play()
        }
    }

    func cancelListening() {
        isListeningModeEnabled = false
        if case .listening = session.state {
            log.info("取消聆聽模式", category: "Pipeline")
            cleanupListening()
            session.state = .idle
        }
    }

    private func cleanupListening() {
        listeningMonitor?.stopMonitoring()
        listeningMonitor = nil
    }

    // MARK: - Recording

    func startRecording() {
        // 語音模式只對這一次錄音有效（前置檢查失敗也要清掉，避免殘留到下次）
        activeMode = pendingMode
        pendingMode = nil
        session.modeName = activeMode?.name

        // 取消任何 pending 的 autoReset
        autoResetTask?.cancel()
        autoResetTask = nil

        // 若聆聽中，先清除
        if case .listening = session.state {
            cleanupListening()
        }

        // 若 Smart Send 倒數中，先取消
        if case .confirming = session.state {
            smartSendTask?.cancel()
            cleanupSmartSend()
        }

        // 若預覽中，先取消
        if case .previewing = session.state {
            session.state = .idle
        }

        // Check prerequisites
        let provider = settingsStore.selectedProvider
        if provider.requiresAPIKey, KeychainHelper.loadAPIKey(for: provider.id) == nil {
            log.error("未設定 \(provider.name) API Key", category: "Pipeline")
            session.state = .error(L10n.Errors.noAPIKey(provider.name))
            autoResetState(after: 3.0)
            return
        }

        // Check Whisper API key if using Whisper engine
        if settingsStore.sttEngine == .whisperAPI {
            guard let key = KeychainHelper.loadAPIKey(for: "whisper_api"), !key.isEmpty else {
                log.error("未設定 Whisper API Key", category: "Pipeline")
                session.state = .error(L10n.Errors.noWhisperKey)
                autoResetState(after: 3.0)
                return
            }
        }

        if settingsStore.sttEngine == .sherpaSenseVoice, !SherpaModelManager.shared.isInstalled {
            log.error("SenseVoice 模型未下載", category: "Pipeline")
            session.state = .error(SherpaSTTError.modelMissing.localizedDescription)
            autoResetState(after: 4.0)
            return
        }

        // 在 reset 前非同步預擷取選取文字（錄音期間可能失去選取）
        // 使用 Task 避免阻塞主線程（clipboard fallback 需要等待）
        if let mode = activeMode {
            log.info("語音模式: \(mode.name)", category: "Pipeline")
        }

        // 螢幕上下文：與錄音並行 OCR，LLM 前再取結果
        screenContextTask?.cancel()
        screenContextTask = nil
        if settingsStore.enableScreenContext {
            screenContextTask = Task { await ScreenContextCapture.captureFrontWindowText() }
        }

        contextCaptureTask?.cancel()
        contextCaptureTask = nil
        if settingsStore.enableContextAwareness {
            contextCaptureTask = Task {
                await TextExtractor.getCurrentContext()
            }
        }

        DictionaryHints.refresh(records: records)
        session.reset()
        session.state = .recording
        session.startTime = Date()
        log.info("開始錄音 (engine=\(settingsStore.sttEngine.rawValue))", category: "STT")

        let micGain = Float(settingsStore.micSensitivity)

        // 判斷是否使用持續 STT 模式
        isUsingContinuousSTT = settingsStore.enableContinuousSTT
            && settingsStore.sttEngine == .appleSpeech
            && backgroundSTT?.isRunning == true

        if isUsingContinuousSTT, let bgSTT = backgroundSTT {
            // 持續 STT 模式：背景 STT 已在運行，直接開始擷取
            bgSTT.micGain = micGain
            bgSTT.startCapture()
            log.info("持續 STT 模式：開始擷取 (locale=\(settingsStore.languagePreference))", category: "STT")
        } else {
            // Pre-buffer 模式：啟動新的 STT session
            isUsingContinuousSTT = false
            do {
                switch settingsStore.sttEngine {
                case .appleSpeech:
                    speechRecognizer.micGain = micGain
                    let locale = Locale(identifier: settingsStore.languagePreference)
                    speechRecognizer.updateLocale(locale)
                    try speechRecognizer.startListening(
                        onDeviceOnly: settingsStore.enableOnDeviceSTT
                    )
                    log.info("Apple Speech 啟動 (locale=\(settingsStore.languagePreference), onDevice=\(settingsStore.enableOnDeviceSTT))", category: "STT")
                case .whisperAPI:
                    whisperClient.micGain = micGain
                    try whisperClient.startRecording()
                    log.info("Whisper 錄音啟動", category: "STT")
                case .sherpaSenseVoice:
                    sherpaEngine.micGain = micGain
                    try sherpaEngine.startListening(languagePreference: settingsStore.languagePreference)
                }
            } catch {
                log.error("語音辨識啟動失敗: \(error.localizedDescription)", category: "STT")
                session.state = .error(error.localizedDescription)
                autoResetState(after: 3.0)
                return
            }
        }

        // Play start sound
        if settingsStore.enableSoundFeedback {
            NSSound(named: .init("Tink"))?.play()
        }

        // 錄音中壓低系統音量（等提示音播完再壓）；離開 recording 時由 observeTranscript 還原
        if settingsStore.enableDuckingWhileRecording {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, case .recording = self.session.state else { return }
                SystemAudioDucker.duck()
            }
        }

        // Observe real-time transcript and audio level updates
        observeTranscript()
    }

    func toggleRecording() {
        if case .recording = session.state {
            stopRecordingAndProcess()
        } else {
            startRecording()
            enableSilenceAutoStop()
        }
    }

    /// 取消錄音，不送 AI、不輸入文字
    func cancelRecording() {
        guard case .recording = session.state else { return }
        if isUsingContinuousSTT, let bgSTT = backgroundSTT {
            _ = bgSTT.stopCapture()
            isUsingContinuousSTT = false
        } else {
            switch settingsStore.sttEngine {
            case .appleSpeech: _ = speechRecognizer.stopListening()
            case .whisperAPI: _ = whisperClient.stopRecording()
            case .sherpaSenseVoice: sherpaEngine.cancel()
            }
        }
        screenContextTask?.cancel()
        screenContextTask = nil
        session.audioLevel = 0
        log.info("錄音已取消", category: "Pipeline")
        returnToIdle()
    }

    /// 用指定語音模式切換錄音（模式快捷鍵 / saybit://toggle?mode=…）
    func toggleRecording(mode: VoiceMode?) {
        if case .recording = session.state {
            stopRecordingAndProcess()
        } else {
            pendingMode = mode
            startRecording()
            enableSilenceAutoStop()
        }
    }

    /// 啟用靜音自動停止（listening 觸發和 toggleRecording 共用）
    private func enableSilenceAutoStop() {
        guard settingsStore.enableAutoStop else { return }
        let silenceHandler: () -> Void = { [weak self] in
            DispatchQueue.main.async {
                guard let self, case .recording = self.session.state else { return }
                self.log.info("靜音偵測觸發自動停止 (\(self.settingsStore.silenceTimeout)s)", category: "Pipeline")
                self.stopRecordingAndProcess()
            }
        }

        if isUsingContinuousSTT, let bgSTT = backgroundSTT {
            bgSTT.silenceTimeoutDuration = settingsStore.silenceTimeout
            bgSTT.onSilenceTimeout = silenceHandler
        } else {
            switch settingsStore.sttEngine {
            case .appleSpeech:
                speechRecognizer.silenceTimeoutDuration = settingsStore.silenceTimeout
                speechRecognizer.onSilenceTimeout = silenceHandler
            case .whisperAPI:
                whisperClient.silenceTimeoutDuration = settingsStore.silenceTimeout
                whisperClient.onSilenceTimeout = silenceHandler
            case .sherpaSenseVoice:
                sherpaEngine.silenceTimeoutDuration = settingsStore.silenceTimeout
                sherpaEngine.onSilenceTimeout = silenceHandler
            }
        }
    }

    func stopRecordingAndProcess() {
        guard case .recording = session.state else { return }

        session.endTime = Date()
        session.audioLevel = 0.0

        if isUsingContinuousSTT, let bgSTT = backgroundSTT {
            // 持續 STT 模式：從背景 STT 擷取文字
            let transcript = bgSTT.stopCapture()
            session.rawTranscript = transcript
            isUsingContinuousSTT = false
            log.info("持續 STT 擷取結束 (時長=\(String(format: "%.1f", session.duration))s)", category: "STT")
            log.info("原始轉錄: \(transcript.isEmpty ? "(空)" : transcript)", category: "STT")

            guard !transcript.isEmpty else {
                log.info("轉錄為空，跳過 LLM", category: "Pipeline")
                returnToIdle()
                return
            }

            if settingsStore.enableSoundFeedback {
                NSSound(named: .init("Pop"))?.play()
            }

            proceedToLLM()
            return
        }

        switch settingsStore.sttEngine {
        case .appleSpeech:
            let transcript = speechRecognizer.stopListening()
            session.rawTranscript = transcript
            log.info("錄音結束 (時長=\(String(format: "%.1f", session.duration))s)", category: "STT")
            log.info("原始轉錄: \(transcript.isEmpty ? "(空)" : transcript)", category: "STT")

            guard !transcript.isEmpty else {
                log.info("轉錄為空，跳過 LLM", category: "Pipeline")
                returnToIdle()
                return
            }

            // Play end sound
            if settingsStore.enableSoundFeedback {
                NSSound(named: .init("Pop"))?.play()
            }

            proceedToLLM()

        case .whisperAPI:
            let audioData = whisperClient.stopRecording()
            log.info("錄音結束 (時長=\(String(format: "%.1f", session.duration))s)", category: "STT")

            guard let audioData, !audioData.isEmpty else {
                log.info("錄音資料為空，跳過", category: "Pipeline")
                returnToIdle()
                return
            }

            // Play end sound
            if settingsStore.enableSoundFeedback {
                NSSound(named: .init("Pop"))?.play()
            }

            session.state = .processing

            // Transcribe via Whisper API, then proceed to LLM
            Task { @MainActor in
                do {
                    let whisperLang: String? = settingsStore.enableAutoLanguageDetection
                        ? nil
                        : whisperLanguageCode(from: settingsStore.languagePreference)
                    let transcript = try await whisperClient.transcribe(
                        audioData: audioData,
                        model: settingsStore.whisperModel,
                        language: whisperLang
                    )
                    guard !transcript.isEmpty else {
                        log.info("Whisper 轉錄為空，跳過 LLM", category: "Pipeline")
                        returnToIdle()
                        return
                    }
                    session.rawTranscript = transcript
                    log.info("Whisper 轉錄: \(transcript.prefix(100))", category: "STT")
                    proceedToLLM()
                } catch {
                    let msg = error.localizedDescription
                    log.error("Whisper 轉錄失敗: \(msg)", category: "STT")
                    session.state = .error(msg)
                    autoResetState(after: 3.0)
                }
            }

        case .sherpaSenseVoice:
            if settingsStore.enableSoundFeedback {
                NSSound(named: .init("Pop"))?.play()
            }
            // 收尾只剩最後一句要辨識（通常 <0.3 秒）
            session.state = .processing
            Task { @MainActor in
                do {
                    let transcript = try await sherpaEngine.stopListening()
                    session.rawTranscript = transcript
                    log.info("錄音結束 (時長=\(String(format: "%.1f", session.duration))s)", category: "STT")
                    log.info("原始轉錄: \(transcript.isEmpty ? "(空)" : transcript)", category: "STT")
                    guard !transcript.isEmpty else {
                        log.info("轉錄為空，跳過 LLM", category: "Pipeline")
                        returnToIdle()
                        return
                    }
                    proceedToLLM()
                } catch {
                    let msg = error.localizedDescription
                    log.error("SenseVoice 辨識失敗: \(msg)", category: "STT")
                    session.state = .error(msg)
                    autoResetState(after: 3.0)
                }
            }
        }
    }

    /// 轉錄完成後，進入 LLM 處理
    private func proceedToLLM() {
        session.state = .processing

        Task { @MainActor in
            // 等待預擷取的上下文完成（async clipboard fallback 可能還在進行）
            if settingsStore.enableContextAwareness {
                if let task = contextCaptureTask {
                    session.appContext = await task.value
                    if let text = session.appContext.selectedText {
                        log.info("預擷取選取文字 (\(text.count) 字): \(text.prefix(50))", category: "Context")
                    }
                }
                log.info("App 上下文: \(session.appContext.appName) | 選取文字: \(session.appContext.selectedText?.prefix(50) ?? "(無)")", category: "Context")
            }
            contextCaptureTask = nil

            await processWithLLM()
        }
    }

    // MARK: - Transcript Observation

    private var transcriptObserveTask: Task<Void, Never>?

    private func observeTranscript() {
        transcriptObserveTask?.cancel()
        transcriptObserveTask = Task { @MainActor in
            while case .recording = session.state {
                if Task.isCancelled { break }
                // 去重：值相同不寫，避免不必要的 @Observable change notification
                // 觸發整顆 OverlayView 重繪
                if isUsingContinuousSTT, let bgSTT = backgroundSTT {
                    let t = bgSTT.currentTranscript
                    let lv = bgSTT.audioLevel
                    if session.rawTranscript != t { session.rawTranscript = t }
                    if session.audioLevel != lv { session.audioLevel = lv }
                } else {
                    switch settingsStore.sttEngine {
                    case .appleSpeech:
                        let t = speechRecognizer.transcript
                        let lv = speechRecognizer.audioLevel
                        if session.rawTranscript != t { session.rawTranscript = t }
                        if session.audioLevel != lv { session.audioLevel = lv }
                    case .whisperAPI:
                        // Whisper 不支援 partial results，只更新音量
                        let lv = whisperClient.audioLevel
                        if session.audioLevel != lv { session.audioLevel = lv }
                    case .sherpaSenseVoice:
                        let t = sherpaEngine.transcript
                        let lv = sherpaEngine.audioLevel
                        if session.rawTranscript != t { session.rawTranscript = t }
                        if session.audioLevel != lv { session.audioLevel = lv }
                    }
                }
                // 20Hz 輪詢，對齊 audio level 50ms 節流；
                // 配合去重後 @Observable 寫入次數實際 ≈ 取樣率 / 兩倍 polling 頻
                try? await Task.sleep(for: .milliseconds(50))
            }
            // 離開 recording（停止 / 取消 / 錯誤）→ 還原系統音量
            SystemAudioDucker.restore()
        }
    }

    // MARK: - LLM Processing（共用 TextRefiner）

    @MainActor
    private func processWithLLM() async {
        let transcript = session.rawTranscript
        let selectedText = session.appContext.selectedText
        let screenContext = await screenContextTask?.value
        screenContextTask = nil
        if let screenContext {
            log.info("螢幕上下文 \(screenContext.count) 字", category: "Context")
        }
        let request = RefineRequest(
            transcript: transcript,
            selectedText: selectedText,
            contextIdentifier: session.appContext.contextIdentifier,
            modeInstructions: activeMode?.instructions,
            screenContext: screenContext
        )
        session.modelName = settingsStore.selectedModel

        do {
            let outcome = try await refiner.refine(
                request,
                onPartial: { text in session.processedText = text },
                onUsage: { usage in
                    session.promptTokens = usage.promptTokens
                    session.completionTokens = usage.completionTokens
                    session.totalTokens = usage.totalTokens
                }
            )
            switch outcome {
            case .text(let text):
                session.processedText = text
                if settingsStore.enablePreviewBeforeInject {
                    session.state = .previewing
                    log.info("進入預覽模式，等待使用者確認", category: "Pipeline")
                    startPreviewAutoConfirm()
                } else {
                    performInject()
                }
            case .action(let action, let confirmation):
                session.processedText = confirmation
                session.pendingAction = action
                session.state = .previewing
                startPreviewAutoCancel()
            case .needsSelection(let hint):
                session.processedText = hint
                session.state = .error(hint)
                autoResetState(after: 3.0)
            }
        } catch RefinerError.emptyResponse {
            session.state = .error(L10n.Errors.llmNoResponse)
            autoResetState(after: 3.0)
        } catch RefinerError.actionFailed(let msg) {
            session.state = .error(msg)
            autoResetState(after: 3.0)
        } catch {
            let msg = TextRefiner.friendlyErrorMessage(error)
            log.error("LLM 錯誤: \(msg) (\(error))", category: "LLM")
            session.lastErrorContext = ErrorContext(
                transcript: transcript,
                selectedText: selectedText,
                appContext: session.appContext
            )
            session.state = .error(msg)
            autoResetState(after: 5.0)
        }
    }

    @MainActor
    private func executeAction(_ action: PendingAction) async {
        do {
            try await refiner.execute(action)
            // 建立成功 → 注入確認文字
            session.pendingAction = nil
            performInject()
        } catch {
            session.pendingAction = nil
            let msg = error.localizedDescription
            log.error("Action 執行失敗: \(msg)", category: "Action")
            session.state = .error(msg)
            autoResetState(after: 3.0)
        }
    }

    // MARK: - Quick Retry

    /// 重試上次失敗的 LLM 處理
    func retryLastAction() {
        guard let errorCtx = session.lastErrorContext else { return }
        log.info("Quick Retry: 重新處理上次失敗的請求", category: "Pipeline")

        session.rawTranscript = errorCtx.transcript
        session.appContext = errorCtx.appContext
        session.lastErrorContext = nil
        session.state = .processing

        Task { @MainActor in
            await processWithLLM()
        }
    }

    // MARK: - Preview Actions

    /// 使用者確認注入（預覽模式）
    func confirmInject() {
        guard case .previewing = session.state else { return }
        cancelPreviewAutoConfirm()
        log.info("使用者確認注入", category: "Pipeline")

        if let action = session.pendingAction {
            Task { @MainActor in
                await executeAction(action)
            }
        } else {
            performInject()
        }
    }

    /// 使用者取消（預覽模式）
    func cancelPreview() {
        guard case .previewing = session.state else { return }
        cancelPreviewAutoConfirm()
        log.info("使用者取消預覽", category: "Pipeline")
        returnToIdle()
    }

    /// 使用者要求重新生成（預覽模式）
    func regenerate() {
        guard case .previewing = session.state else { return }
        cancelPreviewAutoConfirm()
        log.info("使用者要求重新生成", category: "Pipeline")
        session.processedText = ""
        session.state = .processing
        Task { @MainActor in
            await processWithLLM()
        }
    }

    /// 預覽模式自動確認（使用 settingsStore.previewTimeout）
    private func startPreviewAutoConfirm() {
        cancelPreviewAutoConfirm()
        let timeout = settingsStore.previewTimeout
        previewAutoConfirmTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch { return }
            guard let self, case .previewing = self.session.state else { return }
            self.log.info("預覽 \(timeout)s 無操作，自動確認", category: "Pipeline")
            self.confirmInject()
        }
    }

    private func cancelPreviewAutoConfirm() {
        previewAutoConfirmTask?.cancel()
        previewAutoConfirmTask = nil
    }

    /// 行事曆/備忘錄預覽自動取消（使用 settingsStore.previewTimeout）
    private func startPreviewAutoCancel() {
        cancelPreviewAutoConfirm()
        let timeout = settingsStore.previewTimeout
        previewAutoConfirmTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch { return }
            guard let self, case .previewing = self.session.state else { return }
            self.log.info("預覽 \(timeout)s 無操作，自動取消", category: "Pipeline")
            self.cancelPreview()
        }
    }

    /// 執行文字注入 + 後續流程（音效、歷史、Smart Send）
    private func performInject() {
        session.state = .done
        let mode = settingsStore.injectionMode
        TextInjector.inject(session.processedText, mode: mode)
        let typingTime = TextInjector.estimatedDuration(session.processedText, mode: mode)
        log.info("文字已注入 (mode=\(mode.rawValue))", category: "Inject")
        if settingsStore.enableAutoLearnDictionary {
            DictionaryAutoLearner.shared.watch(injected: session.processedText, records: records, after: typingTime)
        }

        saveToHistory()

        if settingsStore.enableSoundFeedback {
            NSSound(named: .init("Purr"))?.play()
        }

        if settingsStore.enableSmartSend {
            if typingTime > 0.5 {
                // 逐字輸入還在打：等打完再開始倒數，否則 Enter 會插在文字中間
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(typingTime))
                    guard let self, case .done = self.session.state else { return }
                    self.startSmartSendCountdown()
                }
            } else {
                startSmartSendCountdown()
            }
        } else {
            autoResetState(after: 2.0)
        }
    }

    // MARK: - Smart Send

    private func startSmartSendCountdown() {
        // 取消前一個倒數（防止重複）
        smartSendTask?.cancel()
        cleanupSmartSend()

        let totalSeconds = Int(settingsStore.smartSendDelay)
        log.info("Smart Send 倒數開始 (\(totalSeconds)s)", category: "SmartSend")

        session.state = .confirming(remaining: totalSeconds)

        // 啟動麥克風監聽（grace period 避免完成音效觸發誤取消）
        let monitor = AudioLevelMonitor()
        monitor.onSpeechDetected = { [weak self] in
            self?.cancelSmartSend()
        }
        let grace: TimeInterval = settingsStore.enableSoundFeedback ? 0.8 : 0
        monitor.startMonitoring(gracePeriod: grace)
        self.audioLevelMonitor = monitor

        // 倒數 Task（sleep 在背景執行緒，避免被主執行緒動畫阻塞）
        smartSendTask = Task { [weak self] in
            for secondsLeft in stride(from: totalSeconds - 1, through: 0, by: -1) {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return // Task 被取消
                }

                let shouldContinue: Bool = await MainActor.run {
                    guard let self, case .confirming = self.session.state else { return false }
                    if secondsLeft > 0 {
                        self.session.state = .confirming(remaining: secondsLeft)
                        self.log.debug("Smart Send 倒數: \(secondsLeft)", category: "SmartSend")
                    }
                    return true
                }
                guard shouldContinue else { return }
            }

            // 倒數結束，送出 Enter（第二段 MainActor.run 必須再次檢查 state，
            // 否則倒數結束後若被 cancelSmartSend/startRecording 搶先切換狀態，
            // Enter 還是會被送出）
            let shouldSendEnter: Bool = await MainActor.run {
                guard let self, case .confirming = self.session.state else { return false }
                self.cleanupSmartSend()
                self.log.info("Smart Send 倒數結束，送出 Enter", category: "SmartSend")
                return true
            }
            guard shouldSendEnter else { return }

            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return  // 100ms 之間被取消，放棄送 Enter
            }

            await MainActor.run {
                guard let self, case .confirming = self.session.state else { return }
                TextInjector.simulateEnter()
                self.session.state = .done
                if self.settingsStore.enableSoundFeedback {
                    NSSound(named: .init("Submarine"))?.play()
                }
                self.autoResetState(after: 1.0)
            }
        }
    }

    private func cancelSmartSend() {
        guard case .confirming = session.state else { return }
        log.info("Smart Send 已取消（偵測到說話）", category: "SmartSend")

        smartSendTask?.cancel()
        cleanupSmartSend()

        session.smartSendCancelled = true
        session.state = .done

        if settingsStore.enableSoundFeedback {
            NSSound(named: .init("Basso"))?.play()
        }

        autoResetState(after: 1.5)
    }

    private func cleanupSmartSend() {
        audioLevelMonitor?.stopMonitoring()
        audioLevelMonitor = nil
        smartSendTask = nil
    }

    // MARK: - Helpers

    /// 回到 idle 或自動重新進入聆聽模式
    private func returnToIdle() {
        session.state = .idle
        if isListeningModeEnabled {
            startListening()
        }
    }

    private func autoResetState(after seconds: Double) {
        autoResetTask?.cancel()
        autoResetTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch { return }
            self?.returnToIdle()
        }
    }

    // MARK: - Data Loading

    private let records = RecordsRepository()

    // MARK: - Language Mapping

    private func whisperLanguageCode(from preference: String) -> String {
        switch preference {
        case "zh-TW": return "zh"
        case "en-US": return "en"
        case "ja-JP": return "ja"
        default: return "zh"
        }
    }

    // MARK: - History

    private func saveToHistory() {
        records.saveTranscription(
            rawTranscript: session.rawTranscript,
            processedText: session.processedText,
            appName: session.appContext.appName,
            durationSec: session.duration,
            modelName: session.modelName,
            promptTokens: session.promptTokens,
            completionTokens: session.completionTokens,
            totalTokens: session.totalTokens
        )
    }

    // MARK: - Background STT Management

    private func startBackgroundSTT() {
        guard backgroundSTT == nil else { return }
        let engine = BackgroundSTTEngine()
        let locale = Locale(identifier: settingsStore.languagePreference)
        engine.start(locale: locale, onDeviceOnly: settingsStore.enableOnDeviceSTT)
        backgroundSTT = engine
        log.info("持續背景 STT 已啟動", category: "Pipeline")
    }

    private func stopBackgroundSTT() {
        backgroundSTT?.stop()
        backgroundSTT = nil
        log.info("持續背景 STT 已停止", category: "Pipeline")
    }
}

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
    /// 這次處理有帶螢幕 OCR 文字：輸出可能受畫面上的內容影響，不自動按 Enter 送出
    private var usedScreenContext = false

    /// 持續背景 STT 引擎（enableContinuousSTT 開啟時啟用）
    private var backgroundSTT: BackgroundSTTEngine?

    /// 本次錄音實際啟動的 STT（startRecording 時快照）。
    /// stop / cancel / 靜音停止都只看它，錄音中改設定不會用錯引擎去停。
    private enum ActiveSTT {
        case appleSpeech
        case whisper
        case sherpa
        case continuous(BackgroundSTTEngine)
    }
    private var activeSTT: ActiveSTT?

    /// 每次 startRecording / cancelRecording 遞增。所有收尾 Task、LLM await 之後、串流回呼、
    /// 轉錄輪詢都比對它，不符代表已是舊 session 的結果 → 直接丟棄（避免舊結果覆寫或注入新 session）。
    private var generation = 0
    /// 錄音結束後的收尾（STT 定稿 → LLM → 注入）；cancelRecording / 新 session 時取消
    private var processingTask: Task<Void, Never>?

    /// 錄音開始時的前景 App；注入 / Smart Send 前比對，不一致就改預覽（避免打進錯的 App）
    private var targetPID: pid_t?
    /// 錄音開始時前景 App 的名稱 / bundle ID（未開啟上下文感知時也能判斷是否為終端機）
    private var targetAppContext: AppContext?

    /// 聆聽模式下連續空轉錄次數（噪音觸發）；達上限就停止聆聽，避免無限循環
    private var emptyTranscriptStreak = 0
    private static let maxEmptyTranscriptStreak = 3

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
                // 錄音中改設定：先取消這次錄音，避免停掉正在用的引擎後整段內容遺失
                self.cancelRecordingForSettingChange("持續 STT")
                if enabled && self.settingsStore.sttEngine == .appleSpeech {
                    self.startBackgroundSTT()
                } else {
                    self.stopBackgroundSTT()
                }
            }
            .store(in: &cancellables)

        // 持續 STT 跟著語言 / on-device 設定（擷取中會延後到擷取結束才套用）
        settingsStore.$languagePreference
            .dropFirst()
            .sink { [weak self] lang in
                guard let self else { return }
                self.backgroundSTT?.updateConfiguration(
                    locale: Locale(identifier: lang),
                    onDeviceOnly: self.settingsStore.enableOnDeviceSTT
                )
            }
            .store(in: &cancellables)

        settingsStore.$enableOnDeviceSTT
            .dropFirst()
            .sink { [weak self] onDevice in
                guard let self else { return }
                self.backgroundSTT?.updateConfiguration(
                    locale: Locale(identifier: self.settingsStore.languagePreference),
                    onDeviceOnly: onDevice
                )
            }
            .store(in: &cancellables)

        // 監聽 STT 引擎切換
        settingsStore.$sttEngine
            .dropFirst()
            .sink { [weak self] engine in
                guard let self else { return }
                self.cancelRecordingForSettingChange("辨識引擎")
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

        // 舊 monitor 若還掛在 consumers 上先拆掉，避免永久殘留
        cleanupListening()
        if !isListeningModeEnabled {
            emptyTranscriptStreak = 0
        }
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
        // 錄音中 / 處理中不能開新 session：舊的 LLM 結果會覆寫並注入到新 session，舊 STT 也會變孤兒
        switch session.state {
        case .recording, .processing:
            log.info("忽略開始錄音：目前狀態為 \(session.state)", category: "Pipeline")
            pendingMode = nil
            return
        default:
            break
        }

        // 新 session：讓所有舊的收尾 Task / 回呼失效
        generation += 1
        usedScreenContext = false
        TextInjector.cancelTyping()
        processingTask?.cancel()
        processingTask = nil
        activeSTT = nil

        // 語音模式只對這一次錄音有效（前置檢查失敗也要清掉，避免殘留到下次）
        activeMode = pendingMode
        pendingMode = nil
        session.modeName = activeMode?.name

        // 取消任何 pending 的 autoReset
        autoResetTask?.cancel()
        autoResetTask = nil
        cancelPreviewAutoConfirm()

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

        // Check prerequisites（失敗時 returnToIdle 會從 .error 回來而停止聆聽模式，避免無限循環）
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

        // 麥克風引擎沒在跑（啟動失敗 / 裝置被拔）→ 先試著重啟一次，仍失敗就報錯，不要假裝在錄音
        if !SharedAudioEngine.shared.isRunning {
            log.error("SharedAudioEngine 未運行，嘗試重新啟動", category: "Audio")
            SharedAudioEngine.shared.start(inputDeviceUID: settingsStore.selectedInputDeviceUID)
        }
        guard SharedAudioEngine.shared.isRunning else {
            log.error("麥克風無法啟動，取消錄音", category: "Pipeline")
            session.state = .error("無法啟動麥克風，請檢查輸入裝置與麥克風權限")
            autoResetState(after: 4.0)
            return
        }

        // 記下錄音開始時的前景 App（注入 / Smart Send 前比對）
        let frontApp = NSWorkspace.shared.frontmostApplication
        targetPID = frontApp?.processIdentifier
        targetAppContext = frontApp.map {
            AppContext(appName: $0.localizedName ?? "", bundleIdentifier: $0.bundleIdentifier, selectedText: nil)
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
        let gen = generation

        if settingsStore.enableContinuousSTT,
           settingsStore.sttEngine == .appleSpeech,
           let bgSTT = backgroundSTT, bgSTT.isRunning {
            // 持續 STT 模式：背景 STT 已在運行，直接開始擷取
            bgSTT.updateConfiguration(
                locale: Locale(identifier: settingsStore.languagePreference),
                onDeviceOnly: settingsStore.enableOnDeviceSTT
            )
            bgSTT.micGain = micGain
            bgSTT.startCapture()
            activeSTT = .continuous(bgSTT)
            log.info("持續 STT 模式：開始擷取 (locale=\(settingsStore.languagePreference))", category: "STT")
        } else {
            // Pre-buffer 模式：啟動新的 STT session
            do {
                switch settingsStore.sttEngine {
                case .appleSpeech:
                    speechRecognizer.micGain = micGain
                    let locale = Locale(identifier: settingsStore.languagePreference)
                    speechRecognizer.updateLocale(locale)
                    speechRecognizer.onSessionEnded = { [weak self] error in
                        self?.handleAppleSessionEnded(error: error, generation: gen)
                    }
                    try speechRecognizer.startListening(
                        onDeviceOnly: settingsStore.enableOnDeviceSTT
                    )
                    activeSTT = .appleSpeech
                    log.info("Apple Speech 啟動 (locale=\(settingsStore.languagePreference), onDevice=\(settingsStore.enableOnDeviceSTT))", category: "STT")
                case .whisperAPI:
                    whisperClient.micGain = micGain
                    try whisperClient.startRecording()
                    activeSTT = .whisper
                    log.info("Whisper 錄音啟動", category: "STT")
                case .sherpaSenseVoice:
                    sherpaEngine.micGain = micGain
                    try sherpaEngine.startListening(languagePreference: settingsStore.languagePreference)
                    activeSTT = .sherpa
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

        // 錄音中壓低系統音量（等提示音播完再壓）；離開 recording 時由 endRecordingPhase 還原
        if settingsStore.enableDuckingWhileRecording {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, self.generation == gen, case .recording = self.session.state else { return }
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

    /// 取消錄音 / 處理中的請求，不送 AI、不輸入文字
    func cancelRecording() {
        switch session.state {
        case .recording:
            let stt = activeSTT
            endRecordingPhase()
            switch stt {
            case .appleSpeech: _ = speechRecognizer.stopListening()
            case .whisper: _ = whisperClient.stopRecording()
            case .sherpa: sherpaEngine.cancel()
            case .continuous(let bgSTT): _ = bgSTT.stopCapture()
            case nil: break
            }
            log.info("錄音已取消", category: "Pipeline")
        case .processing:
            // STT 收尾或 LLM 進行中：取消 Task，並以 generation 讓之後回來的結果全部作廢
            log.info("處理中取消", category: "Pipeline")
        default:
            return
        }
        generation += 1
        processingTask?.cancel()
        processingTask = nil
        activeSTT = nil
        TextInjector.cancelTyping()
        screenContextTask?.cancel()
        screenContextTask = nil
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
        session.audioLevel = 0
        returnToIdle()
    }

    /// 設定變更（引擎 / 持續 STT）時若正在錄音，先取消，避免用新設定的引擎去停舊引擎
    private func cancelRecordingForSettingChange(_ what: String) {
        guard case .recording = session.state else { return }
        log.info("錄音中變更\(what)設定，取消本次錄音", category: "Pipeline")
        cancelRecording()
    }

    /// 真正離開 recording 的轉換點：停止轉錄輪詢、還原系統音量
    private func endRecordingPhase() {
        transcriptObserveTask?.cancel()
        transcriptObserveTask = nil
        session.audioLevel = 0
        SystemAudioDucker.restore()
    }

    /// Apple Speech task 在使用者停止前自己結束（時長上限 / 錯誤）
    private func handleAppleSessionEnded(error: Error?, generation gen: Int) {
        guard gen == generation, case .recording = session.state, case .appleSpeech = activeSTT else { return }
        if let error, speechRecognizer.transcript.isEmpty {
            log.error("Apple Speech 提前結束且無內容: \(error.localizedDescription)", category: "STT")
            endRecordingPhase()
            activeSTT = nil
            generation += 1
            session.state = .error(error.localizedDescription)
            autoResetState(after: 3.0)
            return
        }
        log.info("Apple Speech 提前結束（\(error == nil ? "final" : "error")），以目前內容送出", category: "STT")
        stopRecordingAndProcess()
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
        guard settingsStore.enableAutoStop, let stt = activeSTT else { return }
        let gen = generation
        let silenceHandler: () -> Void = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.generation == gen, case .recording = self.session.state else { return }
                self.log.info("靜音偵測觸發自動停止 (\(self.settingsStore.silenceTimeout)s)", category: "Pipeline")
                self.stopRecordingAndProcess()
            }
        }

        switch stt {
        case .continuous(let bgSTT):
            bgSTT.silenceTimeoutDuration = settingsStore.silenceTimeout
            bgSTT.onSilenceTimeout = silenceHandler
        case .appleSpeech:
            speechRecognizer.silenceTimeoutDuration = settingsStore.silenceTimeout
            speechRecognizer.onSilenceTimeout = silenceHandler
        case .whisper:
            whisperClient.silenceTimeoutDuration = settingsStore.silenceTimeout
            whisperClient.onSilenceTimeout = silenceHandler
        case .sherpa:
            sherpaEngine.silenceTimeoutDuration = settingsStore.silenceTimeout
            sherpaEngine.onSilenceTimeout = silenceHandler
        }
    }

    func stopRecordingAndProcess() {
        guard case .recording = session.state, let stt = activeSTT else { return }

        let gen = generation
        session.endTime = Date()
        endRecordingPhase()
        activeSTT = nil
        // 進 processing：STT 定稿（Apple 等 final / Whisper 上傳 / Sherpa 收尾）+ LLM 都在這個 Task 內
        session.state = .processing

        processingTask?.cancel()
        processingTask = Task { @MainActor [weak self] in
            await self?.finishRecording(stt: stt, generation: gen)
        }
    }

    /// 這個收尾仍屬於目前 session（沒被取消、沒開新 session）
    private func isCurrent(_ gen: Int) -> Bool {
        gen == generation && !Task.isCancelled
    }

    /// 日誌只記長度與前 20 字，避免完整聽寫內容落地
    private func logPreview(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "(空)" }
        let head = text.prefix(20)
        return "(\(text.count) 字): \(head)\(text.count > 20 ? "…" : "")"
    }

    @MainActor
    private func finishRecording(stt: ActiveSTT, generation gen: Int) async {
        let duration = String(format: "%.1f", session.duration)
        let transcript: String
        var playedEndSound = false

        switch stt {
        case .continuous(let bgSTT):
            transcript = await bgSTT.stopCapture(waitForFinal: 1.0)
            log.info("持續 STT 擷取結束 (時長=\(duration)s)", category: "STT")

        case .appleSpeech:
            transcript = await speechRecognizer.finishListening(timeout: 1.0)
            log.info("錄音結束 (時長=\(duration)s)", category: "STT")

        case .sherpa:
            if settingsStore.enableSoundFeedback {
                NSSound(named: .init("Pop"))?.play()
            }
            playedEndSound = true
            do {
                // 收尾只剩最後一句要辨識（通常 <0.3 秒）
                transcript = try await sherpaEngine.stopListening()
                log.info("錄音結束 (時長=\(duration)s)", category: "STT")
            } catch {
                guard isCurrent(gen) else { return }
                let msg = error.localizedDescription
                log.error("SenseVoice 辨識失敗: \(msg)", category: "STT")
                session.state = .error(msg)
                autoResetState(after: 3.0)
                return
            }

        case .whisper:
            let audioData = whisperClient.stopRecording()
            log.info("錄音結束 (時長=\(duration)s)", category: "STT")
            guard let audioData, !audioData.isEmpty else {
                log.info("錄音資料為空，跳過", category: "Pipeline")
                handleEmptyTranscript()
                return
            }
            if settingsStore.enableSoundFeedback {
                NSSound(named: .init("Pop"))?.play()
            }
            playedEndSound = true
            do {
                let whisperLang: String? = settingsStore.enableAutoLanguageDetection
                    ? nil
                    : whisperLanguageCode(from: settingsStore.languagePreference)
                transcript = try await whisperClient.transcribe(
                    audioData: audioData,
                    model: settingsStore.whisperModel,
                    language: whisperLang
                )
            } catch {
                // 取消時 URLSession 拋 URLError(.cancelled)，不能當失敗
                guard isCurrent(gen) else { return }
                let msg = error.localizedDescription
                log.error("Whisper 轉錄失敗: \(msg)", category: "STT")
                session.state = .error(msg)
                autoResetState(after: 3.0)
                return
            }
        }

        guard isCurrent(gen) else { return }
        session.rawTranscript = transcript
        log.info("原始轉錄 \(logPreview(transcript))", category: "STT")

        guard !transcript.isEmpty else {
            log.info("轉錄為空，跳過 LLM", category: "Pipeline")
            handleEmptyTranscript()
            return
        }
        emptyTranscriptStreak = 0

        if !playedEndSound, settingsStore.enableSoundFeedback {
            NSSound(named: .init("Pop"))?.play()
        }

        await prepareContextAndRefine(generation: gen)
    }

    /// 空轉錄：一般情況回 idle；聆聽模式下連續多次（噪音觸發）就停止聆聽並提示
    private func handleEmptyTranscript() {
        guard isListeningModeEnabled else {
            returnToIdle()
            return
        }
        emptyTranscriptStreak += 1
        guard emptyTranscriptStreak >= Self.maxEmptyTranscriptStreak else {
            returnToIdle()
            return
        }
        log.info("聆聽模式連續 \(emptyTranscriptStreak) 次空轉錄，停止聆聽", category: "Pipeline")
        isListeningModeEnabled = false
        emptyTranscriptStreak = 0
        session.state = .error("連續多次未辨識到語音，已停止聆聽模式")
        autoResetState(after: 3.0)
    }

    /// 轉錄完成後：等預擷取的上下文（有 timeout），再進 LLM
    @MainActor
    private func prepareContextAndRefine(generation gen: Int) async {
        // 等待預擷取的上下文完成（async clipboard fallback 可能還在進行）；最多等 2 秒
        if settingsStore.enableContextAwareness, let task = contextCaptureTask {
            if let context = await awaitValue(of: task, timeout: 2.0) {
                guard isCurrent(gen) else { return }
                session.appContext = context
                if let text = context.selectedText {
                    log.info("預擷取選取文字 \(logPreview(text))", category: "Context")
                }
            } else {
                guard isCurrent(gen) else { return }
                log.error("上下文擷取逾時（2s），不帶上下文繼續", category: "Context")
            }
            log.info("App 上下文: \(session.appContext.appName) | 選取文字 \(logPreview(session.appContext.selectedText))", category: "Context")
        }
        contextCaptureTask = nil

        await processWithLLM(generation: gen)
    }

    /// 等 task 的結果，最多 `timeout` 秒；逾時回 nil 並 cancel 該 task（不會被不理會取消的 task 卡住）
    @MainActor
    private func awaitValue<T>(of task: Task<T, Never>, timeout: TimeInterval) async -> T? {
        let gate = ResumeGate<T>()
        return await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            gate.continuation = cont
            let timer = Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                if gate.resume(nil) {
                    task.cancel()
                }
            }
            Task { @MainActor in
                let value = await task.value
                if gate.resume(value) {
                    timer.cancel()
                }
            }
        }
    }

    // MARK: - Transcript Observation

    private var transcriptObserveTask: Task<Void, Never>?

    private func observeTranscript() {
        transcriptObserveTask?.cancel()
        guard let stt = activeSTT else { return }
        let gen = generation
        transcriptObserveTask = Task { @MainActor [weak self] in
            while let self, self.generation == gen, case .recording = self.session.state {
                if Task.isCancelled { break }
                let session = self.session
                // 去重：值相同不寫，避免不必要的 @Observable change notification
                // 觸發整顆 OverlayView 重繪
                switch stt {
                case .continuous(let bgSTT):
                    let t = bgSTT.currentTranscript
                    let lv = bgSTT.audioLevel
                    if session.rawTranscript != t { session.rawTranscript = t }
                    if session.audioLevel != lv { session.audioLevel = lv }
                case .appleSpeech:
                    let t = self.speechRecognizer.transcript
                    let lv = self.speechRecognizer.audioLevel
                    if session.rawTranscript != t { session.rawTranscript = t }
                    if session.audioLevel != lv { session.audioLevel = lv }
                case .whisper:
                    // Whisper 不支援 partial results，只更新音量
                    let lv = self.whisperClient.audioLevel
                    if session.audioLevel != lv { session.audioLevel = lv }
                case .sherpa:
                    let t = self.sherpaEngine.transcript
                    let lv = self.sherpaEngine.audioLevel
                    if session.rawTranscript != t { session.rawTranscript = t }
                    if session.audioLevel != lv { session.audioLevel = lv }
                }
                // 20Hz 輪詢，對齊 audio level 50ms 節流；
                // 配合去重後 @Observable 寫入次數實際 ≈ 取樣率 / 兩倍 polling 頻
                try? await Task.sleep(for: .milliseconds(50))
            }
            // 系統音量還原由 endRecordingPhase 負責（真正離開 recording 的地方），
            // 這裡不還原：舊 session 的輪詢結束時新 session 可能已經壓低音量
        }
    }

    // MARK: - LLM Processing（共用 TextRefiner）

    /// 本次輸出目標是否為終端機（貼上換行 = 執行指令）
    private var isTerminalTarget: Bool {
        session.appContext.contextIdentifier == "terminal"
            || targetAppContext?.contextIdentifier == "terminal"
    }

    /// 終端機：去掉尾端換行，避免貼上即執行
    private func sanitizeForTarget(_ text: String) -> String {
        guard isTerminalTarget else { return text }
        var t = text
        while let last = t.last, last.isNewline { t.removeLast() }
        return t
    }

    @MainActor
    private func processWithLLM(generation gen: Int) async {
        let transcript = session.rawTranscript
        let selectedText = session.appContext.selectedText
        var screenContext: String?
        if let task = screenContextTask {
            // OCR 最多等 3 秒，逾時就不帶螢幕上下文
            screenContext = await awaitValue(of: task, timeout: 3.0) ?? nil
            guard isCurrent(gen) else { return }
            if screenContext == nil {
                log.info("螢幕上下文無結果或逾時", category: "Context")
            }
        }
        screenContextTask = nil
        usedScreenContext = screenContext != nil
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
                onPartial: { [weak self] text in
                    guard let self, self.generation == gen else { return }
                    self.session.processedText = text
                },
                onUsage: { [weak self] usage in
                    guard let self, self.generation == gen else { return }
                    self.session.promptTokens = usage.promptTokens
                    self.session.completionTokens = usage.completionTokens
                    self.session.totalTokens = usage.totalTokens
                }
            )
            guard isCurrent(gen) else { return }
            switch outcome {
            case .text(let text):
                session.processedText = sanitizeForTarget(text)
                if isTerminalTarget {
                    // 終端機一律預覽、不自動確認（貼上即執行，必須使用者確認）
                    session.state = .previewing
                    cancelPreviewAutoConfirm()
                    log.info("目標為終端機，強制預覽", category: "Pipeline")
                } else if settingsStore.enablePreviewBeforeInject {
                    session.state = .previewing
                    log.info("進入預覽模式，等待使用者確認", category: "Pipeline")
                    startPreviewAutoConfirm()
                } else {
                    performInject(verifyTarget: true)
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
        } catch is CancellationError {
            // cancelRecording() 已把 generation 往前推並回到 idle，這裡不能再寫 session
            return
        } catch RefinerError.emptyResponse {
            guard isCurrent(gen) else { return }
            session.state = .error(L10n.Errors.llmNoResponse)
            autoResetState(after: 3.0)
        } catch RefinerError.actionFailed(let msg) {
            guard isCurrent(gen) else { return }
            session.state = .error(msg)
            autoResetState(after: 3.0)
        } catch {
            guard isCurrent(gen) else { return }
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
    private func executeAction(_ action: PendingAction, verifyTarget: Bool, generation gen: Int) async {
        do {
            try await refiner.execute(action)
            guard isCurrent(gen) else { return }
            // 建立成功 → 注入確認文字
            session.pendingAction = nil
            performInject(verifyTarget: verifyTarget)
        } catch {
            guard isCurrent(gen) else { return }
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
        switch session.state {
        case .recording, .processing, .listening:
            return
        default:
            break
        }
        log.info("Quick Retry: 重新處理上次失敗的請求", category: "Pipeline")

        // 錯誤狀態排了 autoReset，不取消的話重試途中會被打回 idle
        autoResetTask?.cancel()
        autoResetTask = nil

        session.rawTranscript = errorCtx.transcript
        session.appContext = errorCtx.appContext
        session.lastErrorContext = nil
        session.state = .processing

        startProcessing { pipeline, gen in
            await pipeline.processWithLLM(generation: gen)
        }
    }

    /// 以目前 generation 啟動處理 Task（存進 processingTask，可被 cancelRecording 取消）
    private func startProcessing(_ body: @escaping @MainActor (VoicePipeline, Int) async -> Void) {
        let gen = generation
        processingTask?.cancel()
        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await body(self, gen)
        }
    }

    // MARK: - Preview Actions

    /// 使用者確認注入（預覽模式）。使用者親手確認 → 以目前前景 App 為目標。
    func confirmInject() {
        confirmInject(byUser: true)
    }

    private func confirmInject(byUser: Bool) {
        guard case .previewing = session.state else { return }
        cancelPreviewAutoConfirm()
        log.info(byUser ? "使用者確認注入" : "預覽逾時自動確認", category: "Pipeline")

        if byUser {
            // 使用者看過預覽後親手確認：目標改為目前的前景 App（Smart Send 也以它為準）
            targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        }

        if let action = session.pendingAction {
            // 執行中切到 processing，避免重複確認造成重複建立
            session.state = .processing
            startProcessing { pipeline, gen in
                await pipeline.executeAction(action, verifyTarget: !byUser, generation: gen)
            }
        } else {
            performInject(verifyTarget: !byUser)
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
        autoResetTask?.cancel()
        autoResetTask = nil
        session.processedText = ""
        session.state = .processing
        startProcessing { pipeline, gen in
            await pipeline.processWithLLM(generation: gen)
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
            self.confirmInject(byUser: false)
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

    /// 前景 App 是否仍是錄音開始時的那個（無法判斷時視為不一致）
    private func isFrontmostTarget() -> Bool {
        guard let pid = targetPID else { return true }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    /// 執行文字注入 + 後續流程（音效、歷史、Smart Send）
    /// - Parameter verifyTarget: 注入前比對前景 App；不一致就改進預覽，讓使用者決定（使用者親手確認時為 false）
    private func performInject(verifyTarget: Bool) {
        session.processedText = sanitizeForTarget(session.processedText)

        if verifyTarget, !isFrontmostTarget() {
            let current = NSWorkspace.shared.frontmostApplication?.localizedName ?? "(未知)"
            log.info("前景 App 已變更（目前: \(current)），不自動注入，改為預覽", category: "Inject")
            // 不排自動確認：自動確認會再次比對失敗，只能由使用者確認或取消
            cancelPreviewAutoConfirm()
            session.state = .previewing
            return
        }

        session.state = .done
        let mode = settingsStore.injectionMode
        TextInjector.inject(session.processedText, mode: mode, context: session.appContext)
        let typingTime = TextInjector.estimatedDuration(session.processedText, mode: mode)
        log.info("文字已注入 (mode=\(mode.rawValue))", category: "Inject")
        if settingsStore.enableAutoLearnDictionary {
            DictionaryAutoLearner.shared.watch(injected: session.processedText, records: records, after: typingTime)
        }

        saveToHistory()

        if settingsStore.enableSoundFeedback {
            NSSound(named: .init("Purr"))?.play()
        }

        if settingsStore.enableSmartSend, isTerminalTarget || usedScreenContext {
            // 終端機：Enter 會執行指令；螢幕上下文：輸出可能被畫面上的文字影響（prompt injection），都不自動送出
            log.info(isTerminalTarget ? "目標為終端機，停用 Smart Send" : "本次使用螢幕上下文，停用 Smart Send", category: "SmartSend")
            autoResetState(after: 2.0)
        } else if settingsStore.enableSmartSend {
            if typingTime > 0.5 {
                // 逐字輸入還在打：等打完再開始倒數，否則 Enter 會插在文字中間
                let gen = generation
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(typingTime))
                    guard let self, self.generation == gen, case .done = self.session.state else { return }
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

        let delay = max(0, settingsStore.smartSendDelay)
        // 顯示用整數秒無條件進位（1.5 秒顯示 2 → 1），實際等待時間仍是 delay
        let totalSeconds = Int(delay.rounded(.up))
        log.info("Smart Send 倒數開始 (\(String(format: "%.1f", delay))s)", category: "SmartSend")

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
        let gen = generation
        smartSendTask = Task { [weak self] in
            // 支援小數秒（滑桿 0.5 步進）：第一段先睡掉小數部分，之後每秒更新一次顯示
            var timeLeft = delay
            var secondsLeft = totalSeconds
            while secondsLeft > 0 {
                let step = timeLeft - Double(secondsLeft - 1)
                do {
                    try await Task.sleep(for: .seconds(step))
                } catch {
                    return // Task 被取消
                }
                timeLeft -= step
                secondsLeft -= 1
                let remaining = secondsLeft

                let shouldContinue: Bool = await MainActor.run {
                    guard let self, self.generation == gen, case .confirming = self.session.state else { return false }
                    if remaining > 0 {
                        let secondsLeft = remaining
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
                guard let self, self.generation == gen, case .confirming = self.session.state else { return false }
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
                guard let self, self.generation == gen, case .confirming = self.session.state else { return }
                // 使用者已切到別的 App：Enter 會送進錯的地方（例如把別的對話送出）→ 直接取消
                guard self.isFrontmostTarget() else {
                    let current = NSWorkspace.shared.frontmostApplication?.localizedName ?? "(未知)"
                    self.log.info("Smart Send 取消：前景 App 已變更（目前: \(current)）", category: "SmartSend")
                    self.session.smartSendCancelled = true
                    self.session.state = .done
                    if self.settingsStore.enableSoundFeedback {
                        NSSound(named: .init("Basso"))?.play()
                    }
                    self.autoResetState(after: 1.5)
                    return
                }
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
        let fromError: Bool
        if case .error = session.state { fromError = true } else { fromError = false }
        session.state = .idle
        guard isListeningModeEnabled else { return }
        if fromError {
            // 從錯誤回來（缺 key / 模型未下載 / LLM 失敗…）不要自動重新聆聽，否則會無限 錯誤→聆聽→錯誤
            log.info("發生錯誤，停止聆聽模式", category: "Pipeline")
            isListeningModeEnabled = false
            emptyTranscriptStreak = 0
            return
        }
        startListening()
    }

    private func autoResetState(after seconds: Double) {
        autoResetTask?.cancel()
        let gen = generation
        autoResetTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch { return }
            guard let self, self.generation == gen else { return }
            // 重試 / 重新生成途中不能被舊的 autoReset 打回 idle
            switch self.session.state {
            case .recording, .processing, .listening:
                return
            default:
                self.returnToIdle()
            }
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
        // 引擎可能因 session 無法重開而自行停止，這時丟掉重建
        if let existing = backgroundSTT {
            guard !existing.isRunning else { return }
            backgroundSTT = nil
        }
        let engine = BackgroundSTTEngine()
        let locale = Locale(identifier: settingsStore.languagePreference)
        engine.start(locale: locale, onDeviceOnly: settingsStore.enableOnDeviceSTT)
        guard engine.isRunning else {
            // 未授權 / recognizer 不可用：不保留引擎，錄音時改走一般 Apple Speech
            log.error("持續背景 STT 啟動失敗，改用一般辨識", category: "Pipeline")
            return
        }
        backgroundSTT = engine
        log.info("持續背景 STT 已啟動", category: "Pipeline")
    }

    private func stopBackgroundSTT() {
        backgroundSTT?.stop()
        backgroundSTT = nil
        log.info("持續背景 STT 已停止", category: "Pipeline")
    }
}

/// 只 resume 一次的 continuation 包裝（awaitValue 的 timeout 與結果互搶，皆在 MainActor 上）
private final class ResumeGate<T> {
    var continuation: CheckedContinuation<T?, Never>?

    /// 回傳 true 代表這次呼叫真的 resume 了
    func resume(_ value: T?) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(returning: value)
        return true
    }
}

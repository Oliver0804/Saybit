//
//  VoicePipeline.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import AppKit
import CoreData
import Foundation

@Observable
class VoicePipeline {
    let session = TranscriptionSession()
    let speechRecognizer = SpeechRecognizer()
    let whisperClient = WhisperSTTClient()

    private let llmClient = OpenRouterClient()
    private let settingsStore: SettingsStore
    private let log = AppLogger.shared
    private var overlayConfigured = false
    private var audioLevelMonitor: AudioLevelMonitor?
    private var smartSendTask: Task<Void, Never>?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        log.info("VoicePipeline 初始化", category: "Pipeline")
        log.info("模型: \(settingsStore.selectedModel)", category: "Pipeline")
        log.info("Prompt 風格: \(settingsStore.promptStyle.rawValue)", category: "Pipeline")
        configureOverlay()
        // Show bubble immediately on launch
        OverlayWindowController.shared.show()
    }

    private func configureOverlay() {
        OverlayWindowController.shared.configure(session: session, settingsStore: settingsStore, pipeline: self)
        overlayConfigured = true
    }

    // MARK: - Recording

    func startRecording() {
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

        session.reset()
        session.state = .recording
        session.startTime = Date()
        log.info("開始錄音 (engine=\(settingsStore.sttEngine.rawValue))", category: "STT")

        let micGain = Float(settingsStore.micSensitivity)

        do {
            switch settingsStore.sttEngine {
            case .appleSpeech:
                speechRecognizer.micGain = micGain
                try speechRecognizer.startListening(
                    onDeviceOnly: settingsStore.enableOnDeviceSTT,
                    inputDeviceUID: settingsStore.selectedInputDeviceUID
                )
                log.info("Apple Speech 啟動 (onDevice=\(settingsStore.enableOnDeviceSTT), device=\(settingsStore.selectedInputDeviceUID.isEmpty ? "系統預設" : settingsStore.selectedInputDeviceUID))", category: "STT")
            case .whisperAPI:
                whisperClient.micGain = micGain
                try whisperClient.startRecording(inputDeviceUID: settingsStore.selectedInputDeviceUID)
                log.info("Whisper 錄音啟動 (device=\(settingsStore.selectedInputDeviceUID.isEmpty ? "系統預設" : settingsStore.selectedInputDeviceUID))", category: "STT")
            }
        } catch {
            log.error("語音辨識啟動失敗: \(error.localizedDescription)", category: "STT")
            session.state = .error(error.localizedDescription)
            autoResetState(after: 3.0)
            return
        }

        // Play start sound
        if settingsStore.enableSoundFeedback {
            NSSound(named: .init("Tink"))?.play()
        }

        // Observe real-time transcript and audio level updates
        observeTranscript()
    }

    func toggleRecording() {
        if case .recording = session.state {
            stopRecordingAndProcess()
        } else {
            startRecording()
            // Enable silence detection for auto-stop
            if settingsStore.enableAutoStop {
                let silenceHandler: () -> Void = { [weak self] in
                    DispatchQueue.main.async {
                        guard let self, case .recording = self.session.state else { return }
                        self.log.info("靜音偵測觸發自動停止 (\(self.settingsStore.silenceTimeout)s)", category: "Pipeline")
                        self.stopRecordingAndProcess()
                    }
                }

                switch settingsStore.sttEngine {
                case .appleSpeech:
                    speechRecognizer.silenceTimeoutDuration = settingsStore.silenceTimeout
                    speechRecognizer.onSilenceTimeout = silenceHandler
                case .whisperAPI:
                    whisperClient.silenceTimeoutDuration = settingsStore.silenceTimeout
                    whisperClient.onSilenceTimeout = silenceHandler
                }
            }
        }
    }

    func stopRecordingAndProcess() {
        guard case .recording = session.state else { return }

        session.endTime = Date()
        session.audioLevel = 0.0

        switch settingsStore.sttEngine {
        case .appleSpeech:
            let transcript = speechRecognizer.stopListening()
            session.rawTranscript = transcript
            log.info("錄音結束 (時長=\(String(format: "%.1f", session.duration))s)", category: "STT")
            log.info("原始轉錄: \(transcript.isEmpty ? "(空)" : transcript)", category: "STT")

            guard !transcript.isEmpty else {
                log.info("轉錄為空，跳過 LLM", category: "Pipeline")
                session.state = .idle
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
                session.state = .idle
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
                    let whisperLang = whisperLanguageCode(from: settingsStore.languagePreference)
                    let transcript = try await whisperClient.transcribe(
                        audioData: audioData,
                        model: settingsStore.whisperModel,
                        language: whisperLang
                    )
                    guard !transcript.isEmpty else {
                        log.info("Whisper 轉錄為空，跳過 LLM", category: "Pipeline")
                        session.state = .idle
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
        }
    }

    /// 轉錄完成後，進入 LLM 處理
    private func proceedToLLM() {
        session.state = .processing

        // Get context
        if settingsStore.enableContextAwareness {
            session.appContext = TextExtractor.getCurrentContext()
            log.info("App 上下文: \(session.appContext.appName) | 選取文字: \(session.appContext.selectedText?.prefix(50) ?? "(無)")", category: "Context")
        }

        // Process through LLM
        Task { @MainActor in
            await processWithLLM()
        }
    }

    // MARK: - Transcript Observation

    private func observeTranscript() {
        Task { @MainActor in
            while case .recording = session.state {
                switch settingsStore.sttEngine {
                case .appleSpeech:
                    session.rawTranscript = speechRecognizer.transcript
                    session.audioLevel = speechRecognizer.audioLevel
                case .whisperAPI:
                    // Whisper 不支援 partial results，只更新音量
                    session.audioLevel = whisperClient.audioLevel
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // MARK: - LLM Processing

    @MainActor
    private func processWithLLM() async {
        let style = settingsStore.promptStyle
        var systemPrompt = SystemPrompts.forStyle(style)
        let temperature = SystemPrompts.temperatureForStyle(style)
        let provider = settingsStore.selectedProvider

        log.info("LLM 處理開始 (provider=\(provider.name), model=\(settingsStore.selectedModel), style=\(style.rawValue), temp=\(temperature))", category: "LLM")

        // 語音技能：偵測觸發詞，載入對應 Prompt 指令
        var transcript = session.rawTranscript
        let skills = loadSnippets() ?? [:]
        var activatedSkill: String?

        for (trigger, prompt) in skills {
            if transcript.hasPrefix(trigger) || transcript.contains(trigger) {
                activatedSkill = trigger
                // 從 transcript 移除觸發詞，保留後續內容
                transcript = transcript.replacingOccurrences(of: trigger, with: "").trimmingCharacters(in: .whitespaces)
                // 將技能 Prompt 附加到 system prompt
                systemPrompt += "\n\n## Active Skill: \(trigger)\n\(prompt)\n\nApply the above skill instruction to process the user's voice input."
                log.info("語音技能啟動: \(trigger)", category: "LLM")
                break
            }
        }

        // 如果觸發詞後沒有其他內容，用原始 transcript
        if transcript.isEmpty {
            transcript = session.rawTranscript
        }

        let selectedText = session.appContext.selectedText
        let hasSelectedText = selectedText != nil && !selectedText!.isEmpty

        // 當有選取文字時，強化 system prompt 中的指令模式提示
        if hasSelectedText {
            systemPrompt += """

            \n\n## ⚠️ ACTIVE MODE: Speak-to-Edit
            The user has SELECTED TEXT in their application. The `existing_text` field contains their selection.
            The `transcript` field is their VOICE INSTRUCTION — it tells you what to do with the selected text.

            You MUST:
            1. Treat the transcript as an INSTRUCTION (e.g. "翻譯成英文" = translate to English)
            2. Apply that instruction to the existing_text
            3. Return ONLY the transformed result
            4. Do NOT return the original text unchanged
            5. Do NOT return the instruction itself
            """
        }

        let payload = LLMPayload(
            transcript: transcript,
            context: session.appContext.contextIdentifier.isEmpty ? nil : session.appContext.contextIdentifier,
            mode: hasSelectedText ? "edit" : nil,
            tone: settingsStore.toneStyle == .auto ? nil : settingsStore.toneStyle.rawValue,
            languagePreference: settingsStore.languagePreference,
            personalDictionary: loadPersonalDictionary(),
            snippets: activatedSkill != nil ? nil : skills.isEmpty ? nil : skills,
            screenContext: nil,
            whisperMode: settingsStore.enableWhisperMode ? true : nil,
            existingText: hasSelectedText ? selectedText : nil
        )

        if hasSelectedText {
            log.info("選取文字已傳入 existing_text (\(selectedText!.count) 字), mode=edit", category: "LLM")
        }
        if settingsStore.enableWhisperMode {
            log.info("Whisper Mode 已啟用", category: "LLM")
        }

        var accumulated = ""
        session.modelName = settingsStore.selectedModel

        do {
            let stream = await llmClient.sendStreaming(
                systemPrompt: systemPrompt,
                payload: payload,
                model: settingsStore.selectedModel,
                temperature: temperature,
                provider: provider
            )
            for try await event in stream {
                switch event {
                case .text(let chunk):
                    accumulated += chunk
                    session.processedText = accumulated
                case .usage(let usage):
                    session.promptTokens = usage.promptTokens
                    session.completionTokens = usage.completionTokens
                    session.totalTokens = usage.totalTokens
                }
            }

            guard !accumulated.isEmpty else {
                log.error("LLM 回傳空結果", category: "LLM")
                session.state = .error(L10n.Errors.llmNoResponse)
                autoResetState(after: 3.0)
                return
            }

            log.info("LLM 結果: \(accumulated.prefix(100))\(accumulated.count > 100 ? "..." : "")", category: "LLM")

            if settingsStore.enablePreviewBeforeInject {
                // 預覽模式：等待使用者確認
                session.state = .previewing
                log.info("進入預覽模式，等待使用者確認", category: "Pipeline")
            } else {
                // 直接注入（原有行為）
                performInject()
            }
        } catch {
            let msg = friendlyErrorMessage(error)
            log.error("LLM 錯誤: \(msg) (\(error))", category: "LLM")
            session.state = .error(msg)
            autoResetState(after: 3.0)
        }
    }

    // MARK: - Error Messages

    private func friendlyErrorMessage(_ error: Error) -> String {
        if let clientError = error as? OpenRouterClient.ClientError {
            switch clientError {
            case .noAPIKey(let provider):
                return L10n.Errors.noAPIKey(provider)
            case .invalidResponse(let code):
                switch code {
                case 401: return L10n.Errors.invalidAPIKey
                case 402: return L10n.Errors.insufficientBalance
                case 429: return L10n.Errors.rateLimited
                case 500...599: return L10n.Errors.serverUnavailable
                default: return L10n.Errors.apiError(code)
                }
            case .decodingError:
                return L10n.Errors.decodingError
            case .networkError:
                return L10n.Errors.networkError
            case .retriesExhausted(let code, let attempts):
                return L10n.Errors.retriesExhausted(attempts, code)
            }
        }
        return error.localizedDescription
    }

    // MARK: - Preview Actions

    /// 使用者確認注入（預覽模式）
    func confirmInject() {
        guard case .previewing = session.state else { return }
        log.info("使用者確認注入", category: "Pipeline")
        performInject()
    }

    /// 使用者取消（預覽模式）
    func cancelPreview() {
        guard case .previewing = session.state else { return }
        log.info("使用者取消預覽", category: "Pipeline")
        session.state = .idle
    }

    /// 使用者要求重新生成（預覽模式）
    func regenerate() {
        guard case .previewing = session.state else { return }
        log.info("使用者要求重新生成", category: "Pipeline")
        session.processedText = ""
        session.state = .processing
        Task { @MainActor in
            await processWithLLM()
        }
    }

    /// 執行文字注入 + 後續流程（音效、歷史、Smart Send）
    private func performInject() {
        session.state = .done
        TextInjector.inject(session.processedText)
        log.info("文字已注入", category: "Inject")

        saveToHistory()

        if settingsStore.enableSoundFeedback {
            NSSound(named: .init("Purr"))?.play()
        }

        if settingsStore.enableSmartSend {
            startSmartSendCountdown()
        } else {
            autoResetState(after: 2.0)
        }
    }

    // MARK: - Smart Send

    private func startSmartSendCountdown() {
        let totalSeconds = Int(settingsStore.smartSendDelay)
        log.info("Smart Send 倒數開始 (\(totalSeconds)s)", category: "SmartSend")

        session.state = .confirming(remaining: totalSeconds)

        // 啟動麥克風監聽（grace period 避免完成音效觸發誤取消）
        let monitor = AudioLevelMonitor()
        monitor.onSpeechDetected = { [weak self] in
            self?.cancelSmartSend()
        }
        let grace: TimeInterval = settingsStore.enableSoundFeedback ? 0.8 : 0
        monitor.startMonitoring(inputDeviceUID: settingsStore.selectedInputDeviceUID, gracePeriod: grace)
        self.audioLevelMonitor = monitor

        // 倒數 Task
        smartSendTask = Task { @MainActor [weak self] in
            for remaining in stride(from: totalSeconds, through: 1, by: -1) {
                guard let self, case .confirming = self.session.state else { return }
                self.session.state = .confirming(remaining: remaining)

                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return // Task 被取消
                }
            }

            // 倒數結束，送出 Enter
            guard let self, case .confirming = self.session.state else { return }
            self.cleanupSmartSend()
            self.log.info("Smart Send 倒數結束，送出 Enter", category: "SmartSend")

            try? await Task.sleep(for: .milliseconds(100))
            TextInjector.simulateEnter()

            self.session.state = .done
            if self.settingsStore.enableSoundFeedback {
                NSSound(named: .init("Submarine"))?.play()
            }
            self.autoResetState(after: 1.0)
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

    private func autoResetState(after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.session.state = .idle
        }
    }

    // MARK: - Data Loading

    private func loadPersonalDictionary() -> [String: String]? {
        let context = PersistenceController.shared.container.viewContext
        let request = PersonalDictionaryEntry.fetchRequest()

        guard let entries = try? context.fetch(request), !entries.isEmpty else {
            return nil
        }

        var dict: [String: String] = [:]
        for entry in entries {
            if let term = entry.term, let preferred = entry.preferred {
                dict[term] = preferred
            }
        }
        return dict.isEmpty ? nil : dict
    }

    private func loadSnippets() -> [String: String]? {
        let context = PersistenceController.shared.container.viewContext
        let request = SnippetEntry.fetchRequest()

        guard let entries = try? context.fetch(request), !entries.isEmpty else {
            return nil
        }

        var snippets: [String: String] = [:]
        for entry in entries {
            if let trigger = entry.trigger, let content = entry.content {
                snippets[trigger] = content
            }
        }
        return snippets.isEmpty ? nil : snippets
    }

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
        let context = PersistenceController.shared.container.viewContext
        let record = TranscriptionRecord(context: context)
        record.id = UUID()
        record.rawTranscript = session.rawTranscript
        record.processedText = session.processedText
        record.appContext = session.appContext.appName
        record.mode = "auto"
        record.timestamp = Date()
        record.duration = session.duration
        record.modelName = session.modelName
        record.promptTokens = Int32(session.promptTokens)
        record.completionTokens = Int32(session.completionTokens)
        record.totalTokens = Int32(session.totalTokens)

        try? context.save()
    }
}

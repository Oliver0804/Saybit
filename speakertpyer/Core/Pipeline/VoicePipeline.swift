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
    /// 在按下快捷鍵時預先擷取的選取文字與上下文（async Task）
    private var contextCaptureTask: Task<AppContext, Never>?

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

        // 在 reset 前非同步預擷取選取文字（錄音期間可能失去選取）
        // 使用 Task 避免阻塞主線程（clipboard fallback 需要等待）
        if settingsStore.enableContextAwareness {
            contextCaptureTask = Task {
                await TextExtractor.getCurrentContext()
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
        let temperature = SystemPrompts.temperatureForStyle(style)
        let model = settingsStore.selectedModel
        let provider = settingsStore.selectedProvider
        let transcript = session.rawTranscript
        let selectedText = session.appContext.selectedText
        let hasSelectedText = selectedText != nil && !selectedText!.isEmpty
        let skills = loadSnippets() ?? [:]

        log.info("LLM 處理開始 (provider=\(provider.name), model=\(model), style=\(style.rawValue))", category: "LLM")

        // ── 決定處理路徑 ──
        let systemPrompt: String
        let contentForLLM: String
        let existingTextForPayload: String?

        if hasSelectedText {
            // ── 有選取文字：單次 LLM 呼叫 ──
            // 既有 prompt 已能透過 existing_text 處理指令（翻譯、改寫等）
            log.info("有選取文字 (\(selectedText!.count) 字), 單階段處理", category: "LLM")
            systemPrompt = SystemPrompts.forStyle(style)
            contentForLLM = transcript
            existingTextForPayload = selectedText
        } else {
            // ── 無選取文字：Stage 1 意圖分類（帶 timeout）→ Stage 2 執行 ──
            let intentResult = await classifyIntentWithTimeout(
                transcript: transcript, skills: skills,
                model: model, provider: provider
            )

            // ── Action intents（行事曆/提醒）→ 獨立處理路徑 ──
            if intentResult.intent == "create_event" || intentResult.intent == "create_reminder" {
                await processActionIntent(intentResult)
                return
            }

            if intentResult.intent != "dictation",
               let content = intentResult.content, !content.isEmpty {
                // 有動作意圖且有可操作內容
                if intentResult.intent == "skill",
                   let skillName = intentResult.skillName,
                   let skillPrompt = skills[skillName] {
                    systemPrompt = skillPrompt + "\n\nOutput ONLY the processed result. No explanation."
                    log.info("Stage 2 使用技能: \(skillName)", category: "LLM")
                } else {
                    let actionPrompt = SystemPrompts.forIntent(intentResult, languagePreference: settingsStore.languagePreference)
                    systemPrompt = actionPrompt.isEmpty ? SystemPrompts.forStyle(style) : actionPrompt
                    log.info("Stage 2 執行: \(intentResult.intent)", category: "LLM")
                }
                contentForLLM = content
                existingTextForPayload = nil
            } else if intentResult.intent != "dictation" {
                // 有動作意圖但沒有內容 → 提示使用者選取文字
                log.info("Stage 1 意圖=\(intentResult.intent) 但無可操作內容，提示使用者", category: "LLM")
                let hint: String
                switch intentResult.intent {
                case "translate":
                    let langName = intentResult.language.flatMap { SystemPrompts.languageDisplayName($0) } ?? "目標語言"
                    hint = "請先選取要翻譯成\(langName)的文字"
                case "rewrite":
                    hint = "請先選取要改寫的文字"
                case "skill":
                    hint = "請先選取要處理的文字"
                default:
                    hint = "請先選取要操作的文字"
                }
                session.processedText = hint
                session.state = .error(hint)
                autoResetState(after: 3.0)
                return
            } else {
                // dictation
                systemPrompt = SystemPrompts.forStyle(style)
                contentForLLM = transcript
                existingTextForPayload = nil
            }
        }

        // ── 串流 LLM 呼叫 ──
        let contextId = session.appContext.contextIdentifier
        let payload = LLMPayload(
            transcript: contentForLLM,
            context: contextId.isEmpty ? nil : contextId,
            mode: hasSelectedText ? "edit" : nil,
            tone: settingsStore.toneStyle == .auto ? nil : settingsStore.toneStyle.rawValue,
            languagePreference: settingsStore.languagePreference,
            personalDictionary: loadPersonalDictionary(),
            snippets: nil,
            screenContext: nil,
            whisperMode: settingsStore.enableWhisperMode ? true : nil,
            existingText: existingTextForPayload
        )

        var accumulated = ""
        session.modelName = model

        do {
            let stream = await llmClient.sendStreaming(
                systemPrompt: systemPrompt,
                payload: payload,
                model: model,
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
                session.state = .previewing
                log.info("進入預覽模式，等待使用者確認", category: "Pipeline")
            } else {
                performInject()
            }
        } catch {
            let msg = friendlyErrorMessage(error)
            log.error("LLM 錯誤: \(msg) (\(error))", category: "LLM")
            session.state = .error(msg)
            autoResetState(after: 3.0)
        }
    }

    // MARK: - Intent Classification (Stage 1)

    /// Stage 1 意圖分類，帶 8 秒 timeout。逾時或失敗時 fallback 為 dictation。
    @MainActor
    private func classifyIntentWithTimeout(
        transcript: String, skills: [String: String],
        model: String, provider: LLMProvider
    ) async -> LLMIntentResponse {
        let dictationFallback = LLMIntentResponse(
            intent: "dictation", language: nil, style: nil,
            format: nil, skillName: nil, content: nil
        )

        let intentPrompt = SystemPrompts.intentClassification(skills: skills, hasSelectedText: false)
        let classificationPayload = LLMPayload(
            transcript: "Transcript: \(transcript)",
            context: session.appContext.contextIdentifier.isEmpty ? nil : session.appContext.contextIdentifier,
            mode: nil, tone: nil, languagePreference: settingsStore.languagePreference,
            personalDictionary: nil, snippets: nil, screenContext: nil, whisperMode: nil, existingText: nil
        )

        let client = llmClient  // capture actor reference

        do {
            let raw: String = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await client.send(
                        systemPrompt: intentPrompt,
                        payload: classificationPayload,
                        model: model,
                        temperature: 0.1,
                        provider: provider
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(8))
                    throw CancellationError()
                }
                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return result
            }

            // 解析 JSON（去除 markdown code fence）
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let data = cleaned.data(using: .utf8),
               let parsed = try? JSONDecoder().decode(LLMIntentResponse.self, from: data) {
                log.info("Stage 1 意圖: \(parsed.intent)" +
                         (parsed.language.map { ", lang=\($0)" } ?? "") +
                         (parsed.style.map { ", style=\($0)" } ?? "") +
                         (parsed.skillName.map { ", skill=\($0)" } ?? ""),
                         category: "LLM")
                return parsed
            } else {
                log.info("Stage 1 JSON 解析失敗，fallback dictation: \(raw.prefix(100))", category: "LLM")
                return dictationFallback
            }
        } catch {
            if error is CancellationError {
                log.error("Stage 1 逾時 (8s)，fallback dictation", category: "LLM")
            } else {
                log.error("Stage 1 失敗: \(error)，fallback dictation", category: "LLM")
            }
            return dictationFallback
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

    // MARK: - Action Intents (Calendar / Reminder)

    enum ActionError: LocalizedError {
        case jsonParseFailed
        case permissionDenied(String)
        case eventCreationFailed(String)

        var errorDescription: String? {
            switch self {
            case .jsonParseFailed: return L10n.Errors.actionJsonParseFailed
            case .permissionDenied(let type): return L10n.Errors.actionPermissionDenied(type)
            case .eventCreationFailed(let msg): return L10n.Errors.actionCreationFailed(msg)
            }
        }
    }

    @MainActor
    private func processActionIntent(_ intentResult: LLMIntentResponse) async {
        let model = settingsStore.selectedModel
        let provider = settingsStore.selectedProvider
        let content = intentResult.content ?? session.rawTranscript

        let actionPrompt = SystemPrompts.forIntent(intentResult, languagePreference: settingsStore.languagePreference)
        let payload = LLMPayload(
            transcript: content,
            context: nil, mode: nil, tone: nil,
            languagePreference: settingsStore.languagePreference,
            personalDictionary: nil, snippets: nil, screenContext: nil,
            whisperMode: nil, existingText: nil
        )

        log.info("Action intent: \(intentResult.intent), content: \(content.prefix(80))", category: "Action")

        do {
            let raw = try await llmClient.send(
                systemPrompt: actionPrompt,
                payload: payload,
                model: model,
                temperature: 0.1,
                provider: provider
            )

            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let jsonData = cleaned.data(using: .utf8) else {
                throw ActionError.jsonParseFailed
            }

            switch intentResult.intent {
            case "create_event":
                let eventResponse = try JSONDecoder().decode(LLMEventResponse.self, from: jsonData)
                session.processedText = eventResponse.confirmationText
                session.pendingAction = .createEvent(eventResponse)
                session.state = .previewing
                log.info("Event preview: \(eventResponse.title) @ \(eventResponse.date)", category: "Action")

            case "create_reminder":
                let reminderResponse = try JSONDecoder().decode(LLMReminderResponse.self, from: jsonData)
                session.processedText = reminderResponse.confirmationText
                session.pendingAction = .createReminder(reminderResponse)
                session.state = .previewing
                log.info("Reminder preview: \(reminderResponse.title)", category: "Action")

            default:
                break
            }
        } catch {
            let msg = L10n.Errors.actionExecutionFailed(error.localizedDescription)
            log.error(msg, category: "Action")
            session.state = .error(msg)
            autoResetState(after: 3.0)
        }
    }

    @MainActor
    private func executeAction(_ action: PendingAction) async {
        let eventKit = EventKitManager.shared

        do {
            switch action {
            case .createEvent(let response):
                if !eventKit.calendarAuthorized {
                    let granted = await eventKit.requestCalendarAccess()
                    guard granted else { throw ActionError.permissionDenied(L10n.General.calendar) }
                }

                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                guard let startDate = formatter.date(from: response.date) else {
                    throw ActionError.eventCreationFailed(L10n.Errors.invalidDateFormat)
                }
                let duration = TimeInterval((response.durationMinutes ?? 60) * 60)
                let endDate = startDate.addingTimeInterval(duration)

                let params = EventKitManager.EventParams(
                    title: response.title,
                    startDate: startDate,
                    endDate: endDate,
                    location: response.location,
                    notes: response.notes
                )
                let _ = try await eventKit.createEvent(params)
                log.info("行事曆事件已建立: \(response.title)", category: "Action")

            case .createReminder(let response):
                if !eventKit.reminderAuthorized {
                    let granted = await eventKit.requestReminderAccess()
                    guard granted else { throw ActionError.permissionDenied(L10n.General.reminders) }
                }

                var dueDate: Date? = nil
                if let dueDateStr = response.dueDate {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime]
                    dueDate = formatter.date(from: dueDateStr)
                }

                let params = EventKitManager.ReminderParams(
                    title: response.title,
                    dueDate: dueDate,
                    notes: response.notes
                )
                let _ = try await eventKit.createReminder(params)
                log.info("提醒事項已建立: \(response.title)", category: "Action")
            }

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

    // MARK: - Preview Actions

    /// 使用者確認注入（預覽模式）
    func confirmInject() {
        guard case .previewing = session.state else { return }
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

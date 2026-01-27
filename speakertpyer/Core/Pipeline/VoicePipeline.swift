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

    private let llmClient = OpenRouterClient()
    private let settingsStore: SettingsStore
    private let log = AppLogger.shared
    private var overlayConfigured = false

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
        OverlayWindowController.shared.configure(session: session, settingsStore: settingsStore)
        overlayConfigured = true
    }

    // MARK: - Recording

    func startRecording() {
        // Check prerequisites
        guard KeychainHelper.loadAPIKey() != nil else {
            log.error("未設定 API Key", category: "Pipeline")
            session.state = .error("未設定 API Key，請在設定中輸入")
            autoResetState(after: 3.0)
            return
        }

        session.reset()
        session.state = .recording
        session.startTime = Date()
        log.info("開始錄音", category: "STT")

        // Apply mic sensitivity
        speechRecognizer.micGain = Float(settingsStore.micSensitivity)

        do {
            try speechRecognizer.startListening(
                onDeviceOnly: settingsStore.enableOnDeviceSTT,
                inputDeviceUID: settingsStore.selectedInputDeviceUID
            )
            log.info("語音辨識啟動 (onDevice=\(settingsStore.enableOnDeviceSTT), device=\(settingsStore.selectedInputDeviceUID.isEmpty ? "系統預設" : settingsStore.selectedInputDeviceUID))", category: "STT")
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
                speechRecognizer.silenceTimeoutDuration = settingsStore.silenceTimeout
                speechRecognizer.onSilenceTimeout = { [weak self] in
                    DispatchQueue.main.async {
                        guard let self, case .recording = self.session.state else { return }
                        self.log.info("靜音偵測觸發自動停止 (\(self.settingsStore.silenceTimeout)s)", category: "Pipeline")
                        self.stopRecordingAndProcess()
                    }
                }
            }
        }
    }

    func stopRecordingAndProcess() {
        guard case .recording = session.state else { return }

        let transcript = speechRecognizer.stopListening()
        session.rawTranscript = transcript
        session.endTime = Date()
        session.audioLevel = 0.0
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
        // Poll speech recognizer for partial results and audio level
        Task { @MainActor in
            while case .recording = session.state {
                session.rawTranscript = speechRecognizer.transcript
                session.audioLevel = speechRecognizer.audioLevel
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // MARK: - LLM Processing

    @MainActor
    private func processWithLLM() async {
        let style = settingsStore.promptStyle
        let systemPrompt = SystemPrompts.forStyle(style)
        let temperature = SystemPrompts.temperatureForStyle(style)

        log.info("LLM 處理開始 (model=\(settingsStore.selectedModel), style=\(style.rawValue), temp=\(temperature))", category: "LLM")

        let selectedText = session.appContext.selectedText
        let hasSelectedText = selectedText != nil && !selectedText!.isEmpty

        let payload = LLMPayload(
            transcript: session.rawTranscript,
            context: session.appContext.contextIdentifier.isEmpty ? nil : session.appContext.contextIdentifier,
            mode: nil,
            tone: settingsStore.toneStyle == .auto ? nil : settingsStore.toneStyle.rawValue,
            languagePreference: settingsStore.languagePreference,
            personalDictionary: loadPersonalDictionary(),
            snippets: loadSnippets(),
            screenContext: nil,
            whisperMode: settingsStore.enableWhisperMode ? true : nil,
            existingText: hasSelectedText ? selectedText : nil
        )

        if hasSelectedText {
            log.info("選取文字已傳入 existing_text (\(selectedText!.count) 字)", category: "LLM")
        }
        if settingsStore.enableWhisperMode {
            log.info("Whisper Mode 已啟用", category: "LLM")
        }

        var accumulated = ""

        do {
            let stream = await llmClient.sendStreaming(
                systemPrompt: systemPrompt,
                payload: payload,
                model: settingsStore.selectedModel,
                temperature: temperature
            )
            for try await chunk in stream {
                accumulated += chunk
                session.processedText = accumulated
            }

            guard !accumulated.isEmpty else {
                log.error("LLM 回傳空結果", category: "LLM")
                session.state = .error("LLM 未回傳任何文字")
                autoResetState(after: 3.0)
                return
            }

            log.info("LLM 結果: \(accumulated.prefix(100))\(accumulated.count > 100 ? "..." : "")", category: "LLM")

            session.state = .done
            TextInjector.inject(accumulated)
            log.info("文字已注入", category: "Inject")

            // Save to history
            saveToHistory()

            // Play done sound
            if settingsStore.enableSoundFeedback {
                NSSound(named: .init("Purr"))?.play()
            }

            // Reset to idle after showing done state
            autoResetState(after: 2.0)
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
            case .noAPIKey:
                return "未設定 API Key"
            case .invalidResponse(let code):
                switch code {
                case 401: return "API Key 無效"
                case 402: return "API 餘額不足"
                case 429: return "API 請求過於頻繁，請稍後再試"
                case 500...599: return "伺服器暫時不可用"
                default: return "API 錯誤 (\(code))"
                }
            case .decodingError:
                return "回應解析失敗"
            case .networkError:
                return "網路連線失敗"
            }
        }
        return error.localizedDescription
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

        try? context.save()
    }
}

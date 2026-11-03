//
//  TextRefiner.swift
//  speakertpyer
//
//  跨平台（macOS / iOS）共用的 LLM 文字處理核心：
//  Stage 1 意圖分類 → Stage 2 串流潤飾 / 動作意圖（行事曆、提醒）。
//  原本寫死在 macOS VoicePipeline 內，抽出來讓 iOS pipeline 共用同一套邏輯。
//

import Foundation

/// 單次處理請求
struct RefineRequest {
    /// STT 原始轉錄
    let transcript: String
    /// 使用者選取的文字（有值時走 edit 模式：翻譯 / 改寫選取內容）
    let selectedText: String?
    /// App 上下文 ID（例如 "slack"），空字串代表未知
    let contextIdentifier: String
    /// 語音模式指令（有值時跳過意圖判斷，直接照指令處理）
    var modeInstructions: String? = nil
    /// 螢幕上可見的文字（OCR），給 AI 參考人名、專有名詞、回覆對象
    var screenContext: String? = nil
}

/// 處理結果
enum RefineOutcome {
    /// 一般文字結果（已完成串流）
    case text(String)
    /// 動作意圖（行事曆 / 提醒），需使用者確認後再呼叫 `execute(_:)`
    case action(PendingAction, confirmation: String)
    /// 偵測到需要選取文字的動作，但目前沒有選取 → 提示文字
    case needsSelection(hint: String)
}

enum RefinerError: LocalizedError {
    /// LLM 回傳空字串
    case emptyResponse
    /// 動作意圖（行事曆 / 提醒）解析或執行失敗
    case actionFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyResponse: return L10n.Errors.llmNoResponse
        case .actionFailed(let msg): return msg
        }
    }
}

@MainActor
final class TextRefiner {
    private let settingsStore: SettingsStore
    private let llmClient: OpenRouterClient
    private let records: RecordsRepository
    private let log = AppLogger.shared

    init(
        settingsStore: SettingsStore,
        llmClient: OpenRouterClient? = nil,
        records: RecordsRepository? = nil
    ) {
        self.settingsStore = settingsStore
        self.llmClient = llmClient ?? OpenRouterClient()
        self.records = records ?? RecordsRepository()
    }

    // MARK: - Main Entry

    /// 執行完整處理流程。
    /// - Parameters:
    ///   - onPartial: 串流中累積的文字（每個 chunk 呼叫一次）
    ///   - onUsage: token 用量
    func refine(
        _ request: RefineRequest,
        onPartial: (String) -> Void,
        onUsage: (LLMUsage) -> Void
    ) async throws -> RefineOutcome {
        let style = settingsStore.promptStyle
        let temperature = SystemPrompts.temperatureForStyle(style)
        let model = settingsStore.selectedModel
        let provider = settingsStore.selectedProvider
        // 字典字面替換：辨識錯的專有名詞先修正，LLM 收到的就是正確寫法
        DictionaryHints.refresh(records: records)
        let transcript = DictionaryHints.apply(request.transcript)
        if transcript != request.transcript {
            log.info("字典替換: \(request.transcript.prefix(60)) → \(transcript.prefix(60))", category: "LLM")
        }
        let nonEmptySelectedText = request.selectedText.flatMap { $0.isEmpty ? nil : $0 }
        let hasSelectedText = nonEmptySelectedText != nil
        let skills = records.loadSnippets() ?? [:]
        let contextId = request.contextIdentifier

        log.info("LLM 處理開始 (provider=\(provider.name), model=\(model), style=\(style.rawValue))", category: "LLM")

        // ── 決定處理路徑 ──
        let systemPrompt: String
        let contentForLLM: String
        let existingTextForPayload: String?

        if let instructions = request.modeInstructions?.trimmingCharacters(in: .whitespacesAndNewlines),
           !instructions.isEmpty {
            // ── 語音模式：使用者指定的指令，單次 LLM 呼叫 ──
            log.info("語音模式指令處理 (\(instructions.prefix(30)))", category: "LLM")
            systemPrompt = SystemPrompts.forMode(instructions: instructions, hasSelectedText: hasSelectedText)
            contentForLLM = transcript
            existingTextForPayload = nonEmptySelectedText
        } else if let pickedText = nonEmptySelectedText {
            // ── 有選取文字：單次 LLM 呼叫 ──
            log.info("有選取文字 (\(pickedText.count) 字), 單階段處理", category: "LLM")
            systemPrompt = SystemPrompts.forStyle(style)
            contentForLLM = transcript
            existingTextForPayload = pickedText
        } else {
            // ── 無選取文字：Stage 1 意圖分類（帶 timeout）→ Stage 2 執行 ──
            let intentResult = await classifyIntentWithTimeout(
                transcript: transcript, skills: skills,
                model: model, provider: provider, contextId: contextId
            )

            // ── Action intents（行事曆/提醒）→ 獨立處理路徑 ──
            if intentResult.intent == "create_event" || intentResult.intent == "create_reminder" {
                return try await processActionIntent(intentResult, transcript: transcript)
            }

            if intentResult.intent != "dictation",
               let content = intentResult.content, !content.isEmpty {
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
                return .needsSelection(hint: hint)
            } else {
                systemPrompt = SystemPrompts.forStyle(style)
                contentForLLM = transcript
                existingTextForPayload = nil
            }
        }

        // ── Context rule 覆蓋語氣 / 附加指示 ──
        var effectiveTone: String? = settingsStore.toneStyle == .auto ? nil : settingsStore.toneStyle.rawValue
        var finalSystemPrompt = systemPrompt
        if let rule = settingsStore.contextRule(for: contextId) {
            if let toneOverride = rule.toneOverride, toneOverride != "auto" {
                effectiveTone = toneOverride
                log.info("Context rule 覆蓋語氣: \(contextId) → \(toneOverride)", category: "Context")
            }
            if let additional = rule.additionalPrompt, !additional.isEmpty {
                finalSystemPrompt += "\n\n### App-Specific Instructions\n\(additional)"
                log.info("Context rule 注入附加指示 (\(contextId))", category: "Context")
            }
        }

        if let screen = request.screenContext, !screen.isEmpty {
            finalSystemPrompt += "\n\n" + SystemPrompts.screenContextRule
        }

        let payload = LLMPayload(
            transcript: contentForLLM,
            context: contextId.isEmpty ? nil : contextId,
            mode: hasSelectedText ? "edit" : nil,
            tone: effectiveTone,
            languagePreference: settingsStore.languagePreference,
            personalDictionary: records.loadPersonalDictionary(),
            snippets: skills.isEmpty ? nil : skills,
            screenContext: request.screenContext,
            whisperMode: settingsStore.enableWhisperMode ? true : nil,
            existingText: existingTextForPayload
        )

        // ── 串流 LLM 呼叫 ──
        var accumulated = ""
        let stream = await llmClient.sendStreaming(
            systemPrompt: finalSystemPrompt,
            payload: payload,
            model: model,
            temperature: temperature,
            provider: provider,
            maxTokens: settingsStore.useCustomLLMParams ? settingsStore.llmMaxTokens : nil,
            frequencyPenalty: settingsStore.useCustomLLMParams ? settingsStore.llmFrequencyPenalty : nil,
            presencePenalty: settingsStore.useCustomLLMParams ? settingsStore.llmPresencePenalty : nil,
            topP: settingsStore.useCustomLLMParams ? settingsStore.llmTopP : nil
        )
        for try await event in stream {
            switch event {
            case .text(let chunk):
                accumulated += chunk
                onPartial(accumulated)
            case .usage(let usage):
                onUsage(usage)
            }
        }

        guard !accumulated.isEmpty else {
            log.error("LLM 回傳空結果", category: "LLM")
            throw RefinerError.emptyResponse
        }

        // LLM 可能誤回 JSON command 格式，此時提取 replacement 欄位
        accumulated = extractReplacementIfCommandJSON(accumulated)
        log.info("LLM 結果: \(accumulated.prefix(100))\(accumulated.count > 100 ? "..." : "")", category: "LLM")
        return .text(accumulated)
    }

    // MARK: - Intent Classification (Stage 1)

    /// Stage 1 意圖分類，帶 8 秒 timeout。逾時或失敗時 fallback 為 dictation。
    private func classifyIntentWithTimeout(
        transcript: String, skills: [String: String],
        model: String, provider: LLMProvider, contextId: String
    ) async -> LLMIntentResponse {
        let dictationFallback = LLMIntentResponse(
            intent: "dictation", language: nil, style: nil,
            format: nil, skillName: nil, content: nil
        )

        let intentPrompt = SystemPrompts.intentClassification(skills: skills, hasSelectedText: false)
        let classificationPayload = LLMPayload(
            transcript: "Transcript: \(transcript)",
            context: contextId.isEmpty ? nil : contextId,
            mode: nil, tone: nil, languagePreference: settingsStore.languagePreference,
            personalDictionary: nil, snippets: nil, screenContext: nil, whisperMode: nil, existingText: nil
        )

        let client = llmClient

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

            let cleaned = Self.stripCodeFence(raw)
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

    // MARK: - Action Intents (Calendar / Reminder)

    private func processActionIntent(_ intentResult: LLMIntentResponse, transcript: String) async throws -> RefineOutcome {
        let model = settingsStore.selectedModel
        let provider = settingsStore.selectedProvider
        let content = intentResult.content ?? transcript

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
            guard let jsonData = Self.stripCodeFence(raw).data(using: .utf8) else {
                throw ActionError.jsonParseFailed
            }

            switch intentResult.intent {
            case "create_event":
                let r = try JSONDecoder().decode(LLMEventResponse.self, from: jsonData)
                log.info("Event preview: \(r.title) @ \(r.date)", category: "Action")
                return .action(.createEvent(r), confirmation: r.confirmationText)
            default:
                let r = try JSONDecoder().decode(LLMReminderResponse.self, from: jsonData)
                log.info("Reminder preview: \(r.title)", category: "Action")
                return .action(.createReminder(r), confirmation: r.confirmationText)
            }
        } catch {
            let msg = L10n.Errors.actionExecutionFailed(error.localizedDescription)
            log.error(msg, category: "Action")
            throw RefinerError.actionFailed(msg)
        }
    }

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

    /// 執行使用者已確認的動作（建立行事曆事件 / 提醒事項）
    func execute(_ action: PendingAction) async throws {
        let eventKit = EventKitManager.shared

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
            let params = EventKitManager.EventParams(
                title: response.title,
                startDate: startDate,
                endDate: startDate.addingTimeInterval(duration),
                location: response.location,
                notes: response.notes
            )
            _ = try await eventKit.createEvent(params)
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
            _ = try await eventKit.createReminder(params)
            log.info("提醒事項已建立: \(response.title)", category: "Action")
        }
    }

    // MARK: - Helpers

    private static func stripCodeFence(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// LLM 有時會誤將 edit 模式的結果以 Command Mode JSON 格式回傳
    /// （如 `{"action":"translate","target":"...","replacement":"..."}`），提取 `replacement`。
    private func extractReplacementIfCommandJSON(_ text: String) -> String {
        let trimmed = Self.stripCodeFence(text)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["action"] is String,
              let replacement = json["replacement"] as? String,
              !replacement.isEmpty else {
            return text
        }
        log.info("偵測到 Command JSON，提取 replacement 欄位", category: "LLM")
        return replacement
    }

    /// 把 LLM client 錯誤轉成使用者看得懂的訊息
    static func friendlyErrorMessage(_ error: Error) -> String {
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
}

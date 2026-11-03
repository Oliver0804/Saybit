//
//  OpenRouterClient.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import Foundation

actor OpenRouterClient {
    /// 專用 URLSession：
    /// - 不與 URLSession.shared 競爭全域 4-per-host quota
    /// - 為 streaming 設定明確的 timeout（單次連線 30s、整段資源 5min）
    /// - waitsForConnectivity 讓暫時離線時 OS 排隊而非立刻失敗
    /// - HTTP/2 multiplexing 預設開啟
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 300
        cfg.waitsForConnectivity = true
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    // MARK: - Retry Configuration
    private let maxRetries = 3
    private let baseDelay: TimeInterval = 1.0  // 1s → 2s → 4s
    private let retryableStatusCodes: Set<Int> = [429, 500, 502, 503, 504]

    enum ClientError: LocalizedError {
        case noAPIKey(String)
        case invalidResponse(Int)
        case decodingError(Error)
        case networkError(Error)
        case retriesExhausted(lastStatusCode: Int, attempts: Int)
        /// 非 2xx 且帶有回應內容（前 4KB 擷取出的訊息）
        case httpError(statusCode: Int, body: String)
        /// 串流中途伺服器送來的 `{"error": …}`
        case streamError(String)
        /// 端點不安全或無效，請求未送出（API Key 未外送）
        case insecureEndpoint(String)

        var errorDescription: String? {
            switch self {
            case .httpError(let code, let body):
                let detail = Self.extractErrorMessage(fromBody: body)
                return detail.isEmpty ? Self.humanReadable(statusCode: code) : "\(Self.humanReadable(statusCode: code))：\(detail)"
            case .streamError(let msg): return "AI 服務回報錯誤：\(msg)"
            case .insecureEndpoint(let msg): return msg
            case .noAPIKey(let provider): return "未設定 \(provider) API Key"
            case .invalidResponse(let code): return Self.humanReadable(statusCode: code)
            case .decodingError(let error): return "解碼錯誤：\(error.localizedDescription)"
            case .networkError(let error): return "網路錯誤：\(error.localizedDescription)"
            case .retriesExhausted(let code, let attempts):
                return "重試 \(attempts) 次後仍失敗（\(Self.humanReadable(statusCode: code))）"
            }
        }

        /// 從錯誤回應 body 取出 `error.message`（OpenAI 相容格式），取不到就回前 200 字。
        nonisolated static func extractErrorMessage(fromBody body: String) -> String {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "" }
            if let data = trimmed.data(using: .utf8),
               let chunk = try? JSONDecoder().decode(OpenRouterStreamChunk.self, from: data),
               let msg = chunk.errorMessage {
                return String(msg.prefix(200))
            }
            return String(trimmed.prefix(200))
        }

        /// 把 HTTP status code 翻成使用者看得懂的訊息。
        static func humanReadable(statusCode code: Int) -> String {
            switch code {
            case 400: return "HTTP 400：請求格式錯誤（可能是模型名稱不正確或參數不被支援）"
            case 401: return "HTTP 401：API Key 無效或已失效"
            case 402: return "HTTP 402：餘額不足，請至服務商儲值"
            case 403: return "HTTP 403：權限不足（可能是模型未授權）"
            case 404: return "HTTP 404：模型不存在或端點錯誤"
            case 408: return "HTTP 408：請求逾時"
            case 413: return "HTTP 413：請求內容過大"
            case 429: return "HTTP 429：超過速率限制，稍候再試"
            case 500: return "HTTP 500：服務商內部錯誤"
            case 502: return "HTTP 502：上游服務無回應"
            case 503: return "HTTP 503：服務暫時不可用"
            case 504: return "HTTP 504：上游逾時"
            default:  return "HTTP \(code)：API 回應錯誤"
            }
        }
    }

    /// Calculate delay with exponential backoff + jitter
    private func retryDelay(attempt: Int) -> TimeInterval {
        let exponential = baseDelay * pow(2.0, Double(attempt))
        let jitter = Double.random(in: 0...0.5)
        return exponential + jitter
    }

    /// 組 user message。`existing_text` / `screen_context` 是資料，用專屬標籤包起來，
    /// 與指令（transcript）分開，也不再重複放進 JSON metadata。
    nonisolated static func buildUserMessage(payload: LLMPayload, metadataJSON: String) -> String {
        var blocks: [String] = []
        if let existing = payload.existingText, !existing.isEmpty {
            blocks.append(taggedBlock("existing_text", existing))
        }
        if let screen = payload.screenContext, !screen.isEmpty {
            blocks.append(taggedBlock("screen_context", screen))
        }
        guard !blocks.isEmpty else { return metadataJSON }
        return """
        ## Voice Instruction
        \(payload.transcript)

        ## Metadata
        \(metadataJSON)

        \(blocks.joined(separator: "\n\n"))
        """
    }

    /// 內容中若出現同名結尾標籤（可能是刻意注入），轉義後再包，避免提早閉合。
    nonisolated private static func taggedBlock(_ tag: String, _ content: String) -> String {
        let escaped = content
            .replacingOccurrences(of: "</\(tag)>", with: "&lt;/\(tag)&gt;")
            .replacingOccurrences(of: "<\(tag)>", with: "&lt;\(tag)&gt;")
        return "<\(tag)>\n\(escaped)\n</\(tag)>"
    }

    /// 非 2xx 時讀 body 前 4KB 放進錯誤訊息
    private func readErrorBody(_ bytes: URLSession.AsyncBytes) async -> String {
        var buffer = Data()
        buffer.reserveCapacity(4096)
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 4096 { break }
            }
        } catch {
            // 讀不到 body 就只回狀態碼
        }
        return String(decoding: buffer, as: UTF8.self)
    }

    func sendStreaming(
        systemPrompt: String,
        payload: LLMPayload,
        model: String,
        temperature: Double,
        provider: LLMProvider,
        maxTokens: Int? = nil,
        frequencyPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        topP: Double? = nil
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let isAppleOnDevice = provider.id == AppleOnDeviceLLM.providerID

                    // 端點檢查必須在讀 key 之前：不安全 / 無效端點一律不送 key
                    if !isAppleOnDevice,
                       let msg = LLMProvider.baseURLValidationMessage(
                           LLMProvider.validateBaseURL(provider.baseURL), url: provider.baseURL) {
                        continuation.finish(throwing: ClientError.insecureEndpoint(msg))
                        return
                    }

                    let apiKey: String? = provider.requiresAPIKey
                        ? KeychainHelper.loadAPIKey(for: provider.id)
                        : (KeychainHelper.loadAPIKey(for: provider.id) ?? "")

                    guard let apiKey, (apiKey.isEmpty == false || !provider.requiresAPIKey) else {
                        continuation.finish(throwing: ClientError.noAPIKey(provider.name))
                        return
                    }

                    guard let endpointURL = URL(string: provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                        continuation.finish(throwing: ClientError.networkError(
                            NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "無效的端點 URL"])
                        ))
                        return
                    }

                    let metadataPayload = payload.withoutTaggedBlocks()
                    let payloadJSON = try jsonEncoder.encode(metadataPayload)
                    let payloadString = String(data: payloadJSON, encoding: .utf8) ?? "{}"
                    let userMessage = Self.buildUserMessage(payload: payload, metadataJSON: payloadString)

                    // Apple 本機模型：不走 HTTP，直接用 FoundationModels 串流
                    if isAppleOnDevice {
                        for try await chunk in AppleOnDeviceLLM.stream(
                            systemPrompt: systemPrompt, userMessage: userMessage,
                            temperature: temperature, maxTokens: maxTokens
                        ) {
                            try Task.checkCancellation()
                            continuation.yield(.text(chunk))
                        }
                        try Task.checkCancellation()
                        continuation.finish()
                        return
                    }

                    // 本地服務（LM Studio, Ollama）可能不支援 stream_options。
                    // 自訂端點先送（才拿得到 token 用量），回 400 再退回不送重試一次。
                    let isCustom = provider.id.hasPrefix("custom-")
                    var useStreamOptions = provider.id != "lmstudio" && provider.id != "ollama"

                    func makeRequest() throws -> URLRequest {
                        let chatRequest = OpenRouterChatRequest(
                            model: model,
                            messages: [
                                .init(role: "system", content: systemPrompt),
                                .init(role: "user", content: userMessage),
                            ],
                            stream: true,
                            temperature: temperature,
                            streamOptions: useStreamOptions ? .init(includeUsage: true) : nil,
                            maxTokens: maxTokens,
                            frequencyPenalty: frequencyPenalty,
                            presencePenalty: presencePenalty,
                            topP: topP
                        )
                        var request = URLRequest(url: endpointURL)
                        request.httpMethod = "POST"
                        if !apiKey.isEmpty {
                            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                        }
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        for (key, value) in provider.extraHeaders {
                            request.setValue(value, forHTTPHeaderField: key)
                        }
                        request.httpBody = try jsonEncoder.encode(chatRequest)
                        return request
                    }

                    var request = try makeRequest()

                    // Retry loop with exponential backoff for connection phase
                    var lastStatusCode = 0
                    var skipNextDelay = false
                    for attempt in 0...maxRetries {
                        if attempt > 0 && !skipNextDelay {
                            let delay = retryDelay(attempt: attempt - 1)
                            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        }
                        skipNextDelay = false
                        try Task.checkCancellation()

                        let (bytes, response) = try await session.bytes(for: request)

                        guard let httpResponse = response as? HTTPURLResponse else {
                            continuation.finish(throwing: ClientError.invalidResponse(0))
                            return
                        }

                        lastStatusCode = httpResponse.statusCode

                        // 自訂端點不支援 stream_options → 拿掉後立即重試一次
                        if httpResponse.statusCode == 400 && isCustom && useStreamOptions && attempt < maxRetries {
                            AppLogger.shared.info("自訂端點回 400，改為不送 stream_options 重試", category: "LLM")
                            useStreamOptions = false
                            request = try makeRequest()
                            skipNextDelay = true
                            continue
                        }

                        // Non-retryable error → fail immediately（附上 body 前 4KB）
                        if !(200...299).contains(httpResponse.statusCode) && !retryableStatusCodes.contains(httpResponse.statusCode) {
                            let body = await readErrorBody(bytes)
                            continuation.finish(throwing: body.isEmpty
                                ? ClientError.invalidResponse(httpResponse.statusCode)
                                : ClientError.httpError(statusCode: httpResponse.statusCode, body: body))
                            return
                        }

                        // Retryable error → try again (unless last attempt)
                        if retryableStatusCodes.contains(httpResponse.statusCode) {
                            if attempt < maxRetries { continue }
                            let body = await readErrorBody(bytes)
                            if !body.isEmpty {
                                AppLogger.shared.error("LLM 重試耗盡，最後回應: \(ClientError.extractErrorMessage(fromBody: body))", category: "LLM")
                            }
                            continuation.finish(throwing: ClientError.retriesExhausted(
                                lastStatusCode: httpResponse.statusCode, attempts: maxRetries + 1
                            ))
                            return
                        }

                        // Success (2xx) → stream response
                        var hasReceivedContent = false
                        for try await line in bytes.lines {
                            try Task.checkCancellation()
                            guard line.hasPrefix("data:") else {
                                // 非 SSE 格式的行 — 可能是錯誤 JSON
                                let trimmed = line.trimmingCharacters(in: .whitespaces)
                                if trimmed.hasPrefix("{"),
                                   let data = trimmed.data(using: .utf8),
                                   let chunk = try? jsonDecoder.decode(OpenRouterStreamChunk.self, from: data),
                                   let message = chunk.errorMessage {
                                    continuation.finish(throwing: ClientError.streamError(message))
                                    return
                                }
                                if !line.isEmpty {
                                    AppLogger.shared.debug("LLM stream non-SSE line (\(line.count) 字)", category: "LLM")
                                }
                                continue
                            }
                            let jsonString = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            if jsonString == "[DONE]" { break }

                            guard let jsonData = jsonString.data(using: .utf8) else { continue }
                            let chunk: OpenRouterStreamChunk
                            do {
                                chunk = try jsonDecoder.decode(OpenRouterStreamChunk.self, from: jsonData)
                            } catch {
                                AppLogger.shared.debug("LLM stream decode error: \(error.localizedDescription) (\(jsonString.count) 字)", category: "LLM")
                                continue
                            }
                            if let message = chunk.errorMessage {
                                AppLogger.shared.error("LLM stream 收到伺服器錯誤: \(message.prefix(200))", category: "LLM")
                                continuation.finish(throwing: ClientError.streamError(message))
                                return
                            }
                            if let content = chunk.choices?.first?.delta?.content {
                                hasReceivedContent = true
                                continuation.yield(.text(content))
                            }
                            if let usage = chunk.usage {
                                continuation.yield(.usage(usage))
                            }
                        }
                        try Task.checkCancellation()
                        if !hasReceivedContent {
                            AppLogger.shared.error("LLM stream 完成但無內容 (provider=\(provider.id))", category: "LLM")
                        }

                        continuation.finish()
                        return
                    }

                    // Should not reach here, but safety net
                    continuation.finish(throwing: ClientError.retriesExhausted(
                        lastStatusCode: lastStatusCode, attempts: maxRetries + 1
                    ))
                } catch {
                    // 取消（含 URLSession 因 task 取消而丟的 URLError.cancelled）一律以 CancellationError
                    // 結束，讓呼叫端能分辨「使用者取消」與「沒有回應」。
                    if error is CancellationError || Task.isCancelled
                        || (error as? URLError)?.code == .cancelled {
                        continuation.finish(throwing: CancellationError())
                    } else {
                        continuation.finish(throwing: ClientError.networkError(error))
                    }
                }
            }
            // 消費端取消 / 停止迭代（例如 Stage 1 逾時）→ 中止 HTTP 請求，不再白付 token
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Quick API key validation with a minimal request (with retry)
    func testConnection(model: String, provider: LLMProvider) async throws {
        if provider.id == AppleOnDeviceLLM.providerID {
            if let reason = AppleOnDeviceLLM.unavailableReason {
                throw AppleOnDeviceLLM.LLMError.unavailable(reason)
            }
            return
        }
        if let msg = LLMProvider.baseURLValidationMessage(
            LLMProvider.validateBaseURL(provider.baseURL), url: provider.baseURL) {
            throw ClientError.insecureEndpoint(msg)
        }
        let apiKey = provider.requiresAPIKey
            ? KeychainHelper.loadAPIKey(for: provider.id)
            : (KeychainHelper.loadAPIKey(for: provider.id) ?? "")

        guard let apiKey, (apiKey.isEmpty == false || !provider.requiresAPIKey) else {
            throw ClientError.noAPIKey(provider.name)
        }

        guard let endpointURL = URL(string: provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ClientError.networkError(
                NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "無效的端點 URL"])
            )
        }

        let chatRequest = OpenRouterChatRequest(
            model: model,
            messages: [.init(role: "user", content: "Hi")],
            stream: false,
            temperature: 0,
            streamOptions: nil,
            maxTokens: nil,
            frequencyPenalty: nil,
            presencePenalty: nil,
            topP: nil
        )

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in provider.extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try jsonEncoder.encode(chatRequest)
        request.timeoutInterval = 10

        for attempt in 0...maxRetries {
            if attempt > 0 {
                let delay = retryDelay(attempt: attempt - 1)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ClientError.invalidResponse(0)
            }

            if (200...299).contains(httpResponse.statusCode) { return }

            if retryableStatusCodes.contains(httpResponse.statusCode) {
                if attempt < maxRetries { continue }
                throw ClientError.retriesExhausted(
                    lastStatusCode: httpResponse.statusCode, attempts: maxRetries + 1
                )
            }

            let body = String(decoding: data.prefix(4096), as: UTF8.self)
            throw body.isEmpty
                ? ClientError.invalidResponse(httpResponse.statusCode)
                : ClientError.httpError(statusCode: httpResponse.statusCode, body: body)
        }
    }

    /// Non-streaming request for simple completions
    func send(
        systemPrompt: String,
        payload: LLMPayload,
        model: String,
        temperature: Double,
        provider: LLMProvider,
        maxTokens: Int? = nil,
        frequencyPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        topP: Double? = nil
    ) async throws -> String {
        var result = ""
        for try await event in sendStreaming(
            systemPrompt: systemPrompt,
            payload: payload,
            model: model,
            temperature: temperature,
            provider: provider,
            maxTokens: maxTokens,
            frequencyPenalty: frequencyPenalty,
            presencePenalty: presencePenalty,
            topP: topP
        ) {
            if case .text(let chunk) = event {
                result += chunk
            }
        }
        return result
    }
}

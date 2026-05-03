//
//  OpenRouterClient.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import Foundation

actor OpenRouterClient {
    private let session = URLSession.shared
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

        var errorDescription: String? {
            switch self {
            case .noAPIKey(let provider): return "未設定 \(provider) API Key"
            case .invalidResponse(let code): return Self.humanReadable(statusCode: code)
            case .decodingError(let error): return "解碼錯誤：\(error.localizedDescription)"
            case .networkError(let error): return "網路錯誤：\(error.localizedDescription)"
            case .retriesExhausted(let code, let attempts):
                return "重試 \(attempts) 次後仍失敗（\(Self.humanReadable(statusCode: code))）"
            }
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
            Task {
                do {
                    let apiKey: String? = provider.requiresAPIKey
                        ? KeychainHelper.loadAPIKey(for: provider.id)
                        : (KeychainHelper.loadAPIKey(for: provider.id) ?? "")

                    guard let apiKey, (apiKey.isEmpty == false || !provider.requiresAPIKey) else {
                        continuation.finish(throwing: ClientError.noAPIKey(provider.name))
                        return
                    }

                    guard let endpointURL = URL(string: provider.baseURL) else {
                        continuation.finish(throwing: ClientError.networkError(
                            NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "無效的端點 URL"])
                        ))
                        return
                    }

                    let payloadJSON = try jsonEncoder.encode(payload)
                    let payloadString = String(data: payloadJSON, encoding: .utf8) ?? "{}"

                    // When existing_text is present, use structured format for clarity
                    let userMessage: String
                    if let existingText = payload.existingText, !existingText.isEmpty {
                        userMessage = """
                        ## Voice Instruction
                        \(payload.transcript)

                        ## Selected Text
                        \(existingText)

                        ## Metadata
                        \(payloadString)
                        """
                    } else {
                        userMessage = payloadString
                    }

                    // 本地服務（LM Studio, Ollama）可能不支援 stream_options
                    let useStreamOptions = provider.id != "lmstudio" && provider.id != "ollama"
                        && !provider.id.hasPrefix("custom-")

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

                    // Retry loop with exponential backoff for connection phase
                    var lastStatusCode = 0
                    for attempt in 0...maxRetries {
                        if attempt > 0 {
                            let delay = retryDelay(attempt: attempt - 1)
                            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        }

                        let (bytes, response) = try await session.bytes(for: request)

                        guard let httpResponse = response as? HTTPURLResponse else {
                            continuation.finish(throwing: ClientError.invalidResponse(0))
                            return
                        }

                        lastStatusCode = httpResponse.statusCode

                        // Non-retryable error → fail immediately
                        if httpResponse.statusCode != 200 && !retryableStatusCodes.contains(httpResponse.statusCode) {
                            continuation.finish(throwing: ClientError.invalidResponse(httpResponse.statusCode))
                            return
                        }

                        // Retryable error → try again (unless last attempt)
                        if retryableStatusCodes.contains(httpResponse.statusCode) {
                            if attempt < maxRetries { continue }
                            continuation.finish(throwing: ClientError.retriesExhausted(
                                lastStatusCode: httpResponse.statusCode, attempts: maxRetries + 1
                            ))
                            return
                        }

                        // Success (200) → stream response
                        var hasReceivedContent = false
                        for try await line in bytes.lines {
                            guard line.hasPrefix("data: ") else {
                                // 非 SSE 格式的行 — 可能是錯誤訊息
                                if !line.isEmpty {
                                    AppLogger.shared.debug("LLM stream non-SSE line: \(line.prefix(200))", category: "LLM")
                                }
                                continue
                            }
                            let jsonString = String(line.dropFirst(6))
                            if jsonString == "[DONE]" { break }

                            guard let jsonData = jsonString.data(using: .utf8) else { continue }
                            do {
                                let chunk = try jsonDecoder.decode(OpenRouterStreamChunk.self, from: jsonData)
                                if let content = chunk.choices?.first?.delta?.content {
                                    hasReceivedContent = true
                                    continuation.yield(.text(content))
                                }
                                if let usage = chunk.usage {
                                    continuation.yield(.usage(usage))
                                }
                            } catch {
                                AppLogger.shared.debug("LLM stream decode error: \(error.localizedDescription), raw: \(jsonString.prefix(300))", category: "LLM")
                                continue
                            }
                        }
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
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ClientError.networkError(error))
                }
            }
        }
    }

    /// Quick API key validation with a minimal request (with retry)
    func testConnection(model: String, provider: LLMProvider) async throws {
        let apiKey = provider.requiresAPIKey
            ? KeychainHelper.loadAPIKey(for: provider.id)
            : (KeychainHelper.loadAPIKey(for: provider.id) ?? "")

        guard let apiKey, (apiKey.isEmpty == false || !provider.requiresAPIKey) else {
            throw ClientError.noAPIKey(provider.name)
        }

        guard let endpointURL = URL(string: provider.baseURL) else {
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

            let (_, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ClientError.invalidResponse(0)
            }

            if httpResponse.statusCode == 200 { return }

            if retryableStatusCodes.contains(httpResponse.statusCode) {
                if attempt < maxRetries { continue }
                throw ClientError.retriesExhausted(
                    lastStatusCode: httpResponse.statusCode, attempts: maxRetries + 1
                )
            }

            throw ClientError.invalidResponse(httpResponse.statusCode)
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

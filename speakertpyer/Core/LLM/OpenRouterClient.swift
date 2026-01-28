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
            case .invalidResponse(let code): return "API 回應錯誤: \(code)"
            case .decodingError(let error): return "解碼錯誤: \(error.localizedDescription)"
            case .networkError(let error): return "網路錯誤: \(error.localizedDescription)"
            case .retriesExhausted(let code, let attempts):
                return "重試 \(attempts) 次後仍失敗 (HTTP \(code))"
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
        provider: LLMProvider
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

                    let chatRequest = OpenRouterChatRequest(
                        model: model,
                        messages: [
                            .init(role: "system", content: systemPrompt),
                            .init(role: "user", content: userMessage),
                        ],
                        stream: true,
                        temperature: temperature,
                        streamOptions: .init(includeUsage: true)
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
                        for try await line in bytes.lines {
                            guard line.hasPrefix("data: ") else { continue }
                            let jsonString = String(line.dropFirst(6))
                            if jsonString == "[DONE]" { break }

                            guard let jsonData = jsonString.data(using: .utf8) else { continue }
                            do {
                                let chunk = try jsonDecoder.decode(OpenRouterStreamChunk.self, from: jsonData)
                                if let content = chunk.choices?.first?.delta?.content {
                                    continuation.yield(.text(content))
                                }
                                if let usage = chunk.usage {
                                    continuation.yield(.usage(usage))
                                }
                            } catch {
                                // Skip malformed chunks
                                continue
                            }
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
            streamOptions: nil
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
        provider: LLMProvider
    ) async throws -> String {
        var result = ""
        for try await event in sendStreaming(
            systemPrompt: systemPrompt,
            payload: payload,
            model: model,
            temperature: temperature,
            provider: provider
        ) {
            if case .text(let chunk) = event {
                result += chunk
            }
        }
        return result
    }
}

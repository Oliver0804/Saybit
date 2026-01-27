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

    enum ClientError: LocalizedError {
        case noAPIKey(String)
        case invalidResponse(Int)
        case decodingError(Error)
        case networkError(Error)

        var errorDescription: String? {
            switch self {
            case .noAPIKey(let provider): return "未設定 \(provider) API Key"
            case .invalidResponse(let code): return "API 回應錯誤: \(code)"
            case .decodingError(let error): return "解碼錯誤: \(error.localizedDescription)"
            case .networkError(let error): return "網路錯誤: \(error.localizedDescription)"
            }
        }
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
                    guard let apiKey = KeychainHelper.loadAPIKey(for: provider.id) else {
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

                    let chatRequest = OpenRouterChatRequest(
                        model: model,
                        messages: [
                            .init(role: "system", content: systemPrompt),
                            .init(role: "user", content: payloadString),
                        ],
                        stream: true,
                        temperature: temperature,
                        streamOptions: .init(includeUsage: true)
                    )

                    var request = URLRequest(url: endpointURL)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    for (key, value) in provider.extraHeaders {
                        request.setValue(value, forHTTPHeaderField: key)
                    }
                    request.httpBody = try jsonEncoder.encode(chatRequest)

                    let (bytes, response) = try await session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: ClientError.invalidResponse(0))
                        return
                    }

                    guard httpResponse.statusCode == 200 else {
                        continuation.finish(throwing: ClientError.invalidResponse(httpResponse.statusCode))
                        return
                    }

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
                } catch {
                    continuation.finish(throwing: ClientError.networkError(error))
                }
            }
        }
    }

    /// Quick API key validation with a minimal request
    func testConnection(model: String, provider: LLMProvider) async throws {
        guard let apiKey = KeychainHelper.loadAPIKey(for: provider.id) else {
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
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in provider.extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try jsonEncoder.encode(chatRequest)
        request.timeoutInterval = 10

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse(0)
        }

        guard httpResponse.statusCode == 200 else {
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

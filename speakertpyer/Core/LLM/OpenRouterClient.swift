//
//  OpenRouterClient.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import Foundation

actor OpenRouterClient {
    private let baseURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private let session = URLSession.shared
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    enum ClientError: LocalizedError {
        case noAPIKey
        case invalidResponse(Int)
        case decodingError(Error)
        case networkError(Error)

        var errorDescription: String? {
            switch self {
            case .noAPIKey: return "未設定 OpenRouter API Key"
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
        temperature: Double
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let apiKey = KeychainHelper.loadAPIKey() else {
                        continuation.finish(throwing: ClientError.noAPIKey)
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
                        temperature: temperature
                    )

                    var request = URLRequest(url: baseURL)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("https://speakertyper.bashcat.net", forHTTPHeaderField: "HTTP-Referer")
                    request.setValue("SpeakerTyper", forHTTPHeaderField: "X-Title")
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
                                continuation.yield(content)
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
    func testConnection(model: String) async throws {
        guard let apiKey = KeychainHelper.loadAPIKey() else {
            throw ClientError.noAPIKey
        }

        let chatRequest = OpenRouterChatRequest(
            model: model,
            messages: [.init(role: "user", content: "Hi")],
            stream: false,
            temperature: 0
        )

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://speakertyper.bashcat.net", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("SpeakerTyper", forHTTPHeaderField: "X-Title")
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
        temperature: Double
    ) async throws -> String {
        var result = ""
        for try await chunk in sendStreaming(
            systemPrompt: systemPrompt,
            payload: payload,
            model: model,
            temperature: temperature
        ) {
            result += chunk
        }
        return result
    }
}

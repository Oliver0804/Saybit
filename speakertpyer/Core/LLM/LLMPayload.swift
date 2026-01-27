//
//  LLMPayload.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import Foundation

struct LLMPayload: Encodable {
    let transcript: String
    let context: String?
    let mode: String?
    let tone: String?
    let languagePreference: String?
    let personalDictionary: [String: String]?
    let snippets: [String: String]?
    let screenContext: String?
    let whisperMode: Bool?
    let existingText: String?

    enum CodingKeys: String, CodingKey {
        case transcript
        case context
        case mode
        case tone
        case languagePreference = "language_preference"
        case personalDictionary = "personal_dictionary"
        case snippets
        case screenContext = "screen_context"
        case whisperMode = "whisper_mode"
        case existingText = "existing_text"
    }
}

struct LLMCommandResponse: Decodable {
    let action: String
    let target: String?
    let replacement: String?
}

struct OpenRouterChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
    let temperature: Double
    let streamOptions: StreamOptions?

    struct ChatMessage: Encodable {
        let role: String
        let content: String
    }

    struct StreamOptions: Encodable {
        let includeUsage: Bool

        enum CodingKeys: String, CodingKey {
            case includeUsage = "include_usage"
        }
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature
        case streamOptions = "stream_options"
    }
}

struct OpenRouterStreamChunk: Decodable {
    let choices: [Choice]?
    let usage: LLMUsage?

    struct Choice: Decodable {
        let delta: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    struct Delta: Decodable {
        let content: String?
    }
}

struct LLMUsage: Decodable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

enum StreamEvent {
    case text(String)
    case usage(LLMUsage)
}

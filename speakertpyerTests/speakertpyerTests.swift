//
//  speakertpyerTests.swift
//  speakertpyerTests
//
//  Created by 顏國明 on 2026/1/27.
//

import Foundation
import Testing
@testable import Saybit

// MARK: - LLMProvider.modelsEndpoint

struct LLMProviderModelsEndpointTests {

    @Test func openAIEndpointDerivation() {
        let url = LLMProvider.openAI.modelsEndpoint
        #expect(url?.absoluteString == "https://api.openai.com/v1/models")
    }

    @Test func openRouterEndpointDerivation() {
        let url = LLMProvider.openRouter.modelsEndpoint
        #expect(url?.absoluteString == "https://openrouter.ai/api/v1/models")
    }

    @Test func deepSeekEndpointDerivation() {
        let url = LLMProvider.deepSeek.modelsEndpoint
        #expect(url?.absoluteString == "https://api.deepseek.com/models")
    }

    @Test func groqEndpointDerivation() {
        let url = LLMProvider.groq.modelsEndpoint
        #expect(url?.absoluteString == "https://api.groq.com/openai/v1/models")
    }

    @Test func togetherEndpointDerivation() {
        let url = LLMProvider.togetherAI.modelsEndpoint
        #expect(url?.absoluteString == "https://api.together.xyz/v1/models")
    }

    @Test func lmStudioEndpointDerivation() {
        let url = LLMProvider.lmStudio.modelsEndpoint
        #expect(url?.absoluteString == "http://localhost:1234/v1/models")
    }

    @Test func customEndpointWithPort() {
        let p = LLMProvider.custom(
            id: "custom-x",
            name: "X",
            baseURL: "http://192.168.0.10:8080/v1/chat/completions"
        )
        #expect(p.modelsEndpoint?.absoluteString == "http://192.168.0.10:8080/v1/models")
    }

    @Test func malformedBaseURLReturnsNil() {
        let p = LLMProvider.custom(id: "bad", name: "Bad", baseURL: "not a url")
        #expect(p.modelsEndpoint == nil)
    }
}

// MARK: - TranscriptionSession

struct TranscriptionSessionTests {

    @Test func resetClearsAllFields() {
        let s = TranscriptionSession()
        s.state = .recording
        s.rawTranscript = "hello"
        s.processedText = "Hello!"
        s.startTime = Date()
        s.endTime = Date()
        s.audioLevel = 0.7
        s.smartSendCancelled = true
        s.modelName = "gpt-4.1-nano"
        s.promptTokens = 10
        s.completionTokens = 20
        s.totalTokens = 30

        s.reset()

        #expect(s.state == .idle)
        #expect(s.rawTranscript.isEmpty)
        #expect(s.processedText.isEmpty)
        #expect(s.startTime == nil)
        #expect(s.endTime == nil)
        #expect(s.audioLevel == 0.0)
        #expect(s.smartSendCancelled == false)
        #expect(s.modelName.isEmpty)
        #expect(s.promptTokens == 0)
        #expect(s.completionTokens == 0)
        #expect(s.totalTokens == 0)
    }

    @Test func durationZeroWhenNoStart() {
        let s = TranscriptionSession()
        #expect(s.duration == 0)
    }

    @Test func durationCalculatedFromRange() {
        let s = TranscriptionSession()
        let start = Date()
        s.startTime = start
        s.endTime = start.addingTimeInterval(2.5)
        #expect(abs(s.duration - 2.5) < 0.001)
    }

    @Test func confirmingStateEquality() {
        #expect(TranscriptionSession.State.confirming(remaining: 3) == .confirming(remaining: 3))
        #expect(TranscriptionSession.State.confirming(remaining: 3) != .confirming(remaining: 2))
    }
}

// MARK: - SSE chunk decoding

struct OpenRouterStreamChunkDecodeTests {

    private let decoder = JSONDecoder()

    @Test func decodesContentDelta() throws {
        let json = #"""
        {"choices":[{"delta":{"content":"Hello"},"finish_reason":null}]}
        """#.data(using: .utf8)!
        let chunk = try decoder.decode(OpenRouterStreamChunk.self, from: json)
        #expect(chunk.choices?.first?.delta?.content == "Hello")
        #expect(chunk.choices?.first?.finishReason == nil)
        #expect(chunk.usage == nil)
    }

    @Test func decodesUsageOnly() throws {
        let json = #"""
        {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":34,"total_tokens":46}}
        """#.data(using: .utf8)!
        let chunk = try decoder.decode(OpenRouterStreamChunk.self, from: json)
        #expect(chunk.usage?.promptTokens == 12)
        #expect(chunk.usage?.completionTokens == 34)
        #expect(chunk.usage?.totalTokens == 46)
    }

    @Test func decodesEmptyDelta() throws {
        let json = #"""
        {"choices":[{"delta":{},"finish_reason":"stop"}]}
        """#.data(using: .utf8)!
        let chunk = try decoder.decode(OpenRouterStreamChunk.self, from: json)
        #expect(chunk.choices?.first?.delta?.content == nil)
        #expect(chunk.choices?.first?.finishReason == "stop")
    }
}

// MARK: - ClientError messages

struct ClientErrorMessageTests {

    @Test func unauthorizedHasFriendlyMessage() {
        let err = OpenRouterClient.ClientError.invalidResponse(401)
        #expect(err.errorDescription?.contains("401") == true)
    }

    @Test func rateLimitedHasFriendlyMessage() {
        let err = OpenRouterClient.ClientError.invalidResponse(429)
        #expect(err.errorDescription?.contains("429") == true)
    }

    @Test func noAPIKeyMentionsProviderName() {
        let err = OpenRouterClient.ClientError.noAPIKey("OpenRouter")
        #expect(err.errorDescription?.contains("OpenRouter") == true)
    }
}

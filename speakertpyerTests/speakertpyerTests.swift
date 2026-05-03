//
//  speakertpyerTests.swift
//  speakertpyerTests
//
//  Created by 顏國明 on 2026/1/27.
//

import CoreGraphics
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

// MARK: - UpdateChecker semver

struct UpdateCheckerSemverTests {

    @Test func normalizeStripsLeadingV() {
        #expect(UpdateChecker.normalize("v1.5.0") == "1.5.0")
        #expect(UpdateChecker.normalize("V2.0") == "2.0")
        #expect(UpdateChecker.normalize("3.0.0") == "3.0.0")
        #expect(UpdateChecker.normalize("  v1.0  ") == "1.0")
    }

    @Test func compareBasicOrdering() {
        #expect(UpdateChecker.compareSemver("1.0.0", "1.0.1") == .orderedAscending)
        #expect(UpdateChecker.compareSemver("1.5.0", "1.5.0") == .orderedSame)
        #expect(UpdateChecker.compareSemver("2.0.0", "1.99.0") == .orderedDescending)
    }

    @Test func compareWithDifferentLengths() {
        #expect(UpdateChecker.compareSemver("1.5", "1.5.0") == .orderedSame)
        #expect(UpdateChecker.compareSemver("1.5", "1.5.1") == .orderedAscending)
        #expect(UpdateChecker.compareSemver("1.6", "1.5.99") == .orderedDescending)
    }

    @Test func compareIgnoresPreReleaseSuffix() {
        // Only compare core version
        #expect(UpdateChecker.compareSemver("1.5.0-beta.1", "1.5.0") == .orderedSame)
    }
}

// MARK: - HotKeyConflictChecker

struct HotKeyConflictCheckerTests {

    @Test func detectsSpotlightConflict() {
        let conflict = HotKeyConflictChecker.conflict(
            keyCode: 49, // Space
            modifiers: .maskCommand
        )
        #expect(conflict?.name.contains("Spotlight") == true)
    }

    @Test func defaultOptionSpaceIsNotInList() {
        // Saybit 預設 ⌥Space 不在內建衝突清單裡
        let conflict = HotKeyConflictChecker.conflict(
            keyCode: 49,
            modifiers: .maskAlternate
        )
        #expect(conflict == nil)
    }

    @Test func detectsScreenshotConflict() {
        let conflict = HotKeyConflictChecker.conflict(
            keyCode: 21, // 4
            modifiers: [.maskCommand, .maskShift]
        )
        #expect(conflict?.name.contains("Screenshot") == true)
    }

    @Test func ignoresExtraModifierBits() {
        // 即使帶上 capslock/fn 等其他 bit，仍應命中
        let extraFlags: CGEventFlags = [.maskCommand, .maskAlphaShift]
        let conflict = HotKeyConflictChecker.conflict(
            keyCode: 12, // Q
            modifiers: extraFlags
        )
        #expect(conflict?.name.contains("Quit") == true)
    }
}

// MARK: - ModelPricingTable

struct ModelPricingTests {

    @Test func gpt41NanoPricingMatches() {
        let cost = ModelPricingTable.cost(model: "gpt-4.1-nano",
                                          promptTokens: 1000,
                                          completionTokens: 1000)
        // 0.0001 + 0.0004 = 0.0005
        #expect(cost.map { abs($0 - 0.0005) < 0.0001 } == true)
    }

    @Test func unknownModelReturnsNil() {
        let cost = ModelPricingTable.cost(model: "totally-fake-model-xyz",
                                          promptTokens: 1000,
                                          completionTokens: 1000)
        #expect(cost == nil)
    }

    @Test func emptyModelReturnsNil() {
        let cost = ModelPricingTable.cost(model: "",
                                          promptTokens: 100,
                                          completionTokens: 100)
        #expect(cost == nil)
    }

    @Test func formatUSDHandlesEdges() {
        #expect(ModelPricingTable.formatUSD(0) == "$0")
        #expect(ModelPricingTable.formatUSD(0.00001) == "<$0.0001")
        #expect(ModelPricingTable.formatUSD(0.1234) == "$0.1234")
    }

    @Test func providerPrefixedModelMatches() {
        // OpenRouter style "anthropic/claude-sonnet-4"
        let cost = ModelPricingTable.cost(model: "anthropic/claude-sonnet-4",
                                          promptTokens: 1000,
                                          completionTokens: 1000)
        // sonnet-4: 0.003 + 0.015 = 0.018
        #expect(cost.map { abs($0 - 0.018) < 0.0001 } == true)
    }
}

// MARK: - LM Studio URL normalization

struct LMStudioURLTests {

    @Test func bareOriginGetsFullSuffix() {
        #expect(SettingsStore.normalizeLMStudioURL("http://localhost:1234")
                == "http://localhost:1234/v1/chat/completions")
    }

    @Test func trailingSlashStripped() {
        #expect(SettingsStore.normalizeLMStudioURL("http://localhost:1234/")
                == "http://localhost:1234/v1/chat/completions")
    }

    @Test func alreadyHasV1() {
        #expect(SettingsStore.normalizeLMStudioURL("http://localhost:1234/v1")
                == "http://localhost:1234/v1/chat/completions")
    }

    @Test func alreadyFull() {
        #expect(SettingsStore.normalizeLMStudioURL("http://localhost:1234/v1/chat/completions")
                == "http://localhost:1234/v1/chat/completions")
    }

    @Test func whitespaceTrimmed() {
        #expect(SettingsStore.normalizeLMStudioURL("  http://localhost:1234  ")
                == "http://localhost:1234/v1/chat/completions")
    }

    @Test func remoteHostWithPort() {
        #expect(SettingsStore.normalizeLMStudioURL("http://192.168.0.10:1234/v1/")
                == "http://192.168.0.10:1234/v1/chat/completions")
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

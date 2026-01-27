//
//  LLMProvider.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/28.
//

import Foundation

struct LLMProvider: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let baseURL: String
    let extraHeaders: [String: String]
    let keyPlaceholder: String
    let modelHint: String
    let isBuiltIn: Bool

    // MARK: - Built-in Providers

    static let openRouter = LLMProvider(
        id: "openrouter",
        name: "OpenRouter",
        baseURL: "https://openrouter.ai/api/v1/chat/completions",
        extraHeaders: [
            "HTTP-Referer": "https://speakertyper.bashcat.net",
            "X-Title": "SpeakerTyper",
        ],
        keyPlaceholder: "sk-or-v1-...",
        modelHint: "openai/gpt-4.1-mini · anthropic/claude-sonnet-4 · google/gemini-2.5-flash",
        isBuiltIn: true
    )

    static let openAI = LLMProvider(
        id: "openai",
        name: "OpenAI",
        baseURL: "https://api.openai.com/v1/chat/completions",
        extraHeaders: [:],
        keyPlaceholder: "sk-...",
        modelHint: "gpt-4.1-mini · gpt-4.1 · gpt-4o",
        isBuiltIn: true
    )

    static let groq = LLMProvider(
        id: "groq",
        name: "Groq",
        baseURL: "https://api.groq.com/openai/v1/chat/completions",
        extraHeaders: [:],
        keyPlaceholder: "gsk_...",
        modelHint: "llama-3.3-70b-versatile · gemma2-9b-it",
        isBuiltIn: true
    )

    static let togetherAI = LLMProvider(
        id: "together",
        name: "Together AI",
        baseURL: "https://api.together.xyz/v1/chat/completions",
        extraHeaders: [:],
        keyPlaceholder: "...",
        modelHint: "meta-llama/Llama-3.3-70B-Instruct-Turbo · Qwen/Qwen2.5-72B-Instruct-Turbo",
        isBuiltIn: true
    )

    static let builtInProviders: [LLMProvider] = [.openRouter, .openAI, .groq, .togetherAI]

    // MARK: - Custom Provider Factory

    static func custom(id: String, name: String, baseURL: String) -> LLMProvider {
        LLMProvider(
            id: id,
            name: name,
            baseURL: baseURL,
            extraHeaders: [:],
            keyPlaceholder: "...",
            modelHint: "",
            isBuiltIn: false
        )
    }
}

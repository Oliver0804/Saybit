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
    let requiresAPIKey: Bool

    // Coding keys with default for requiresAPIKey (backward compat)
    init(id: String, name: String, baseURL: String, extraHeaders: [String: String],
         keyPlaceholder: String, modelHint: String, isBuiltIn: Bool, requiresAPIKey: Bool = true) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.extraHeaders = extraHeaders
        self.keyPlaceholder = keyPlaceholder
        self.modelHint = modelHint
        self.isBuiltIn = isBuiltIn
        self.requiresAPIKey = requiresAPIKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        extraHeaders = try container.decode([String: String].self, forKey: .extraHeaders)
        keyPlaceholder = try container.decode(String.self, forKey: .keyPlaceholder)
        modelHint = try container.decode(String.self, forKey: .modelHint)
        isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
        requiresAPIKey = try container.decodeIfPresent(Bool.self, forKey: .requiresAPIKey) ?? true
    }

    /// Ollama API base for fetching models: GET /api/tags
    var ollamaAPIBase: String? {
        guard id == "ollama" else { return nil }
        // baseURL is .../v1/chat/completions, extract origin
        guard let url = URL(string: baseURL),
              let scheme = url.scheme,
              let host = url.host else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    // MARK: - Built-in Providers

    static let openRouter = LLMProvider(
        id: "openrouter",
        name: "OpenRouter",
        baseURL: "https://openrouter.ai/api/v1/chat/completions",
        extraHeaders: [
            "HTTP-Referer": "https://saybit.bashcat.net",
            "X-Title": "Saybit",
        ],
        keyPlaceholder: "sk-or-v1-...",
        modelHint: "openai/gpt-4.1-nano · anthropic/claude-sonnet-4 · google/gemini-2.5-flash",
        isBuiltIn: true
    )

    static let openAI = LLMProvider(
        id: "openai",
        name: "OpenAI",
        baseURL: "https://api.openai.com/v1/chat/completions",
        extraHeaders: [:],
        keyPlaceholder: "sk-...",
        modelHint: "gpt-4.1-nano · gpt-4.1-mini · gpt-4o",
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

    static let ollama = LLMProvider(
        id: "ollama",
        name: "Ollama (本地)",
        baseURL: "http://localhost:11434/v1/chat/completions",
        extraHeaders: [:],
        keyPlaceholder: "",
        modelHint: "llama3 · qwen2.5 · gemma2 · mistral",
        isBuiltIn: true,
        requiresAPIKey: false
    )

    static let builtInProviders: [LLMProvider] = [.openRouter, .openAI, .groq, .togetherAI, .ollama]

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

    // MARK: - Ollama Helpers

    /// Fetch available models from Ollama (GET /api/tags)
    static func fetchOllamaModels(baseOrigin: String = "http://localhost:11434") async -> [String] {
        guard let url = URL(string: "\(baseOrigin)/api/tags") else { return [] }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return []
            }
            let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
            return decoded.models.map(\.name)
        } catch {
            return []
        }
    }

    /// Check if Ollama is running
    static func isOllamaRunning(baseOrigin: String = "http://localhost:11434") async -> Bool {
        guard let url = URL(string: "\(baseOrigin)/api/tags") else { return false }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 2
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}

// MARK: - Ollama API Response

private struct OllamaTagsResponse: Decodable {
    let models: [OllamaModel]

    struct OllamaModel: Decodable {
        let name: String
    }
}

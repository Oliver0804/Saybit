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
        modelHint: "deepseek/deepseek-v4-flash · deepseek/deepseek-v4-pro · openai/gpt-4.1-nano · google/gemini-2.5-flash",
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

    static let deepSeek = LLMProvider(
        id: "deepseek",
        name: "DeepSeek",
        baseURL: "https://api.deepseek.com/chat/completions",
        extraHeaders: [:],
        keyPlaceholder: "sk-...",
        modelHint: "deepseek-chat · deepseek-reasoner",
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

    static let lmStudio = LLMProvider(
        id: "lmstudio",
        name: "LM Studio (本地)",
        baseURL: "http://localhost:1234/v1/chat/completions",
        extraHeaders: [:],
        keyPlaceholder: "lm-studio-...",
        modelHint: "",
        isBuiltIn: true,
        requiresAPIKey: false
    )

    static let builtInProviders: [LLMProvider] = [.openRouter, .openAI, .deepSeek, .groq, .togetherAI, .ollama, .lmStudio]

    // MARK: - Default Model

    /// 給定 provider id 回傳適合該 provider 的「常用」預設模型名稱。
    /// 給切換 provider 後預先填模型用，使用者仍可改成自己想用的。
    /// 本地服務（ollama / lmstudio / 自訂）回 nil — 由抓回的 model list 決定。
    static func defaultModel(for providerID: String) -> String? {
        switch providerID {
        case "openrouter": "deepseek/deepseek-v4-flash"
        case "openai":     "gpt-4.1-nano"
        case "deepseek":   "deepseek-chat"
        case "groq":       "llama-3.3-70b-versatile"
        case "together":   "meta-llama/Llama-3.3-70B-Instruct-Turbo"
        default: nil
        }
    }

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

    // MARK: - OpenAI-Compatible Models Endpoint

    /// 從 chat/completions 的 baseURL 推導出 /models 端點。
    /// e.g. ".../v1/chat/completions" → ".../v1/models"
    ///      ".../chat/completions"    → ".../models"
    var modelsEndpoint: URL? {
        guard let url = URL(string: baseURL),
              let scheme = url.scheme,
              let host = url.host else { return nil }
        var parts = url.pathComponents.filter { $0 != "/" }
        if parts.last == "completions" { parts.removeLast() }
        if parts.last == "chat" { parts.removeLast() }
        parts.append("models")
        let port = url.port.map { ":\($0)" } ?? ""
        let path = "/" + parts.joined(separator: "/")
        return URL(string: "\(scheme)://\(host)\(port)\(path)")
    }

    /// 從任何 OpenAI 相容的 /v1/models 端點抓取可用模型清單。
    /// 適用：OpenAI、DeepSeek、OpenRouter、Groq、Together 等。
    static func fetchOpenAIModels(provider: LLMProvider) async throws -> [String] {
        guard let url = provider.modelsEndpoint else {
            throw NSError(domain: "LLMProvider", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "無法解析 models 端點：\(provider.baseURL)"])
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if let key = KeychainHelper.loadAPIKey(for: provider.id), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        for (k, v) in provider.extraHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "LLMProvider", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)：\(body.prefix(200))"])
        }
        let decoded = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        return decoded.data.map(\.id).sorted()
    }

    // MARK: - LM Studio Helpers

    /// Fetch available LLM models from LM Studio (GET /api/v1/models)
    static func fetchLMStudioModels(baseOrigin: String = "http://localhost:1234") async -> [String] {
        guard let url = URL(string: "\(baseOrigin)/api/v1/models") else { return [] }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            // 帶上 API key（如果有）
            if let key = KeychainHelper.loadAPIKey(for: "lmstudio"), !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return []
            }
            let decoded = try JSONDecoder().decode(LMStudioModelsResponse.self, from: data)
            // 只回傳 LLM 模型，排除 embedding 模型
            return decoded.models
                .filter { $0.type == "llm" }
                .map(\.key)
        } catch {
            return []
        }
    }

    /// Check if LM Studio is running
    static func isLMStudioRunning(baseOrigin: String = "http://localhost:1234") async -> Bool {
        guard let url = URL(string: "\(baseOrigin)/api/v1/models") else { return false }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            if let key = KeychainHelper.loadAPIKey(for: "lmstudio"), !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
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

// MARK: - OpenAI-Compatible /v1/models Response

private struct OpenAIModelsResponse: Decodable {
    let data: [Model]
    struct Model: Decodable { let id: String }
}

// MARK: - LM Studio API Response

private struct LMStudioModelsResponse: Decodable {
    let models: [LMStudioModel]

    struct LMStudioModel: Decodable {
        let type: String       // "llm" or "embedding"
        let key: String        // model identifier (e.g. "google/gemma-3-4b")
    }
}

// MARK: - Ollama API Response

private struct OllamaTagsResponse: Decodable {
    let models: [OllamaModel]

    struct OllamaModel: Decodable {
        let name: String
    }
}

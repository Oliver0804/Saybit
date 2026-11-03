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

    /// Apple Intelligence 本機模型（FoundationModels）：離線、免費、免 Key。
    /// baseURL 只是佔位（OpenRouterClient 依 id 分流，不會真的連線）
    static let appleOnDevice = LLMProvider(
        id: AppleOnDeviceLLM.providerID,
        name: "Apple 本機 (離線)",
        baseURL: "https://apple-on-device.invalid",
        extraHeaders: [:],
        keyPlaceholder: "",
        modelHint: "",
        isBuiltIn: true,
        requiresAPIKey: false
    )

    static let builtInProviders: [LLMProvider] = [.openRouter, .openAI, .deepSeek, .groq, .togetherAI, .ollama, .lmStudio, .appleOnDevice]

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
        case AppleOnDeviceLLM.providerID: AppleOnDeviceLLM.modelName
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

    // MARK: - Base URL Validation

    enum BaseURLValidation: Equatable {
        /// https，或 http 但 host 在本機 / 區網
        case ok
        /// http 且 host 為公開位址：API key 會明文外送
        case insecureRemote
        /// 無法解析出 scheme + host，或 scheme 不是 http(s)
        case invalid
    }

    /// 送出 API key 前檢查端點：https → ok；http 只允許 localhost / 127.0.0.0/8 / ::1 /
    /// 10.x / 172.16–31.x / 192.168.x / *.local；其他 http → insecureRemote；解析失敗 → invalid。
    nonisolated static func validateBaseURL(_ raw: String) -> BaseURLValidation {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(),
              let rawHost = comps.host, !rawHost.isEmpty else { return .invalid }
        switch scheme {
        case "https":
            return .ok
        case "http":
            return isLocalHost(rawHost) ? .ok : .insecureRemote
        default:
            return .invalid
        }
    }

    nonisolated private static func isLocalHost(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        if host == "::1" || host == "0:0:0:0:0:0:0:1" { return true }

        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber),
                  let v = Int(p), (0...255).contains(v) else { return false }
            octets.append(v)
        }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    /// `validateBaseURL` 的中文說明（.ok 回 nil）
    nonisolated static func baseURLValidationMessage(_ v: BaseURLValidation, url: String) -> String? {
        switch v {
        case .ok: return nil
        case .insecureRemote:
            return "端點 \(url) 使用未加密的 http:// 連到外部主機，API Key 與內容會以明文傳送；請改用 https://（http 僅允許本機或區網位址）"
        case .invalid:
            return "端點 URL 無效：\(url)（需為 https://… 或本機 / 區網的 http://…）"
        }
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
        let validation = validateBaseURL(provider.baseURL)
        if let msg = baseURLValidationMessage(validation, url: provider.baseURL) {
            throw NSError(domain: "LLMProvider", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: msg])
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

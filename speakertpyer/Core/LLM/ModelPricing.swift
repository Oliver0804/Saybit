//
//  ModelPricing.swift
//  speakertpyer
//
//  常見模型的概略單價（USD per 1K tokens）。
//  實際費用以服務商當下定價為準，僅作粗估顯示。
//

import Foundation

struct ModelPricing {
    /// USD per 1,000 tokens
    let inputPer1K: Double
    let outputPer1K: Double

    /// 計算總價（USD）。
    func cost(promptTokens: Int, completionTokens: Int) -> Double {
        let inCost  = Double(promptTokens)     / 1000.0 * inputPer1K
        let outCost = Double(completionTokens) / 1000.0 * outputPer1K
        return inCost + outCost
    }

    /// 是否屬於本地（成本為 0）。
    var isFree: Bool { inputPer1K == 0 && outputPer1K == 0 }
}

enum ModelPricingTable {
    static let zero = ModelPricing(inputPer1K: 0, outputPer1K: 0)

    /// 內建價目表。比對方式見 `price(for:)`：去掉 `provider/` 前綴後做前綴比對（含邊界）。
    /// 第一個命中的 entry 會被採用，故順序由「具體 → 通用」排列。
    private static let table: [(pattern: String, price: ModelPricing)] = [
        // OpenAI
        ("gpt-4.1-nano",                   .init(inputPer1K: 0.0001, outputPer1K: 0.0004)),
        ("gpt-4.1-mini",                   .init(inputPer1K: 0.0004, outputPer1K: 0.0016)),
        ("gpt-4.1",                        .init(inputPer1K: 0.002,  outputPer1K: 0.008)),
        ("gpt-4o-mini",                    .init(inputPer1K: 0.00015, outputPer1K: 0.0006)),
        ("gpt-4o",                         .init(inputPer1K: 0.0025, outputPer1K: 0.010)),
        ("o1-mini",                        .init(inputPer1K: 0.003,  outputPer1K: 0.012)),
        ("o1",                             .init(inputPer1K: 0.015,  outputPer1K: 0.060)),

        // Anthropic
        ("claude-haiku-4-5",               .init(inputPer1K: 0.001,  outputPer1K: 0.005)),
        ("claude-sonnet-4-7",              .init(inputPer1K: 0.003,  outputPer1K: 0.015)),
        ("claude-sonnet-4-6",              .init(inputPer1K: 0.003,  outputPer1K: 0.015)),
        ("claude-sonnet-4",                .init(inputPer1K: 0.003,  outputPer1K: 0.015)),
        // Opus 4.5 起降價為 $5 / $25 per 1M；4.0 / 4.1 仍為 $15 / $75
        ("claude-opus-4-7",                .init(inputPer1K: 0.005,  outputPer1K: 0.025)),
        ("claude-opus-4-6",                .init(inputPer1K: 0.005,  outputPer1K: 0.025)),
        ("claude-opus-4-5",                .init(inputPer1K: 0.005,  outputPer1K: 0.025)),
        ("claude-opus-4",                  .init(inputPer1K: 0.015,  outputPer1K: 0.075)),

        // Google
        ("gemini-2.5-flash",               .init(inputPer1K: 0.000075, outputPer1K: 0.0003)),
        ("gemini-2.5-pro",                 .init(inputPer1K: 0.00125,  outputPer1K: 0.010)),
        ("gemini-2.0-flash",               .init(inputPer1K: 0.0001,   outputPer1K: 0.0004)),

        // DeepSeek
        ("deepseek-v4-flash",              .init(inputPer1K: 0.00014, outputPer1K: 0.00028)),
        ("deepseek-v4-pro",                .init(inputPer1K: 0.00055, outputPer1K: 0.00219)),
        ("deepseek-reasoner",              .init(inputPer1K: 0.00055, outputPer1K: 0.00219)),
        ("deepseek-chat",                  .init(inputPer1K: 0.00014, outputPer1K: 0.00028)),
        ("deepseek-flash",                 .init(inputPer1K: 0.00007, outputPer1K: 0.00028)),
        ("deepseek-pro",                   .init(inputPer1K: 0.00055, outputPer1K: 0.00219)),
        ("deepseek-v3",                    .init(inputPer1K: 0.00014, outputPer1K: 0.00028)),

        // Groq（隨方案變動，僅參考）
        ("llama-3.3-70b",                  .init(inputPer1K: 0.00059, outputPer1K: 0.00079)),
        ("llama-3.1-70b",                  .init(inputPer1K: 0.00059, outputPer1K: 0.00079)),
        ("llama-3.1-8b",                   .init(inputPer1K: 0.00005, outputPer1K: 0.00008)),
        ("gemma2-9b-it",                   .init(inputPer1K: 0.0002,  outputPer1K: 0.0002)),

        // Together AI
        ("qwen2.5-72b",                    .init(inputPer1K: 0.0012,  outputPer1K: 0.0012)),
    ]

    /// 從模型名稱推估單價；找不到回傳 nil（呼叫端可決定要不要當免費）。
    /// 去掉 `provider/` 前綴（如 `openai/`、`meta-llama/`）與 `:tag` 後綴，`.` 視同 `-`，
    /// 再做前綴比對且要求邊界（下一字元非英數），避免 `sao10k/...` 被 `o1` 之類的子字串誤配。
    static func price(for model: String) -> ModelPricing? {
        let name = normalize(model)
        guard !name.isEmpty else { return nil }
        for (pattern, price) in table {
            let p = normalize(pattern)
            guard name.hasPrefix(p) else { continue }
            let rest = name.dropFirst(p.count)
            if let next = rest.first, next.isLetter || next.isNumber { continue }
            return price
        }
        return nil
    }

    private static func normalize(_ model: String) -> String {
        var lower = model.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = lower.lastIndex(of: "/") { lower = String(lower[lower.index(after: slash)...]) }
        if let colon = lower.firstIndex(of: ":") { lower = String(lower[..<colon]) }
        return lower.replacingOccurrences(of: ".", with: "-")
    }

    /// 計算成本：本地服務（ollama/lmstudio prefix）視為 0；未知模型回 nil。
    static func cost(model: String, promptTokens: Int, completionTokens: Int) -> Double? {
        let lower = model.lowercased()
        if lower.isEmpty { return nil }
        // 本地：常見前綴或無斜線且明顯為本地名（保守起見只認明確標記）
        if lower.hasPrefix("local/") || lower.hasPrefix("ollama/") {
            return 0
        }
        // OpenRouter 免費版模型（`…:free`）
        if lower.hasSuffix(":free") { return 0 }
        guard let p = price(for: model) else { return nil }
        return p.cost(promptTokens: promptTokens, completionTokens: completionTokens)
    }

    /// 格式化美元成本：< 0.01 顯示 4 位小數，否則 4 位。
    static func formatUSD(_ cost: Double) -> String {
        if cost == 0 { return "$0" }
        if cost < 0.0001 { return "<$0.0001" }
        return String(format: "$%.4f", cost)
    }
}

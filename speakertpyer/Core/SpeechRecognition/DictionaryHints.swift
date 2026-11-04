//
//  DictionaryHints.swift
//  speakertpyer
//
//  讓個人字典直接作用在「辨識」這一層，而不只靠 LLM：
//    1. Apple 語音辨識：把偏好寫法當 contextualStrings 提示，提高專有名詞命中率
//    2. 所有引擎（含 SenseVoice / Whisper）：辨識完先做「原始詞 → 偏好寫法」字面替換，
//       LLM 收到的就已經是正確寫法（本機小模型也不會漏換）
//

import Foundation

enum DictionaryHints {
    /// Apple Speech 的 contextualStrings（偏好寫法，去重，最多 100 個）
    private(set) static var contextualStrings: [String] = []
    private static var entries: [String: String] = [:]
    private static var regex: NSRegularExpression?

    /// 重新讀取字典（錄音開始時呼叫；字典很小，讀取成本可忽略）
    static func refresh(records: RecordsRepository) {
        let dict = records.loadPersonalDictionary() ?? [:]
        guard dict != entries || regex == nil else { return }
        entries = dict

        var seen = Set<String>()
        contextualStrings = dict.values
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(100)
            .map { $0 }

        // 長詞優先，避免短詞先吃掉長詞的一部分
        let terms = dict.keys
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        // 英文詞要整字比對（line 不能吃掉 deadline / online 裡的 line）
        func pattern(_ term: String) -> String {
            let escaped = NSRegularExpression.escapedPattern(for: term)
            let lead = term.first.map { $0.isASCII && ($0.isLetter || $0.isNumber) } ?? false
            let trail = term.last.map { $0.isASCII && ($0.isLetter || $0.isNumber) } ?? false
            return (lead ? "(?<![A-Za-z0-9])" : "") + escaped + (trail ? "(?![A-Za-z0-9])" : "")
        }
        regex = terms.isEmpty ? nil : try? NSRegularExpression(
            pattern: terms.map(pattern).joined(separator: "|"),
            options: [.caseInsensitive]
        )
    }

    /// 單次掃描替換（不會連鎖替換）
    static func apply(_ text: String) -> String {
        guard let regex, !text.isEmpty else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        // key 比對不分大小寫
        let lookup = Dictionary(entries.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        let out = NSMutableString(string: text)
        for m in matches.reversed() {
            let found = ns.substring(with: m.range)
            if let replacement = lookup[found.lowercased()] {
                out.replaceCharacters(in: m.range, with: replacement)
            }
        }
        return out as String
    }
}

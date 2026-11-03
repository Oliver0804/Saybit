//
//  DictionaryAutoLearner.swift
//  speakertpyer
//
//  自動學習字典：文字輸入後持續觀察同一個輸入框約 30 秒，
//  若使用者只手動改了其中一個詞（例如「鄭」→「John」），就把這組更正加進個人字典，
//  下次辨識 / 潤飾就會自動用對的寫法。
//  只接受「輸入內容範圍內、單一處、短詞」的修改，大幅改寫、刪除、送出訊息都不會學。
//

#if os(macOS)
import AppKit
import ApplicationServices

@MainActor
final class DictionaryAutoLearner {
    static let shared = DictionaryAutoLearner()

    private var task: Task<Void, Never>?
    private let log = AppLogger.shared

    /// 觀察時間（秒）與輪詢間隔
    private let watchDuration: TimeInterval = 30
    private let pollInterval: Duration = .seconds(2)
    private let maxTermLength = 20
    /// 輸入框內容超過這個字數就不觀察（每 2 秒整份讀出來太重）
    nonisolated private static let maxDocumentCharacters = 20_000
    /// 拉丁字更正最多允許的編輯距離 / 長度差
    private let maxLatinEditDistance = 2
    private let maxLatinLengthDelta = 2

    /// AXUIElement 是 CFType（thread-safe），包一層才能跨 Task 傳遞
    nonisolated private struct ElementBox: @unchecked Sendable { let element: AXUIElement }

    nonisolated private enum ReadResult: Sendable {
        case value(String)
        case tooLarge
        case unavailable
    }

    func watch(injected text: String, records: RecordsRepository, after typingTime: TimeInterval = 0) {
        task?.cancel()
        let injected = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard injected.count >= 2,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }

        task = Task { [weak self] in
            // 等貼上 / 逐字輸入完成，取得基準內容
            try? await Task.sleep(for: .seconds(typingTime + 0.6))
            guard !Task.isCancelled, Self.frontmostPID() == pid else { return }

            // AX 同步呼叫可能卡住，全部在背景執行，不佔主執行緒
            let initial = await Task.detached(priority: .utility) { () -> (ElementBox, ReadResult)? in
                guard let element = Self.focusedElement(pid: pid) else { return nil }
                return (ElementBox(element: element), Self.readValue(of: element))
            }.value
            guard !Task.isCancelled, let (box, firstRead) = initial,
                  case .value(let before) = firstRead,
                  let range = before.range(of: injected) else { return }
            let injStart = before.distance(from: before.startIndex, to: range.lowerBound)
            let injEnd = injStart + injected.count

            var latest = before
            let deadline = Date().addingTimeInterval(self?.watchDuration ?? 30)
            while Date() < deadline {
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(2))
                // 取消（又有新的輸入）就放棄這次觀察
                if Task.isCancelled { return }
                // 使用者切到別的 App 就停止觀察
                guard Self.frontmostPID() == pid else { break }
                let read = await Task.detached(priority: .utility) { () -> ReadResult? in
                    // 焦點換到別的輸入框就停止觀察
                    guard let current = Self.focusedElement(pid: pid), CFEqual(current, box.element) else { return nil }
                    return Self.readValue(of: box.element)
                }.value
                guard let read else { break }
                switch read {
                case .value(let v): latest = v
                case .tooLarge: return
                case .unavailable: continue
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.learn(before: before, after: latest, injectedRange: injStart..<injEnd, records: records)
        }
    }

    private static func frontmostPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    // MARK: - Filters

    /// 數字、日期、時間相關字元：這類修改通常是「改事實」（三點→四點），不是錯字更正
    nonisolated static let numericCharacters: Set<Character> = Set("零〇一二兩两三四五六七八九十百千萬万億亿年月日")
    // 「點 / 時 / 分 / 號」不列入：它們常出現在一般詞（重點、時候、部分、號碼），而「三點→四點」這類修改已由數字本身擋下

    nonisolated static func containsNumeric(_ s: String) -> Bool {
        s.contains { $0.isNumber || numericCharacters.contains($0) }
    }

    nonisolated static func isLatin(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy(\.isASCII)
    }

    /// Levenshtein 編輯距離（以 Character 計）
    nonisolated static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = x[i - 1] == y[j - 1]
                    ? prev[j - 1]
                    : min(prev[j - 1], prev[j], cur[j - 1]) + 1
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }

    /// 這組 old → new 是否像「錯字更正」而值得學
    nonisolated static func isLearnableCorrection(old: String, new: String, maxDistance: Int = 2, maxLengthDelta: Int = 2) -> Bool {
        if containsNumeric(old) || containsNumeric(new) { return false }
        if isLatin(old) && isLatin(new) {
            guard abs(old.count - new.count) <= maxLengthDelta,
                  editDistance(old, new) <= maxDistance else { return false }
        }
        return true
    }

    // MARK: - Diff

    private func learn(before: String, after: String, injectedRange: Range<Int>, records: RecordsRepository) {
        // 忽略結尾空白 / 換行（智慧送出的 Enter、自動加的換行不算修改）
        func trimTrailing(_ x: String) -> [Character] {
            var c = Array(x)
            while let last = c.last, last.isWhitespace || last.isNewline { c.removeLast() }
            return c
        }
        let a = trimTrailing(before), b = trimTrailing(after)
        guard a != b else { return }

        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }

        // 英文字詞擴展到完整單字（Jon → John 才不會學成 "" → "h"）
        func isWord(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
        while p > 0, isWord(a[p - 1]) { p -= 1 }
        while s > 0, isWord(a[a.count - s]) { s -= 1 }

        // 純插入 / 純刪除不是「把錯字改對」，不學
        guard a.count - s > p, b.count - s > p else { return }

        // 中文更正至少取兩個字（「氣→汽」擴成「天氣→天汽」），避免單字詞誤傷其他句子
        func isCJK(_ c: Character) -> Bool { c.unicodeScalars.first?.properties.isIdeographic ?? false }
        var expandGuard = 0
        while (a.count - s - p < 2 || b.count - s - p < 2), expandGuard < 2,
              a[p ..< (a.count - s)].contains(where: isCJK) || b[p ..< (b.count - s)].contains(where: isCJK) {
            expandGuard += 1
            if p > 0, isCJK(a[p - 1]) {
                p -= 1
            } else if s > 0, isCJK(a[a.count - s]) {
                s -= 1
            } else {
                break
            }
        }

        let oldRange = p ..< (a.count - s)
        let newRange = p ..< (b.count - s)
        guard oldRange.lowerBound >= injectedRange.lowerBound,
              oldRange.upperBound <= injectedRange.upperBound else { return }

        let old = String(a[oldRange]).trimmingCharacters(in: .whitespaces)
        let new = String(b[newRange]).trimmingCharacters(in: .whitespaces)
        guard !old.isEmpty, !new.isEmpty, old != new,
              old.count <= maxTermLength, new.count <= maxTermLength,
              !old.contains(where: \.isNewline), !new.contains(where: \.isNewline),
              old.contains(where: { $0.isLetter }), new.contains(where: { $0.isLetter }) else { return }
        // 多處修改會被合併成一大段（中間夾著標點）→ 不是單一詞的更正，不學
        let separators = CharacterSet(charactersIn: "，。！？、；：,!?;:「」『』()（）[]\"")
        guard old.rangeOfCharacter(from: separators) == nil,
              new.rangeOfCharacter(from: separators) == nil else { return }
        // 數字 / 日期時間的修改、拉丁字大改都不是錯字更正
        guard Self.isLearnableCorrection(old: old, new: new,
                                         maxDistance: maxLatinEditDistance,
                                         maxLengthDelta: maxLatinLengthDelta) else {
            log.info("自動學習字典：修改不像錯字更正，略過（\(old.count) → \(new.count) 字）", category: "Dictionary")
            return
        }

        if records.addDictionaryEntry(term: old, preferred: new) {
            DictionaryHints.refresh(records: records)
            // 日誌只記長度，不落盤使用者內容
            log.info("自動學習字典: \(old.count) 字 → \(new.count) 字", category: "Dictionary")
            NSSound(named: .init("Glass"))?.play()
            OverlayWindowController.shared.showTransientNotice(text: "已學習「\(old)」→「\(new)」") { [weak self] in
                self?.removeEntry(term: old, preferred: new, records: records)
            }
        }
    }

    /// 撤銷自動學習：刪掉剛加入的詞條
    private func removeEntry(term: String, preferred: String, records: RecordsRepository) {
        let context = records.container.viewContext
        let request = PersonalDictionaryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "term ==[c] %@ AND preferred == %@", term, preferred)
        guard let entries = try? context.fetch(request), !entries.isEmpty else { return }
        entries.forEach(context.delete)
        do {
            try context.save()
        } catch {
            context.rollback()
            log.error("撤銷自動學習字典失敗: \(error.localizedDescription)", category: "Dictionary")
            return
        }
        DictionaryHints.refresh(records: records)
        log.info("已撤銷自動學習字典詞條", category: "Dictionary")
    }

    // MARK: - AX（只在背景執行緒呼叫）

    nonisolated private static func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.5)
        return element
    }

    nonisolated private static func readValue(of element: AXUIElement) -> ReadResult {
        var count: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
           let n = count as? Int, n > maxDocumentCharacters {
            return .tooLarge
        }
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let string = value as? String else { return .unavailable }
        return string.count > maxDocumentCharacters ? .tooLarge : .value(string)
    }
}
#endif

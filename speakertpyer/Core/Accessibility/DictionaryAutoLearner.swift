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

    func watch(injected text: String, records: RecordsRepository, after typingTime: TimeInterval = 0) {
        task?.cancel()
        let injected = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard injected.count >= 2,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let element = Self.focusedElement(pid: pid) else { return }

        task = Task { [weak self] in
            guard let self else { return }
            // 等貼上 / 逐字輸入完成，取得基準內容
            try? await Task.sleep(for: .seconds(typingTime + 0.6))
            guard !Task.isCancelled, let before = Self.value(of: element),
                  let range = before.range(of: injected) else { return }
            let injStart = before.distance(from: before.startIndex, to: range.lowerBound)
            let injEnd = injStart + injected.count

            var latest = before
            let deadline = Date().addingTimeInterval(watchDuration)
            while Date() < deadline {
                try? await Task.sleep(for: pollInterval)
                if Task.isCancelled { break }
                // 焦點換到別的輸入框就停止觀察
                guard let current = Self.focusedElement(pid: pid), CFEqual(current, element) else { break }
                if let v = Self.value(of: element) { latest = v }
            }
            self.learn(before: before, after: latest, injectedRange: injStart..<injEnd, records: records)
        }
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

        if records.addDictionaryEntry(term: old, preferred: new) {
            DictionaryHints.refresh(records: records)
            log.info("自動學習字典: \(old) → \(new)", category: "Dictionary")
            NSSound(named: .init("Glass"))?.play()
        }
    }

    // MARK: - AX

    private static func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return (focused as! AXUIElement)
    }

    private static func value(of element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
#endif

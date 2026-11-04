//
//  TextInjector.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import AppKit
import CoreGraphics

enum TextInjector {
    private static let log = AppLogger.shared

    /// 逐字輸入：每個 CGEvent 最多帶幾個 UTF-16 單元（不拆開同一個字元）
    static let maxUTF16PerEvent = 20
    /// 逐字輸入：每個事件之間的間隔
    private static let keystrokeInterval: TimeInterval = 0.02

    /// 目前進行中的逐字輸入；新的 inject 或 cancelTyping() 會取消它
    private static var typingTask: Task<Void, Never>?

    /// 輸入完成大約需要的時間（逐字模式每個事件 20ms），讓智慧送出等打完再按 Enter
    static func estimatedDuration(_ text: String, mode: InjectionMode) -> TimeInterval {
        switch mode {
        case .keypress: return Double(keypressChunks(text).count) * keystrokeInterval + 0.15
        case .paste, .replaceSelection: return 0.15
        }
    }

    /// 統一入口：根據模式注入文字
    /// - Parameter context: 目標 App（決定逐字模式換行要不要加 Shift）；nil 時以目前前景 App 判斷
    static func inject(_ text: String, mode: InjectionMode = .paste, context: AppContext? = nil) {
        cancelTyping()
        switch mode {
        case .paste:
            injectViaPaste(text)
        case .keypress:
            simulateKeypress(text, context: context)
        case .replaceSelection:
            replaceSelection(text)
        }
    }

    /// 停止尚未打完的逐字輸入
    static func cancelTyping() {
        guard let task = typingTask else { return }
        task.cancel()
        typingTask = nil
    }

    /// 模擬按下 Enter/Return 鍵
    static func simulateEnter() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key code 0x24 = Return key
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false) else {
            return
        }

        // 確保不帶任何修飾鍵（避免 Cmd+V 殘留 flags 導致 Cmd+Enter）
        keyDown.flags = []
        keyUp.flags = []

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    // MARK: - Paste Mode (Cmd+V)

    /// Inject text via clipboard paste (Cmd+V) with clipboard save/restore
    private static func injectViaPaste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let backup = ClipboardBackup.snapshot(pasteboard)

        pasteboard.clearContents()
        // 標 TransientType：剪貼簿管理器不會把每句聽寫記成一筆歷史
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: ClipboardBackup.transientType)
        pasteboard.writeObjects([item])
        let ourChangeCount = pasteboard.changeCount
        let targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            simulatePaste()

            // 等目標 App 真的貼上才還原剪貼簿（慢速 App 0.5s 內可能還沒讀剪貼簿）
            await waitForPasteToLand(text, pid: targetPID)

            // 僅在剪貼簿仍是我們寫入的內容時還原，避免覆寫使用者期間的新複製
            guard pasteboard.changeCount == ourChangeCount else { return }
            ClipboardBackup.restore(backup, to: pasteboard)
        }
    }

    private enum PasteProbe { case landed, notYet, unreadable }

    /// 輪詢焦點元素的值，含注入文字的結尾即視為貼上完成；最多等 2 秒。
    /// 目標不提供 AX 值（多數 Electron / 自繪 App）時退回固定等待 0.8 秒。
    private static func waitForPasteToLand(_ text: String, pid: pid_t?) async {
        let probe = String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(40))
        guard let pid, !probe.isEmpty else {
            try? await Task.sleep(for: .milliseconds(800))
            return
        }
        let start = Date()
        while Date().timeIntervalSince(start) < 2.0 {
            try? await Task.sleep(for: .milliseconds(100))
            let result = await Task.detached(priority: .userInitiated) {
                probeFocusedValue(pid: pid, contains: probe)
            }.value
            switch result {
            case .landed:
                return
            case .unreadable:
                let remaining = 0.8 - Date().timeIntervalSince(start)
                if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
                return
            case .notYet:
                continue
            }
        }
        log.info("貼上 2 秒內未在焦點欄位偵測到注入文字，照常還原剪貼簿", category: "Inject")
    }

    private nonisolated static func probeFocusedValue(pid: pid_t, contains probe: String) -> PasteProbe {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .unreadable }
        let element = focused as! AXUIElement
        // 超大文件不整份讀出來比對
        var count: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
           let n = count as? Int, n > 200_000 {
            return .unreadable
        }
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let string = value as? String else { return .unreadable }
        return string.contains(probe) ? .landed : .notYet
    }

    // MARK: - Keypress Mode (逐字輸入)

    enum KeypressChunk: Equatable {
        /// 以 unicode string 送出的一段文字（≤ maxUTF16PerEvent 個 UTF-16 單元）
        case text([UInt16])
        /// 換行：送真正的 Return 鍵（virtualKey 0x24）
        case newline
    }

    /// 把文字切成逐字輸入的事件單位：換行獨立成 Return 鍵，其餘每段最多 20 個 UTF-16 單元
    static func keypressChunks(_ text: String) -> [KeypressChunk] {
        var chunks: [KeypressChunk] = []
        var buffer: [UInt16] = []
        for char in text {
            if char.isNewline {
                if !buffer.isEmpty { chunks.append(.text(buffer)); buffer = [] }
                chunks.append(.newline)
                continue
            }
            let units = Array(String(char).utf16)
            if !buffer.isEmpty, buffer.count + units.count > maxUTF16PerEvent {
                chunks.append(.text(buffer))
                buffer = []
            }
            buffer.append(contentsOf: units)
        }
        if !buffer.isEmpty { chunks.append(.text(buffer)) }
        return chunks
    }

    /// 模擬逐字鍵盤輸入，適合不支援貼上的應用程式。
    /// 單一可取消的 Task；每個事件前確認前景 App 沒換，換了就停止，避免剩下的字打進別的 App。
    private static func simulateKeypress(_ text: String, context: AppContext?) {
        let chunks = keypressChunks(text)
        guard !chunks.isEmpty else { return }

        let front = NSWorkspace.shared.frontmostApplication
        let startPID = front?.processIdentifier
        let target = context ?? AppContext(
            appName: front?.localizedName ?? "",
            bundleIdentifier: front?.bundleIdentifier,
            selectedText: nil
        )
        // 聊天類 App 的 Enter 是送出，換行要用 Shift+Enter
        let newlineFlags: CGEventFlags = target.contextCategory == .chatMessaging ? .maskShift : []

        typingTask = Task { @MainActor in
            let source = CGEventSource(stateID: .hidSystemState)
            for (index, chunk) in chunks.enumerated() {
                if Task.isCancelled {
                    log.info("逐字輸入已取消（剩 \(chunks.count - index) 段）", category: "Inject")
                    return
                }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != startPID {
                    log.error("逐字輸入中前景 App 已切換，停止輸入（剩 \(chunks.count - index) 段）", category: "Inject")
                    return
                }
                postKeypress(chunk, source: source, newlineFlags: newlineFlags)
                try? await Task.sleep(for: .seconds(keystrokeInterval))
            }
        }
    }

    private static func postKeypress(_ chunk: KeypressChunk, source: CGEventSource?, newlineFlags: CGEventFlags) {
        switch chunk {
        case .newline:
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false) else { return }
            down.flags = newlineFlags
            up.flags = newlineFlags
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        case .text(let units):
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            down.flags = []
            up.flags = []
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Replace Selection Mode (Delete + Paste)

    /// 先刪除選取文字，再貼上新文字
    private static func replaceSelection(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)

        // 模擬 Delete/Backspace 刪除選取內容
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: true),
           let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: false) {
            keyDown.flags = []
            keyUp.flags = []
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }

        // 短暫延遲後貼上
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            injectViaPaste(text)
        }
    }

    // MARK: - Private

    private static func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key code 9 = V key
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

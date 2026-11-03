//
//  TextExtractor.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import AppKit
import ApplicationServices

enum TextExtractor {
    private static let log = AppLogger.shared

    /// Get the current frontmost app context including selected text.
    ///
    /// 整段保證不在 caller 的 actor（含 MainActor）上跑：
    /// - AX 同步 API 與 AppleScript 都可能卡 50–500ms（目標 app 卡住、繁忙）
    /// - 用 Task.detached 把同步段隔離到 background priority pool
    static func getCurrentContext() async -> AppContext {
        // NSWorkspace.frontmostApplication 必須在 main thread 讀
        let (appName, bundleID, pid): (String, String?, pid_t) = await MainActor.run {
            guard let app = NSWorkspace.shared.frontmostApplication else {
                return ("Unknown", nil, pid_t(-1))
            }
            return (app.localizedName ?? "Unknown", app.bundleIdentifier, app.processIdentifier)
        }

        guard pid > 0 else { return .empty }

        // Strategy 1: AX API — 在 detached background pool 跑，不阻塞 caller actor
        let axResult = await Task.detached(priority: .userInitiated) {
            getSelectedTextViaAX(pid: pid)
        }.value

        var selectedText: String?
        switch axResult.selection {
        case .text(let text):
            selectedText = text
        case .emptySelection:
            // AX 明確回報「沒有選取」：不送 ⌘C（VS Code 會複製整行、Finder 會複製檔案）
            selectedText = nil
        case .unsupported:
            // Strategy 2: Clipboard-based Cmd+C (內部自帶 async sleep)
            if shouldUseClipboardFallback(bundleID: bundleID, role: axResult.role) {
                log.info("AX API 不支援選取文字（role=\(axResult.role ?? "nil")），嘗試 clipboard fallback", category: "TextExtract")
                selectedText = await getSelectedTextViaClipboard()
            } else {
                log.info("AX API 不支援選取文字，role=\(axResult.role ?? "nil") 不符或 App 在排除清單，略過 ⌘C fallback", category: "TextExtract")
            }
        }

        if let text = selectedText {
            log.info("成功擷取選取文字 (\(text.count) 字)", category: "TextExtract")
        }

        return AppContext(
            appName: appName,
            bundleIdentifier: bundleID,
            selectedText: selectedText
        )
    }

    // MARK: - Strategy 1: Accessibility API

    /// AX 讀取選取文字的三種結果：只有 `.unsupported` 才考慮 ⌘C fallback
    enum AXSelection: Equatable {
        case text(String)
        case emptySelection
        case unsupported
    }

    struct AXSelectionResult {
        let selection: AXSelection
        /// 焦點元素的 kAXRoleAttribute（拿不到焦點元素時為 nil）
        let role: String?
    }

    /// ⌘C fallback 只對文字輸入類元素執行
    private nonisolated static let fallbackRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        "AXWebArea",
    ]

    nonisolated static func shouldUseClipboardFallback(bundleID: String?, role: String?) -> Bool {
        guard let role, fallbackRoles.contains(role) else { return false }
        return !SensitiveApps.matches(bundleID, patterns: SensitiveApps.clipboardFallbackPatterns)
    }

    private nonisolated static func getSelectedTextViaAX(pid: pid_t) -> AXSelectionResult {
        let log = AppLogger.shared
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.5)

        // Try 1a: focused element → selected text
        var focusedElement: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        var role: String?
        if focusResult == .success,
           let focused = focusedElement,
           CFGetTypeID(focused) == AXUIElementGetTypeID() {
            // 上面的 CFGetTypeID 比對已等同 type guard，
            // 而 CFType conditional downcast 編譯器會警告 always succeeds，因此維持 as!。
            let focusedAX = focused as! AXUIElement
            var roleValue: AnyObject?
            if AXUIElementCopyAttributeValue(focusedAX, kAXRoleAttribute as CFString, &roleValue) == .success {
                role = roleValue as? String
            }
            var selText: AnyObject?
            let textResult = AXUIElementCopyAttributeValue(
                focusedAX,
                kAXSelectedTextAttribute as CFString,
                &selText
            )
            if textResult == .success, let text = selText as? String {
                return AXSelectionResult(selection: text.isEmpty ? .emptySelection : .text(text), role: role)
            }
            log.info("AX focusedElement 有但 selectedText 失敗 (status=\(textResult.rawValue))", category: "TextExtract")
        } else {
            log.info("AX focusedElement 失敗 (status=\(focusResult.rawValue))", category: "TextExtract")
        }

        // Try 1b: directly on app element (some apps expose it here)
        var appSelText: AnyObject?
        let appResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXSelectedTextAttribute as CFString,
            &appSelText
        )
        if appResult == .success, let text = appSelText as? String {
            return AXSelectionResult(selection: text.isEmpty ? .emptySelection : .text(text), role: role)
        }

        return AXSelectionResult(selection: .unsupported, role: role)
    }

    // MARK: - Strategy 2: Clipboard-based Cmd+C

    /// Unified clipboard approach: save clipboard → try AppleScript → try CGEvent → poll → restore
    private static func getSelectedTextViaClipboard() async -> String? {
        let pasteboard = NSPasteboard.general
        let originalChangeCount = pasteboard.changeCount

        // Save current clipboard content（完整保留所有型別，含圖片/RTF）
        let backup = ClipboardBackup.snapshot(pasteboard)

        // Try AppleScript first (more reliable for Electron apps).
        // executeAndReturnError 是同步阻塞，放到 detached task 隔離不阻塞 caller。
        var cmdCSent = await Task.detached(priority: .userInitiated) { () -> Bool in
            let script = NSAppleScript(source: """
                tell application "System Events"
                    keystroke "c" using command down
                end tell
            """)
            var errorInfo: NSDictionary?
            script?.executeAndReturnError(&errorInfo)
            if let err = errorInfo {
                Self.log.info("AppleScript Cmd+C 失敗: \(err)", category: "TextExtract")
                return false
            }
            Self.log.info("AppleScript Cmd+C 已送出", category: "TextExtract")
            return true
        }.value

        // If AppleScript failed, try CGEvent
        // Use nil source to avoid inheriting physical modifier keys (user may still hold hotkey)
        if !cmdCSent {
            let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x08, keyDown: true)
            keyDown?.flags = .maskCommand
            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x08, keyDown: false)

            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
            cmdCSent = true
            log.info("CGEvent Cmd+C 已送出 (nil source)", category: "TextExtract")
        }

        guard cmdCSent else {
            log.info("Cmd+C 無法送出", category: "TextExtract")
            return nil
        }

        // Poll for clipboard change (up to 600ms)
        // Use Task.sleep to yield the main actor instead of blocking the thread
        var clipboardChanged = false
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(50))
            if pasteboard.changeCount != originalChangeCount {
                clipboardChanged = true
                break
            }
        }

        guard clipboardChanged else {
            log.info("Clipboard fallback: 剪貼簿未改變", category: "TextExtract")
            return nil
        }

        let copiedText = pasteboard.string(forType: .string)

        // Restore original clipboard（完整還原所有型別）
        ClipboardBackup.restore(backup, to: pasteboard)

        guard let text = copiedText, !text.isEmpty else {
            return nil
        }

        log.info("Clipboard fallback 成功取得文字 (\(text.count) 字)", category: "TextExtract")
        return text
    }
}

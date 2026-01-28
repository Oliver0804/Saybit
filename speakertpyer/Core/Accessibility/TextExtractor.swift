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

    /// Get the current frontmost app context including selected text (async to avoid blocking main thread)
    static func getCurrentContext() async -> AppContext {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return .empty
        }

        let appName = frontApp.localizedName ?? "Unknown"
        let bundleID = frontApp.bundleIdentifier

        // Strategy 1: AX API — focused element → selected text (fast, no side effects)
        var selectedText = getSelectedTextViaAX(for: frontApp)

        // Strategy 2: Clipboard-based Cmd+C (AppleScript → CGEvent fallback)
        if selectedText == nil {
            log.info("AX API 未取得選取文字，嘗試 clipboard fallback", category: "TextExtract")
            selectedText = await getSelectedTextViaClipboard()
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

    private static func getSelectedTextViaAX(for app: NSRunningApplication) -> String? {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        // Try 1a: focused element → selected text
        var focusedElement: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        if focusResult == .success,
           let focused = focusedElement,
           CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let focusedAX = focused as! AXUIElement
            var selText: AnyObject?
            let textResult = AXUIElementCopyAttributeValue(
                focusedAX,
                kAXSelectedTextAttribute as CFString,
                &selText
            )
            if textResult == .success, let text = selText as? String, !text.isEmpty {
                return text
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
        if appResult == .success, let text = appSelText as? String, !text.isEmpty {
            return text
        }

        return nil
    }

    // MARK: - Strategy 2: Clipboard-based Cmd+C

    /// Unified clipboard approach: save clipboard → try AppleScript → try CGEvent → poll → restore
    private static func getSelectedTextViaClipboard() async -> String? {
        let pasteboard = NSPasteboard.general
        let originalChangeCount = pasteboard.changeCount

        // Save current clipboard content
        let savedItems = pasteboard.pasteboardItems?.compactMap { item -> (String, NSPasteboard.PasteboardType)? in
            for type in item.types {
                if let data = item.string(forType: type) {
                    return (data, type)
                }
            }
            return nil
        } ?? []

        // Try AppleScript first (more reliable for Electron apps)
        var cmdCSent = false
        let script = NSAppleScript(source: """
            tell application "System Events"
                keystroke "c" using command down
            end tell
        """)
        var errorInfo: NSDictionary?
        script?.executeAndReturnError(&errorInfo)
        if let err = errorInfo {
            log.info("AppleScript Cmd+C 失敗: \(err)", category: "TextExtract")
        } else {
            cmdCSent = true
            log.info("AppleScript Cmd+C 已送出", category: "TextExtract")
        }

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

        // Restore original clipboard
        pasteboard.clearContents()
        for (content, type) in savedItems {
            pasteboard.setString(content, forType: type)
        }

        guard let text = copiedText, !text.isEmpty else {
            return nil
        }

        log.info("Clipboard fallback 成功取得文字 (\(text.count) 字)", category: "TextExtract")
        return text
    }
}

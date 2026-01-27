//
//  TextExtractor.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import AppKit
import ApplicationServices

enum TextExtractor {
    /// Get the current frontmost app context including selected text
    static func getCurrentContext() -> AppContext {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return .empty
        }

        let appName = frontApp.localizedName ?? "Unknown"
        let bundleID = frontApp.bundleIdentifier

        // Try to get selected text via Accessibility API
        var selectedText = getSelectedText(for: frontApp)

        // Fallback: use clipboard-based extraction for Electron/web apps
        if selectedText == nil {
            selectedText = getSelectedTextViaClipboard()
        }

        return AppContext(
            appName: appName,
            bundleIdentifier: bundleID,
            selectedText: selectedText
        )
    }

    private static func getSelectedText(for app: NSRunningApplication) -> String? {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        // Get focused element
        var focusedElement: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard focusResult == .success,
              let focused = focusedElement,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return nil
        }

        // Get selected text (safe: CFGetTypeID already validated above)
        let focusedAXElement = focused as! AXUIElement
        var selectedText: AnyObject?
        let textResult = AXUIElementCopyAttributeValue(
            focusedAXElement,
            kAXSelectedTextAttribute as CFString,
            &selectedText
        )

        guard textResult == .success, let text = selectedText as? String, !text.isEmpty else {
            return nil
        }

        return text
    }

    /// Fallback: simulate Cmd+C to capture selected text, then restore clipboard
    private static func getSelectedTextViaClipboard() -> String? {
        let pasteboard = NSPasteboard.general
        let originalChangeCount = pasteboard.changeCount

        // Save current clipboard contents
        let savedItems = pasteboard.pasteboardItems?.compactMap { item -> (String, NSPasteboard.PasteboardType)? in
            for type in item.types {
                if let data = item.string(forType: type) {
                    return (data, type)
                }
            }
            return nil
        } ?? []

        // Simulate Cmd+C
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true) // 'c' key
        keyDown?.flags = CGEventFlags.maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        keyUp?.flags = CGEventFlags.maskCommand

        keyDown?.post(tap: CGEventTapLocation.cghidEventTap)
        keyUp?.post(tap: CGEventTapLocation.cghidEventTap)

        // Wait for clipboard to update
        Thread.sleep(forTimeInterval: 0.1)

        // Check if clipboard changed
        guard pasteboard.changeCount != originalChangeCount else {
            return nil // No selection was copied
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

        return text
    }
}

//
//  TextInjector.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import AppKit
import CoreGraphics

enum TextInjector {
    /// Inject text into the currently focused app by simulating Cmd+V
    static func inject(_ text: String) {
        // Save current pasteboard content
        let pasteboard = NSPasteboard.general
        let previousContent = pasteboard.string(forType: .string)

        // Set new content
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Small delay to ensure pasteboard is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            simulatePaste()

            // Restore previous pasteboard content after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if let previous = previousContent {
                    pasteboard.clearContents()
                    pasteboard.setString(previous, forType: .string)
                }
            }
        }
    }

    /// 模擬按下 Enter/Return 鍵
    static func simulateEnter() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key code 0x24 = Return key
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false) else {
            return
        }

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

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

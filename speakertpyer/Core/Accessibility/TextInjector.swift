//
//  TextInjector.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import AppKit
import CoreGraphics

enum TextInjector {
    /// 統一入口：根據模式注入文字
    static func inject(_ text: String, mode: InjectionMode = .paste) {
        switch mode {
        case .paste:
            injectViaPaste(text)
        case .keypress:
            simulateKeypress(text)
        case .replaceSelection:
            replaceSelection(text)
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
        pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            simulatePaste()

            // 延長到 0.5s，給慢速 app（Electron / 大型文件）足夠時間完成貼上才還原
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                // 僅在剪貼簿仍是我們寫入的內容時還原，避免覆寫使用者期間的新複製
                guard pasteboard.changeCount == ourChangeCount else { return }
                ClipboardBackup.restore(backup, to: pasteboard)
            }
        }
    }

    // MARK: - Keypress Mode (逐字輸入)

    /// 模擬逐字鍵盤輸入，適合不支援貼上的應用程式
    private static func simulateKeypress(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        var delay: TimeInterval = 0

        for char in text {
            let charDelay = delay
            DispatchQueue.main.asyncAfter(deadline: .now() + charDelay) {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else { return }
                let chars = Array(String(char).utf16)
                event.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
                event.flags = []
                event.post(tap: .cghidEventTap)

                // keyUp
                if let upEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                    upEvent.flags = []
                    upEvent.post(tap: .cghidEventTap)
                }
            }
            delay += 0.02 // 20ms between keystrokes
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

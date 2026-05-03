//
//  HotKeyConflictChecker.swift
//  speakertpyer
//
//  比對使用者選的快捷鍵是否撞到已知 macOS 系統熱鍵或常見 app 熱鍵。
//  注意：這是 best-effort 的「軟性」警告，不能完全取代讀取
//  com.apple.symbolichotkeys 的 plist；那邊涉及私有 key 結構不穩定。
//

import CoreGraphics
import Foundation

enum HotKeyConflictChecker {
    struct KnownShortcut {
        let modifiers: CGEventFlags
        let keyCode: UInt16
        let name: String   // 顯示用敘述
    }

    /// 內建的「常見且高優先」系統熱鍵清單。命中代表很可能被系統攔截。
    /// 模板採 macOS 預設值（使用者改過就不準）。
    static let knownSystem: [KnownShortcut] = [
        // Spotlight ⌘Space
        .init(modifiers: .maskCommand, keyCode: 49, name: "Spotlight (⌘ Space)"),
        // 切換輸入來源 ⌃Space
        .init(modifiers: .maskControl, keyCode: 49, name: "Input Source (⌃ Space)"),
        // 螢幕截圖 ⌘⇧3 / ⌘⇧4 / ⌘⇧5
        .init(modifiers: [.maskCommand, .maskShift], keyCode: 20, name: "Screenshot (⌘⇧ 3)"),
        .init(modifiers: [.maskCommand, .maskShift], keyCode: 21, name: "Screenshot Area (⌘⇧ 4)"),
        .init(modifiers: [.maskCommand, .maskShift], keyCode: 23, name: "Screenshot Tool (⌘⇧ 5)"),
        // Mission Control ⌃↑ / Application Windows ⌃↓
        .init(modifiers: .maskControl, keyCode: 126, name: "Mission Control (⌃ ↑)"),
        .init(modifiers: .maskControl, keyCode: 125, name: "App Windows (⌃ ↓)"),
        // 切換桌面 ⌃← / ⌃→
        .init(modifiers: .maskControl, keyCode: 123, name: "Switch Space (⌃ ←)"),
        .init(modifiers: .maskControl, keyCode: 124, name: "Switch Space (⌃ →)"),
        // 切換應用程式 ⌘Tab
        .init(modifiers: .maskCommand, keyCode: 48, name: "App Switcher (⌘ Tab)"),
        // 隱藏 ⌘H / 結束 ⌘Q
        .init(modifiers: .maskCommand, keyCode: 4,  name: "Hide App (⌘ H)"),
        .init(modifiers: .maskCommand, keyCode: 12, name: "Quit App (⌘ Q)"),
        // 複製/貼上/剪下/全選/Undo
        .init(modifiers: .maskCommand, keyCode: 8,  name: "Copy (⌘ C)"),
        .init(modifiers: .maskCommand, keyCode: 9,  name: "Paste (⌘ V)"),
        .init(modifiers: .maskCommand, keyCode: 7,  name: "Cut (⌘ X)"),
        .init(modifiers: .maskCommand, keyCode: 0,  name: "Select All (⌘ A)"),
        .init(modifiers: .maskCommand, keyCode: 6,  name: "Undo (⌘ Z)"),
        // 儲存/新建/開啟/關閉
        .init(modifiers: .maskCommand, keyCode: 1,  name: "Save (⌘ S)"),
        .init(modifiers: .maskCommand, keyCode: 45, name: "New (⌘ N)"),
        .init(modifiers: .maskCommand, keyCode: 31, name: "Open (⌘ O)"),
        .init(modifiers: .maskCommand, keyCode: 13, name: "Close Window (⌘ W)"),
        // 鎖定螢幕 ⌃⌘Q（macOS 10.13+）
        .init(modifiers: [.maskControl, .maskCommand], keyCode: 12, name: "Lock Screen (⌃⌘ Q)"),
    ]

    /// 比較兩組修飾鍵：只比 ⌘⌃⌥⇧ 四個 bit，其他狀態 bit 忽略。
    private static let modifierMask: CGEventFlags = [
        .maskCommand, .maskControl, .maskAlternate, .maskShift,
    ]

    /// 回傳第一筆撞到的系統熱鍵；nil 表示沒撞到內建清單裡的項目。
    static func conflict(keyCode: UInt16, modifiers: CGEventFlags) -> KnownShortcut? {
        let userMods = modifiers.intersection(modifierMask)
        return knownSystem.first { ks in
            ks.keyCode == keyCode && ks.modifiers.intersection(modifierMask) == userMods
        }
    }
}

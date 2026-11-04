//
//  SensitiveApps.swift
//  speakertpyer
//
//  不該被 Saybit 讀取內容（螢幕 OCR、⌘C 擷取選取文字）的 App：
//  密碼管理員、鑰匙圈、終端機、遠端桌面 / 虛擬機。
//  規則以 bundle ID 比對；結尾 `.*` 表示前綴比對。
//

#if os(macOS)
import ApplicationServices
import Foundation

nonisolated enum SensitiveApps {
    /// 螢幕內容擷取黑名單（H9）
    static let screenCapturePatterns: [String] = [
        "com.1password.*",
        "com.agilebits.*",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.microsoft.rdc.macos",
        "com.parallels.*",
        "com.vmware.*",
        "com.teamviewer.*",
    ]

    /// ⌘C fallback 黑名單（M18）：除上述外，Finder 的 ⌘C 會複製檔案而非文字
    static let clipboardFallbackPatterns: [String] = screenCapturePatterns + [
        "com.apple.finder",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.dashlane.*",
        "com.apple.ScreenSharing",
        "com.anydesk.*",
        "com.realvnc.*",
    ]

    static func matches(_ bundleID: String?, patterns: [String]) -> Bool {
        guard let id = bundleID?.lowercased(), !id.isEmpty else { return false }
        return patterns.contains { raw in
            let pattern = raw.lowercased()
            if pattern.hasSuffix(".*") {
                let prefix = String(pattern.dropLast(2))
                return id == prefix || id.hasPrefix(prefix + ".")
            }
            return id == pattern
        }
    }

    /// 前景 App 的焦點元素是否為密碼欄位（AXSecureTextField）
    static func focusedElementIsSecure(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement
        var subrole: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success else {
            return false
        }
        return (subrole as? String) == (kAXSecureTextFieldSubrole as String)
    }
}
#endif

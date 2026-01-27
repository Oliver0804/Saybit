//
//  AccessibilityManager.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import AppKit
import ApplicationServices

class AccessibilityManager {
    static let shared = AccessibilityManager()

    var isAuthorized: Bool {
        AXIsProcessTrusted()
    }

    func promptIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}

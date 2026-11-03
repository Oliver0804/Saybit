//
//  GlobalHotKeyManager.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import ApplicationServices
import CoreGraphics
import Foundation

class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var onDoubleTap: (() -> Void)?

    private var registeredKeyCode: UInt16 = 49 // Space
    private var registeredModifiers: CGEventFlags = .maskAlternate // Option
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private(set) var isRegistered = false

    // MARK: - Extra Bindings（語音模式快捷鍵，按一下切換錄音）

    struct Binding {
        let keyCode: UInt16
        let modifiers: CGEventFlags
        let action: () -> Void
    }

    /// 由主快捷鍵共用同一個 event tap；修飾鍵需完全相符（避免 ⌃. 吃掉 ⌃⇧.）
    var extraBindings: [Binding] = []
    private var extraKeyDownCode: UInt16?

    // MARK: - Double Tap Detection
    private var lastKeyDownTime: TimeInterval = 0
    private let doubleTapInterval: TimeInterval = 0.3
    private var pendingSingleTapWork: DispatchWorkItem?

    // MARK: - Hotkey Recording

    private(set) var isRecordingNewHotkey = false
    private var recordingCallback: ((UInt16, CGEventFlags) -> Void)?
    /// Called with currently held modifiers during recording, for live UI feedback
    var onRecordingModifiersChanged: ((CGEventFlags) -> Void)?
    /// 錄製被取消（Esc / 逾時 / cancelRecording()）時在主執行緒呼叫一次，之後自動清掉；
    /// 每次 startRecording 前後設定即可。錄製成功時不呼叫。
    var onRecordingCancelled: (() -> Void)?
    private var recordingTimeoutWork: DispatchWorkItem?

    /// 開始錄製新快捷鍵。錄製期間鍵盤事件會被吃掉，所以一定有逾時（預設 10 秒）自動取消。
    func startRecording(timeout: TimeInterval = 10, completion: @escaping (UInt16, CGEventFlags) -> Void) {
        recordingTimeoutWork?.cancel()
        recordingCallback = completion
        isRecordingNewHotkey = true
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRecordingNewHotkey else { return }
            AppLogger.shared.info("快捷鍵錄製逾時（\(Int(timeout)) 秒），自動取消", category: "HotKey")
            self.cancelRecording()
        }
        recordingTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(timeout, 1), execute: work)
    }

    func cancelRecording() {
        let wasRecording = isRecordingNewHotkey
        endRecording()
        onRecordingModifiersChanged = nil
        if wasRecording { notifyRecordingCancelled() }
    }

    /// 結束錄製狀態（不通知）：成功、取消共用
    private func endRecording() {
        isRecordingNewHotkey = false
        recordingCallback = nil
        recordingTimeoutWork?.cancel()
        recordingTimeoutWork = nil
    }

    private func notifyRecordingCancelled() {
        let callback = onRecordingCancelled
        onRecordingCancelled = nil
        DispatchQueue.main.async { callback?() }
    }

    // MARK: - Permission Retry / Health

    /// event tap 建立失敗（通常是尚未授權輔助使用）時呼叫；授權後自動註冊成功會呼叫 onRegistrationRecovered
    var onRegistrationFailed: (() -> Void)?
    var onRegistrationRecovered: (() -> Void)?
    /// 已註冊後偵測到輔助使用權限被撤銷
    var onPermissionLost: (() -> Void)?
    private var permissionRetryTimer: Timer?
    private var healthTimer: Timer?
    private var permissionLostReported = false

    /// 失敗後每 2 秒檢查 AXIsProcessTrusted()，授權後自動重新註冊
    private func scheduleRegistrationRetry() {
        guard permissionRetryTimer == nil else { return }
        permissionRetryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                self.permissionRetryTimer?.invalidate()
                self.permissionRetryTimer = nil
                AppLogger.shared.info("輔助使用已授權，重新註冊快捷鍵", category: "HotKey")
                self.register(keyCode: self.registeredKeyCode, modifiers: self.registeredModifiers)
                if self.isRegistered { self.onRegistrationRecovered?() }
            }
        }
    }

    /// 註冊後每 5 秒確認權限仍在、tap 仍啟用
    private func startHealthCheck() {
        healthTimer?.invalidate()
        permissionLostReported = false
        healthTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let tap = self.eventTap else { return }
                if !AXIsProcessTrusted() {
                    if !self.permissionLostReported {
                        self.permissionLostReported = true
                        AppLogger.shared.error("輔助使用權限已被撤銷，快捷鍵失效", category: "HotKey")
                        self.onPermissionLost?()
                    }
                    return
                }
                if self.permissionLostReported {
                    // 權限恢復：重建 tap（被撤銷過的 tap 不一定能直接重新啟用）
                    self.permissionLostReported = false
                    self.register(keyCode: self.registeredKeyCode, modifiers: self.registeredModifiers)
                    if self.isRegistered { self.onRegistrationRecovered?() }
                    return
                }
                if !CGEvent.tapIsEnabled(tap: tap) {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
        }
    }

    // MARK: - Registration

    func register(keyCode: UInt16, modifiers: CGEventFlags) {
        // Remove existing tap
        unregister()

        registeredKeyCode = keyCode
        registeredModifiers = modifiers

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            isRegistered = false
            AppLogger.shared.error("Failed to create event tap. Accessibility permission required.", category: "HotKey")
            onRegistrationFailed?()
            scheduleRegistrationRetry()
            return
        }

        permissionRetryTimer?.invalidate()
        permissionRetryTimer = nil
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRegistered = true
        startHealthCheck()
        AppLogger.shared.info("Global hotkey registered: \(Self.hotkeyDescription(keyCode: keyCode, modifiers: modifiers))", category: "HotKey")
    }

    func unregister() {
        healthTimer?.invalidate()
        healthTimer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        isRegistered = false
    }

    private var isHotkeyDown = false

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if it gets disabled
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Recording mode - capture next key combo
        if isRecordingNewHotkey {
            if type == .keyDown {
                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

                // Escape cancels recording
                if keyCode == 53 {
                    cancelRecording()
                    return nil
                }

                let modifiers = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])

                // Require at least one modifier
                guard !modifiers.isEmpty else { return nil }

                let callback = recordingCallback
                endRecording()
                onRecordingCancelled = nil
                DispatchQueue.main.async {
                    callback?(keyCode, modifiers)
                }
                return nil
            }
            // Update live modifier display during recording
            if type == .flagsChanged {
                let currentMods = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
                let callback = onRecordingModifiersChanged
                DispatchQueue.main.async {
                    callback?(currentMods)
                }
                return nil
            }
            if type == .keyUp { return nil }
            return Unmanaged.passUnretained(event)
        }

        // Normal hotkey handling
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // 語音模式快捷鍵（精確比對修飾鍵）
        if !extraBindings.isEmpty {
            let mods = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
            if type == .keyDown, extraKeyDownCode == nil,
               let binding = extraBindings.first(where: { $0.keyCode == keyCode && $0.modifiers == mods }) {
                extraKeyDownCode = keyCode
                DispatchQueue.main.async { binding.action() }
                return nil
            }
            if type == .keyDown, extraKeyDownCode == keyCode { return nil } // 長按重複
            if type == .keyUp, extraKeyDownCode == keyCode {
                extraKeyDownCode = nil
                return nil
            }
        }

        // Check if our hotkey modifier is active
        let modifierMatch = flags.contains(registeredModifiers)

        // 長按主快捷鍵時的 auto-repeat keyDown 也要吃掉，否則會漏給前景 App（hold 模式必現）
        if type == .keyDown && keyCode == registeredKeyCode && isHotkeyDown {
            return nil
        }

        if type == .keyDown && keyCode == registeredKeyCode && modifierMatch && !isHotkeyDown {
            isHotkeyDown = true

            if onDoubleTap != nil {
                // Double-tap mode: detect rapid successive presses
                let now = ProcessInfo.processInfo.systemUptime
                let elapsed = now - lastKeyDownTime
                lastKeyDownTime = now

                if elapsed <= doubleTapInterval {
                    // Second tap within window → fire double tap
                    pendingSingleTapWork?.cancel()
                    pendingSingleTapWork = nil
                    DispatchQueue.main.async { [weak self] in
                        self?.onDoubleTap?()
                    }
                }
                // No single-tap fallback needed; we just wait for the double
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.onKeyDown?()
                }
            }
            return nil // Consume the event
        }

        if type == .keyUp && keyCode == registeredKeyCode && isHotkeyDown {
            isHotkeyDown = false
            if onDoubleTap == nil {
                DispatchQueue.main.async { [weak self] in
                    self?.onKeyUp?()
                }
            }
            return nil // Consume the event
        }

        // Also handle the case where modifier is released while key is held
        if type == .flagsChanged && isHotkeyDown && !modifierMatch {
            isHotkeyDown = false
            DispatchQueue.main.async { [weak self] in
                self?.onKeyUp?()
            }
        }

        return Unmanaged.passUnretained(event)
    }

    deinit {
        unregister()
    }

    // MARK: - Key Name Utilities

    static func hotkeyDescription(keyCode: UInt16?, modifiers: CGEventFlags) -> String {
        var parts: [String] = []
        if modifiers.contains(.maskControl) { parts.append("⌃") }
        if modifiers.contains(.maskAlternate) { parts.append("⌥") }
        if modifiers.contains(.maskShift) { parts.append("⇧") }
        if modifiers.contains(.maskCommand) { parts.append("⌘") }
        if let keyCode {
            parts.append(keyName(for: keyCode))
        }
        return parts.joined(separator: " ")
    }

    static func keyName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "O"
        case 32: return "U"
        case 33: return "["
        case 34: return "I"
        case 35: return "P"
        case 36: return "Return"
        case 37: return "L"
        case 38: return "J"
        case 39: return "'"
        case 40: return "K"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        case 48: return "Tab"
        case 49: return "Space"
        case 50: return "`"
        case 51: return "Delete"
        case 53: return "Esc"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 105: return "F13"
        case 107: return "F14"
        case 109: return "F10"
        case 111: return "F12"
        case 113: return "F15"
        case 118: return "F4"
        case 120: return "F2"
        case 122: return "F1"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return "Key(\(keyCode))"
        }
    }
}

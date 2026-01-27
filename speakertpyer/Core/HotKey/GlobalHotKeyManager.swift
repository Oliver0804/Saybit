//
//  GlobalHotKeyManager.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import CoreGraphics
import Foundation

class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private var registeredKeyCode: UInt16 = 49 // Space
    private var registeredModifiers: CGEventFlags = .maskAlternate // Option
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private(set) var isRegistered = false

    // MARK: - Hotkey Recording

    private(set) var isRecordingNewHotkey = false
    private var recordingCallback: ((UInt16, CGEventFlags) -> Void)?
    /// Called with currently held modifiers during recording, for live UI feedback
    var onRecordingModifiersChanged: ((CGEventFlags) -> Void)?

    func startRecording(completion: @escaping (UInt16, CGEventFlags) -> Void) {
        recordingCallback = completion
        isRecordingNewHotkey = true
    }

    func cancelRecording() {
        isRecordingNewHotkey = false
        recordingCallback = nil
        onRecordingModifiersChanged = nil
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
            print("[SpeakerTyper] Failed to create event tap. Accessibility permission required.")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRegistered = true
        print("[SpeakerTyper] Global hotkey registered: \(Self.hotkeyDescription(keyCode: keyCode, modifiers: modifiers))")
    }

    func unregister() {
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
                    isRecordingNewHotkey = false
                    recordingCallback = nil
                    return nil
                }

                let modifiers = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])

                // Require at least one modifier
                guard !modifiers.isEmpty else { return nil }

                isRecordingNewHotkey = false
                let callback = recordingCallback
                recordingCallback = nil
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

        // Check if our hotkey modifier is active
        let modifierMatch = flags.contains(registeredModifiers)

        if type == .keyDown && keyCode == registeredKeyCode && modifierMatch && !isHotkeyDown {
            isHotkeyDown = true
            DispatchQueue.main.async { [weak self] in
                self?.onKeyDown?()
            }
            return nil // Consume the event
        }

        if type == .keyUp && keyCode == registeredKeyCode && isHotkeyDown {
            isHotkeyDown = false
            DispatchQueue.main.async { [weak self] in
                self?.onKeyUp?()
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

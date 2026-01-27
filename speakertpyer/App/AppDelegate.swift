//
//  AppDelegate.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import AppKit
import Speech
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    let settingsStore = SettingsStore()
    private var hotKeyManager: GlobalHotKeyManager?
    private(set) var voicePipeline: VoicePipeline?
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupPipeline()

        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            showOnboarding()
        } else {
            requestPermissions()
            setupHotKey()
        }
    }

    // MARK: - Onboarding

    private func showOnboarding() {
        // LSUIElement apps need to temporarily become regular apps to show windows
        NSApp.setActivationPolicy(.regular)

        let onboardingView = OnboardingView { [weak self] in
            DispatchQueue.main.async {
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
                // Revert to accessory (menu bar only, no Dock icon)
                NSApp.setActivationPolicy(.accessory)
                // Now register hotkey (accessibility permission should be granted)
                self?.setupHotKey()
            }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "SpeakerTyper 設定引導"
        window.contentView = NSHostingView(rootView: onboardingView)
        window.center()
        window.makeKeyAndOrderFront(nil)

        // Activate after a brief delay to ensure the policy change takes effect
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }

        self.onboardingWindow = window
    }

    // MARK: - Permissions

    private func requestPermissions() {
        // Microphone
        AVAudioApplication.requestRecordPermission { granted in
            if !granted {
                print("[SpeakerTyper] Microphone permission denied")
            }
        }

        // Speech Recognition
        SFSpeechRecognizer.requestAuthorization { status in
            if status != .authorized {
                print("[SpeakerTyper] Speech recognition permission denied: \(status.rawValue)")
            }
        }

        // Accessibility
        AccessibilityManager.shared.promptIfNeeded()
    }

    // MARK: - HotKey

    func setupHotKey() {
        hotKeyManager = GlobalHotKeyManager.shared
        configureHotkeyCallbacks()
        hotKeyManager?.register(
            keyCode: UInt16(settingsStore.hotkeyKeyCode),
            modifiers: CGEventFlags(rawValue: UInt64(settingsStore.hotkeyModifiers))
        )
    }

    private func configureHotkeyCallbacks() {
        switch settingsStore.hotkeyTriggerMode {
        case .toggle:
            hotKeyManager?.onKeyDown = { [weak self] in
                self?.voicePipeline?.toggleRecording()
            }
            hotKeyManager?.onKeyUp = nil
        case .hold:
            hotKeyManager?.onKeyDown = { [weak self] in
                self?.voicePipeline?.startRecording()
            }
            hotKeyManager?.onKeyUp = { [weak self] in
                self?.voicePipeline?.stopRecordingAndProcess()
            }
        }
    }

    // MARK: - Pipeline

    private func setupPipeline() {
        voicePipeline = VoicePipeline(settingsStore: settingsStore)
    }
}

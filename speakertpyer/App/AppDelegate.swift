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
    private var tutorialWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsStore.shared = settingsStore
        setupPipeline()

        // Listen for tutorial show requests from Settings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowTutorial),
            name: .showTutorial,
            object: nil
        )

        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            showOnboarding()
        } else {
            requestPermissions()
            setupHotKey()
        }

        clearStaleUpdateNotification()
        runAutoUpdateCheckIfDue()
    }

    /// 啟動時若使用者已升級到 ≥ 通知中的版本，清掉殘留的 availableUpdateTag。
    private func clearStaleUpdateNotification() {
        let stored = settingsStore.availableUpdateTag
        guard !stored.isEmpty else { return }
        let current = UpdateChecker.shared.currentVersion()
        let normalized = UpdateChecker.normalize(stored)
        if UpdateChecker.compareSemver(current, normalized) != .orderedAscending {
            settingsStore.availableUpdateTag = ""
            settingsStore.availableUpdateURL = ""
            AppLogger.shared.info("Cleared stale update notification (current v\(current) ≥ \(normalized))", category: "Update")
        }
    }

    /// 啟動時檢查更新（24h 節流）。
    private func runAutoUpdateCheckIfDue() {
        guard settingsStore.enableAutoUpdateCheck else { return }
        let elapsed = Date().timeIntervalSince(settingsStore.lastUpdateCheckAt)
        guard elapsed >= 24 * 3600 else { return }

        Task { [weak self] in
            do {
                let result = try await UpdateChecker.shared.check()
                await MainActor.run {
                    guard let self else { return }
                    self.settingsStore.lastUpdateCheckAt = Date()
                    if case .newer(_, let release) = result {
                        self.settingsStore.availableUpdateTag = release.tagName
                        self.settingsStore.availableUpdateURL = release.htmlUrl
                        AppLogger.shared.info("Auto update found: \(release.tagName)", category: "Update")
                    } else {
                        self.settingsStore.availableUpdateTag = ""
                        self.settingsStore.availableUpdateURL = ""
                    }
                }
            } catch {
                AppLogger.shared.debug("Auto update check failed: \(error.localizedDescription)", category: "Update")
            }
        }
    }

    // MARK: - Onboarding

    private func showOnboarding() {
        NSApp.setActivationPolicy(.regular)

        let onboardingView = OnboardingView(
            settingsStore: settingsStore,
            onComplete: { [weak self] in
                DispatchQueue.main.async {
                    self?.onboardingWindow?.close()
                    self?.onboardingWindow = nil
                    NSApp.setActivationPolicy(.accessory)
                    self?.setupHotKey()
                }
            },
            onStartTutorial: { [weak self] in
                DispatchQueue.main.async {
                    self?.onboardingWindow?.close()
                    self?.onboardingWindow = nil
                    self?.setupHotKey()
                    self?.showTutorial()
                }
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = L10n.Onboarding.title
        window.contentView = NSHostingView(rootView: onboardingView)
        window.center()
        window.makeKeyAndOrderFront(nil)

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }

        self.onboardingWindow = window
    }

    // MARK: - Tutorial

    func showTutorial() {
        if let existing = tutorialWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        NSApp.setActivationPolicy(.regular)

        let tutorialView = TutorialView(settingsStore: settingsStore) { [weak self] in
            self?.tutorialWindow?.close()
            self?.tutorialWindow = nil
            NSApp.setActivationPolicy(.accessory)
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = L10n.Tutorial.title
        window.contentView = NSHostingView(rootView: tutorialView)
        window.center()
        window.makeKeyAndOrderFront(nil)

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }

        self.tutorialWindow = window
    }

    @objc private func handleShowTutorial() {
        showTutorial()
    }

    // MARK: - Permissions

    private func requestPermissions() {
        AVAudioApplication.requestRecordPermission { granted in
            if !granted {
                AppLogger.shared.error("Microphone permission denied", category: "Permission")
            }
        }

        SFSpeechRecognizer.requestAuthorization { status in
            if status != .authorized {
                AppLogger.shared.error("Speech recognition permission denied: \(status.rawValue)", category: "Permission")
            }
        }

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
        hotKeyManager?.onKeyDown = nil
        hotKeyManager?.onKeyUp = nil
        hotKeyManager?.onDoubleTap = nil

        switch settingsStore.hotkeyTriggerMode {
        case .toggle:
            hotKeyManager?.onKeyDown = { [weak self] in
                self?.voicePipeline?.toggleRecording()
            }
        case .hold:
            hotKeyManager?.onKeyDown = { [weak self] in
                self?.voicePipeline?.startRecording()
            }
            hotKeyManager?.onKeyUp = { [weak self] in
                self?.voicePipeline?.stopRecordingAndProcess()
            }
        case .doubleTap:
            hotKeyManager?.onDoubleTap = { [weak self] in
                self?.voicePipeline?.toggleRecording()
            }
        }
    }

    // MARK: - Pipeline

    private func setupPipeline() {
        voicePipeline = VoicePipeline(settingsStore: settingsStore)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let showTutorial = Notification.Name("com.bashcat.speakertpyer.showTutorial")
}

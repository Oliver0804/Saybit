//
//  AppDelegate.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import AppKit
import Combine
import Speech
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    let settingsStore = SettingsStore()
    private var hotKeyManager: GlobalHotKeyManager?
    private(set) var voicePipeline: VoicePipeline?
    private var onboardingWindow: NSWindow?
    private var tutorialWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    /// 最近一個在前景的「其他 App」：URL scheme 會讓 Saybit 被啟用、搶走焦點，處理前要把焦點還回去
    private var lastExternalApp: NSRunningApplication?

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

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .sink { [weak self] app in self?.lastExternalApp = app }
            .store(in: &cancellables)
        lastExternalApp = NSWorkspace.shared.frontmostApplication

        // 語音模式增刪 / 改快捷鍵 → 重新綁定
        settingsStore.$voiceModes
            .dropFirst()
            .sink { [weak self] modes in self?.registerModeHotkeys(modes) }
            .store(in: &cancellables)
    }

    // MARK: - URL Scheme（Raycast / 捷徑 / Stream Deck）

    /// saybit://toggle、saybit://start、saybit://stop、saybit://cancel，可加 ?mode=<模式名稱>
    /// saybit://settings?tab=general|api|hotkey|dictionary|transcribe|history|statistics|logs
    func application(_ application: NSApplication, open urls: [URL]) {
        // 開 URL 會把 Saybit 帶到前景；先把焦點還給原本的 App，文字才會輸入到正確位置
        // saybit://settings 本來就要把 Saybit 帶到前景，不用還焦點
        if urls.allSatisfy({ ($0.host ?? "").lowercased() == "settings" }) {
            urls.forEach(handleURL)
            return
        }
        let needsRefocus = NSApp.isActive || NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        if needsRefocus, let app = lastExternalApp, !app.isTerminated {
            app.activate()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                for url in urls { self.handleURL(url) }
            }
        } else {
            for url in urls { handleURL(url) }
        }
    }

    private func handleURL(_ url: URL) {
        guard url.scheme?.lowercased() == "saybit", let pipeline = voicePipeline else { return }
        let command = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        let modeName = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "mode" })?.value
        let mode = modeName.flatMap { settingsStore.voiceMode(named: $0) }
        if let modeName, mode == nil {
            AppLogger.shared.error("URL scheme 找不到語音模式: \(modeName)", category: "URL")
        }
        AppLogger.shared.info("URL scheme: \(command)\(modeName.map { " mode=\($0)" } ?? "")", category: "URL")

        let isRecording: Bool = { if case .recording = pipeline.session.state { return true } else { return false } }()
        switch command {
        case "toggle", "dictate":
            pipeline.toggleRecording(mode: mode)
        case "start":
            if !isRecording { pipeline.toggleRecording(mode: mode) }
        case "stop":
            if isRecording { pipeline.stopRecordingAndProcess() }
        case "cancel":
            pipeline.cancelRecording()
        case "settings":
            let tab = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "tab" })?.value
                .flatMap(SettingsTab.init(rawValue:))
            OverlayWindowController.shared.openSettings(tab: tab)
        default:
            AppLogger.shared.error("未知的 URL 指令: \(url.absoluteString)", category: "URL")
        }
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
        registerModeHotkeys(settingsStore.voiceModes)
    }

    /// 每個有設定快捷鍵的語音模式：按一下開始 / 再按一下停止
    private func registerModeHotkeys(_ modes: [VoiceMode]) {
        let bindings = modes.compactMap { mode -> GlobalHotKeyManager.Binding? in
            guard mode.hasHotkey, let keyCode = mode.keyCode else { return nil }
            let modeID = mode.id
            return GlobalHotKeyManager.Binding(
                keyCode: UInt16(keyCode),
                modifiers: CGEventFlags(rawValue: mode.modifiers)
            ) { [weak self] in
                guard let self else { return }
                let current = self.settingsStore.voiceModes.first { $0.id == modeID }
                self.voicePipeline?.toggleRecording(mode: current)
            }
        }
        GlobalHotKeyManager.shared.extraBindings = bindings
        if !bindings.isEmpty {
            AppLogger.shared.info("語音模式快捷鍵: \(bindings.count) 組", category: "HotKey")
        }
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

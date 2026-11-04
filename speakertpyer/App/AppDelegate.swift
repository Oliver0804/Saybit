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

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let settingsStore = SettingsStore()
    private var hotKeyManager: GlobalHotKeyManager?
    private(set) var voicePipeline: VoicePipeline?
    private var onboardingWindow: NSWindow?
    private var tutorialWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    /// 最近一個在前景的「其他 App」：URL scheme 會讓 Saybit 被啟用、搶走焦點，處理前要把焦點還回去
    private var lastExternalApp: NSRunningApplication?
    /// URL 指令去重：同一指令 1 秒內重複直接丟棄
    private var lastURLCommandAt: [String: Date] = [:]
    /// 正在詢問 URL 來源授權時，其他 URL 指令一律丟棄（避免對話框堆疊）
    private var isPromptingURLSender = false

    /// 啟動器類 App 不當作「要把焦點還回去」的目標（它們觸發 URL 後自己會隱藏）
    private static let launcherBundleIDs: Set<String> = [
        "com.raycast.macos",
        "com.runningwithcrayons.alfred",
        "com.apple.spotlight",
        "com.elgato.streamdeck",
    ]

    /// 引導視窗還開著時不允許開始錄音（URL scheme / 捷徑 / 選單列 / 膠囊）
    var isRecordingAllowed: Bool { onboardingWindow == nil }

    /// 外部（URL scheme 以外的捷徑 / AppIntents）能否控制錄音
    func allowsExternalRecordingControl(source: String) -> Bool {
        guard settingsStore.enableURLSchemeControl else {
            AppLogger.shared.info("\(source)：已停用外部控制，忽略", category: "URL")
            return false
        }
        guard isRecordingAllowed else {
            AppLogger.shared.info("\(source)：引導尚未完成，忽略", category: "URL")
            return false
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsStore.shared = settingsStore
        setupPipeline()
        showPersistenceNoticeIfNeeded()

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
            .filter { !Self.launcherBundleIDs.contains(($0.bundleIdentifier ?? "").lowercased()) }
            .sink { [weak self] app in self?.lastExternalApp = app }
            .store(in: &cancellables)
        lastExternalApp = NSWorkspace.shared.frontmostApplication

        // 語音模式增刪 / 改快捷鍵 → 重新綁定
        settingsStore.$voiceModes
            .dropFirst()
            .sink { [weak self] modes in self?.registerModeHotkeys(modes) }
            .store(in: &cancellables)

        // 主快捷鍵改變 → 重新檢查語音模式快捷鍵是否撞到（@Published 在 willSet 發送，延到下一輪再讀新值）
        settingsStore.$hotkeyKeyCode.combineLatest(settingsStore.$hotkeyModifiers)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.registerModeHotkeys(self.settingsStore.voiceModes)
            }
            .store(in: &cancellables)
    }

    // MARK: - URL Scheme（Raycast / 捷徑 / Stream Deck）

    private struct URLSender {
        let pid: pid_t?
        let bundleID: String?
        let name: String?
    }

    /// 從目前處理中的 Apple Event 取得送出者；只在 application(_:open:) 同步區段內有效
    private static func currentURLSender() -> URLSender {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let descriptor = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr)) else {
            return URLSender(pid: nil, bundleID: nil, name: nil)
        }
        let pid = pid_t(descriptor.int32Value)
        guard pid > 0 else { return URLSender(pid: nil, bundleID: nil, name: nil) }
        let app = NSRunningApplication(processIdentifier: pid)
        return URLSender(pid: pid, bundleID: app?.bundleIdentifier, name: app?.localizedName)
    }

    nonisolated private static func isSettingsURL(_ url: URL) -> Bool {
        (url.host ?? "").lowercased() == "settings"
    }

    /// saybit://toggle、saybit://start、saybit://stop、saybit://cancel，可加 ?mode=<模式名稱>
    /// saybit://settings?tab=general|api|hotkey|dictionary|transcribe|history|statistics|logs
    func application(_ application: NSApplication, open urls: [URL]) {
        let sender = Self.currentURLSender()

        // saybit://settings 只開設定頁，不需驗證來源，也本來就要把 Saybit 帶到前景
        urls.filter(Self.isSettingsURL).forEach(handleURL)
        let controlURLs = urls.filter { !Self.isSettingsURL($0) }
        guard !controlURLs.isEmpty else { return }

        let senderLabel = sender.bundleID ?? sender.pid.map { "pid \($0)" } ?? "unknown"
        guard settingsStore.enableURLSchemeControl else {
            AppLogger.shared.info("URL scheme 控制已停用，忽略來自 \(senderLabel) 的指令", category: "URL")
            return
        }
        guard isRecordingAllowed else {
            AppLogger.shared.info("引導尚未完成，忽略來自 \(senderLabel) 的 URL 指令", category: "URL")
            return
        }

        let now = Date()
        let fresh = controlURLs.filter { url in
            let key = url.absoluteString.lowercased()
            if let last = lastURLCommandAt[key], now.timeIntervalSince(last) < 1 {
                AppLogger.shared.info("URL 指令 1 秒內重複，丟棄: \(url.host ?? "")（來源 \(senderLabel)）", category: "URL")
                return false
            }
            lastURLCommandAt[key] = now
            return true
        }
        guard !fresh.isEmpty else { return }

        guard authorizeURLSender(sender) else { return }
        performURLCommands(fresh)
    }

    /// 來源在允許清單 → 直接通過；否則詢問使用者。拿不到 pid / bundle ID 一律視為未知來源。
    private func authorizeURLSender(_ sender: URLSender) -> Bool {
        if sender.pid == ProcessInfo.processInfo.processIdentifier { return true }
        if let id = sender.bundleID,
           settingsStore.urlSchemeAllowedSenders.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) {
            return true
        }
        if isPromptingURLSender {
            AppLogger.shared.info("正在詢問 URL 來源授權，丟棄來自 \(sender.bundleID ?? "unknown") 的指令", category: "URL")
            return false
        }
        isPromptingURLSender = true
        defer { isPromptingURLSender = false }

        let name = sender.name ?? sender.bundleID ?? "不明的 App"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(name) 想透過 Saybit 開始錄音並輸入文字"
        if let id = sender.bundleID {
            alert.informativeText = "來源：\(id)\n允許後，這個 App 可以讓 Saybit 開始 / 停止錄音，並把結果輸入到目前使用中的 App。"
        } else {
            alert.informativeText = "無法辨識送出這個指令的程式（可能是終端機指令或背景程式）。若不是你自己觸發的，請拒絕。"
        }
        var rememberButton: NSButton?
        if sender.bundleID != nil {
            rememberButton = alert.addButton(withTitle: "允許並記住")
        }
        let onceButton = alert.addButton(withTitle: "僅此一次")
        let denyButton = alert.addButton(withTitle: "拒絕")
        // 預設按鈕（Return）是拒絕，避免誤按就放行
        rememberButton?.keyEquivalent = ""
        onceButton.keyEquivalent = ""
        denyButton.keyEquivalent = "\r"

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let buttons = alert.buttons
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let chosen = buttons.indices.contains(index) ? buttons[index] : denyButton

        if let rememberButton, chosen === rememberButton, let id = sender.bundleID {
            settingsStore.urlSchemeAllowedSenders.append(id)
            AppLogger.shared.info("URL 來源已加入允許清單: \(id)", category: "URL")
            return true
        }
        if chosen === onceButton {
            AppLogger.shared.info("URL 來源僅此一次允許: \(sender.bundleID ?? "unknown")", category: "URL")
            return true
        }
        AppLogger.shared.info("URL 來源被拒絕: \(sender.bundleID ?? "unknown")", category: "URL")
        return false
    }

    private func performURLCommands(_ urls: [URL]) {
        // 開 URL（或授權對話框）會把 Saybit 帶到前景；先把焦點還給原本的 App，文字才會輸入到正確位置
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
                    self?.finishOnboarding(startTutorial: false, closedByUser: false)
                }
            },
            onStartTutorial: { [weak self] in
                DispatchQueue.main.async {
                    self?.finishOnboarding(startTutorial: true, closedByUser: false)
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
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }

        self.onboardingWindow = window
    }

    /// 引導結束的唯一收尾：按完成、按開始教學、或直接按紅色關閉鈕都走這裡。
    /// - closedByUser: 使用者用關閉鈕跳過；不標記完成（下次啟動會再顯示），但本次仍註冊快捷鍵並請求權限。
    private func finishOnboarding(startTutorial: Bool, closedByUser: Bool) {
        guard let window = onboardingWindow else { return }
        onboardingWindow = nil
        window.delegate = nil
        if !closedByUser { window.close() }
        // 拆掉 SwiftUI 內容，讓引導頁的麥克風測試等 onDisappear 收尾
        DispatchQueue.main.async { window.contentView = nil }

        if closedByUser {
            AppLogger.shared.info("引導視窗被關閉（未完成），照常註冊快捷鍵並請求權限", category: "Onboarding")
            requestPermissions()
        }
        setupHotKey()
        if startTutorial {
            showTutorial()
        } else {
            OverlayWindowController.restoreAccessoryPolicyIfNoWindows(closing: window)
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === onboardingWindow {
            finishOnboarding(startTutorial: false, closedByUser: true)
        } else if window === tutorialWindow {
            finishTutorial(closedByUser: true)
        }
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
            self?.finishTutorial(closedByUser: false)
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
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }

        self.tutorialWindow = window
    }

    /// 教學結束的唯一收尾（完成或按紅色關閉鈕）
    private func finishTutorial(closedByUser: Bool) {
        guard let window = tutorialWindow else { return }
        tutorialWindow = nil
        window.delegate = nil
        if !closedByUser { window.close() }
        DispatchQueue.main.async { window.contentView = nil }
        // 教學頁可能留著快捷鍵錄製狀態
        GlobalHotKeyManager.shared.cancelRecording()
        OverlayWindowController.restoreAccessoryPolicyIfNoWindows(closing: window)
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
        configurePermissionCallbacks()
        hotKeyManager?.register(
            keyCode: UInt16(settingsStore.hotkeyKeyCode),
            modifiers: CGEventFlags(rawValue: UInt64(settingsStore.hotkeyModifiers))
        )
        registerModeHotkeys(settingsStore.voiceModes)
    }

    /// 每個有設定快捷鍵的語音模式：按一下開始 / 再按一下停止
    private func registerModeHotkeys(_ modes: [VoiceMode]) {
        let mainKeyCode = settingsStore.hotkeyKeyCode
        let mainModifiers = UInt64(settingsStore.hotkeyModifiers)
        let bindings = modes.compactMap { mode -> GlobalHotKeyManager.Binding? in
            guard mode.hasHotkey, let keyCode = mode.keyCode else { return nil }
            // 與主快捷鍵相同時讓給主快捷鍵，否則模式綁定會先把主快捷鍵吃掉
            if mode.hotkeyConflicts(keyCode: mainKeyCode, modifiers: mainModifiers) {
                AppLogger.shared.error("語音模式「\(mode.name)」的快捷鍵與主快捷鍵相同，已略過", category: "HotKey")
                return nil
            }
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

    /// 輔助使用未授權 / 被撤銷時在膠囊附近提示；授權後 GlobalHotKeyManager 會自動重新註冊
    private func configurePermissionCallbacks() {
        hotKeyManager?.onRegistrationFailed = {
            OverlayWindowController.shared.showTransientNotice(
                text: "快捷鍵尚未啟用：請到「系統設定 › 隱私權與安全性 › 輔助使用」允許 Saybit",
                duration: 6
            )
        }
        hotKeyManager?.onPermissionLost = {
            OverlayWindowController.shared.showTransientNotice(
                text: "輔助使用權限已被關閉，快捷鍵與文字輸入暫時無法使用",
                duration: 6
            )
        }
        hotKeyManager?.onRegistrationRecovered = {
            OverlayWindowController.shared.showTransientNotice(text: "快捷鍵已啟用", duration: 2)
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

    // MARK: - Core Data 復原提示

    /// Core Data 在 App 初始化時載入失敗（已備份重建或改用記憶體 store）→ 啟動後告知使用者
    private func showPersistenceNoticeIfNeeded() {
        guard let notice = PersistenceController.pendingUserNotice else { return }
        PersistenceController.pendingUserNotice = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = notice.title
            alert.informativeText = notice.message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            if let path = UserDefaults.standard.string(forKey: PersistenceController.lastRecoveryBackupPathKey),
               notice.title.contains("已重建") {
                alert.addButton(withTitle: "在 Finder 中顯示備份")
                if alert.runModal() == .alertSecondButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            } else {
                alert.runModal()
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

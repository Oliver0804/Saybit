//
//  OverlayWindow.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import AppKit
import SwiftUI

// MARK: - Custom Hosting View (transparent, sizes to SwiftUI content)

class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

/// Panel 的透明容器 — 純透明，子視圖透過 Auto Layout 置中
class TransparentContainerView: NSView {
    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    // 讓 isMovableByWindowBackground 在透明區域也能觸發拖曳
    override var mouseDownCanMoveWindow: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = .clear
    }
}

// MARK: - Overlay Window Controller

class OverlayWindowController: NSObject {
    static let shared = OverlayWindowController()

    private var panel: NSPanel?
    private var session: TranscriptionSession?
    private(set) var settingsStore: SettingsStore?
    private weak var pipeline: VoicePipeline?
    private var moveObserver: Any?
    private var rightClickMonitor: Any?
    private var leftDownMonitor: Any?
    private var leftUpMonitor: Any?
    private var dragMonitor: Any?
    /// 拖曳：按下時的滑鼠螢幕座標與 panel 原點；超過門檻才算拖曳（避免把點擊當拖曳）
    private var dragStartMouse: NSPoint = .zero
    private var dragStartOrigin: NSPoint = .zero
    private var isDragging = false
    private var settingsWindow: NSWindow?

    // Click vs drag discrimination
    private var mouseDownTime: Date = .distantPast

    private let panelWidth: CGFloat = 900
    private let panelHeight: CGFloat = 240

    deinit {
        if let observer = moveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let monitor = rightClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = leftDownMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = leftUpMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = dragMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func configure(session: TranscriptionSession, settingsStore: SettingsStore, pipeline: VoicePipeline) {
        self.session = session
        self.settingsStore = settingsStore
        self.pipeline = pipeline
    }

    func show() {
        if panel == nil {
            setupPanel()
        }
        guard let panel else { return }
        panel.orderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: - Panel Setup

    private func setupPanel() {
        let origin = initialPosition()

        let panel = NSPanel(
            contentRect: NSRect(x: origin.x, y: origin.y, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 拖曳改由下方 event monitor 自行處理：SwiftUI 的 hosting view 不會把拖曳交給
        // isMovableByWindowBackground，原本只有膠囊外圍的透明邊緣拖得動
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false

        let pipelineRef = self.pipeline
        let capsuleView = CapsuleBarView(
            session: session ?? TranscriptionSession(),
            settingsStore: settingsStore ?? SettingsStore(),
            onConfirmInject: { pipelineRef?.confirmInject() },
            onRegenerate: { pipelineRef?.regenerate() },
            onCancelPreview: { pipelineRef?.cancelPreview() },
            onRetry: { pipelineRef?.retryLastAction() }
        )
        let hostingView = OverlayHostingView(rootView: capsuleView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.setContentHuggingPriority(.required, for: .horizontal)
        hostingView.setContentHuggingPriority(.required, for: .vertical)
        hostingView.setContentCompressionResistancePriority(.required, for: .horizontal)
        hostingView.setContentCompressionResistancePriority(.required, for: .vertical)

        // 用透明容器包裝，hostingView 透過 constraints 只佔膠囊實際大小並置中
        let container = TransparentContainerView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            hostingView.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        panel.contentView = container
        self.panel = panel

        // Right-click context menu via local event monitor
        // (SwiftUI's internal views intercept rightMouseDown, so we monitor at app level)
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard
                let self,
                let panel = self.panel,
                event.window == panel,
                let contentView = panel.contentView
            else {
                return event
            }
            let menu = self.buildContextMenu()
            NSMenu.popUpContextMenu(menu, with: event, for: contentView)
            return nil
        }

        // Left-click monitor: record mouseDown position + time
        leftDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window == panel else { return event }
            self.dragStartMouse = NSEvent.mouseLocation
            self.dragStartOrigin = panel.frame.origin
            self.isDragging = false
            self.mouseDownTime = Date()
            return event
        }

        // 拖曳膠囊（不論按在膠囊本體或邊緣）
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            guard let self, let panel = self.panel, event.window == panel else { return event }
            let now = NSEvent.mouseLocation
            let dx = now.x - self.dragStartMouse.x
            let dy = now.y - self.dragStartMouse.y
            if !self.isDragging && hypot(dx, dy) < 4 { return event }
            self.isDragging = true
            panel.setFrameOrigin(NSPoint(x: self.dragStartOrigin.x + dx, y: self.dragStartOrigin.y + dy))
            return nil
        }

        // Left-click monitor: check if it's a tap (not drag)
        leftUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self, let panel = self.panel, event.window == panel else { return event }
            if self.isDragging {
                self.isDragging = false
                // 拖到螢幕外就拉回可見範圍
                let clamped = self.clampToVisibleScreen(panel.frame)
                if clamped.origin != panel.frame.origin { panel.setFrameOrigin(clamped.origin) }
                return event
            }
            let elapsed = Date().timeIntervalSince(self.mouseDownTime)
            if elapsed < 0.3 {
                self.handleCapsuleTap()
            }
            return event
        }

        // Observe drag to save position
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.savePosition()
        }
    }

    func rebuild() {
        if let observer = moveObserver {
            NotificationCenter.default.removeObserver(observer)
            moveObserver = nil
        }
        if let monitor = rightClickMonitor {
            NSEvent.removeMonitor(monitor)
            rightClickMonitor = nil
        }
        if let monitor = leftDownMonitor {
            NSEvent.removeMonitor(monitor)
            leftDownMonitor = nil
        }
        if let monitor = leftUpMonitor {
            NSEvent.removeMonitor(monitor)
            leftUpMonitor = nil
        }
        if let monitor = dragMonitor {
            NSEvent.removeMonitor(monitor)
            dragMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Position Memory

    private func initialPosition() -> NSPoint {
        guard let screen = Self.screenUnderMouse() else {
            return NSPoint(x: 200, y: 200)
        }
        let screenFrame = screen.visibleFrame

        if let store = settingsStore, store.hasCustomOverlayPosition {
            let candidate = NSRect(
                x: store.overlayPositionX,
                y: store.overlayPositionY,
                width: Double(panelWidth),
                height: Double(panelHeight)
            )
            let clamped = clampToVisibleScreen(candidate)
            return clamped.origin
        }

        // Default: top-center of screen
        let x = screenFrame.midX - panelWidth / 2
        let y = screenFrame.maxY - panelHeight - 12
        return NSPoint(x: x, y: y)
    }

    private func savePosition() {
        guard let panel, let store = settingsStore else { return }
        store.overlayPositionX = Double(panel.frame.origin.x)
        store.overlayPositionY = Double(panel.frame.origin.y)
        store.hasCustomOverlayPosition = true
    }

    private func clampToVisibleScreen(_ rect: NSRect) -> NSRect {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(rect) })
                ?? NSScreen.main else { return rect }
        let visible = screen.visibleFrame
        var origin = rect.origin
        origin.x = max(visible.minX, min(origin.x, visible.maxX - rect.width))
        origin.y = max(visible.minY, min(origin.y, visible.maxY - rect.height))
        return NSRect(origin: origin, size: rect.size)
    }

    // MARK: - Capsule Tap

    private func handleCapsuleTap() {
        guard let session else { return }
        // 引導還沒走完不允許從膠囊開始錄音（停止 / 取消仍可）
        let recordingAllowed = (NSApp.delegate as? AppDelegate)?.isRecordingAllowed ?? true
        switch session.state {
        case .idle where !recordingAllowed, .confirming where !recordingAllowed:
            AppLogger.shared.info("引導尚未完成，忽略膠囊點擊", category: "Overlay")
        case .idle:
            pipeline?.startListening()
        case .listening:
            pipeline?.cancelListening()
        case .recording:
            pipeline?.stopRecordingAndProcess()
        case .confirming:
            pipeline?.toggleRecording()
        default:
            break
        }
    }

    // MARK: - Context Menu (NSMenu)

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        // Prompt Style submenu
        let promptItem = NSMenuItem(title: L10n.Overlay.promptStyleMenu, action: nil, keyEquivalent: "")
        let promptSubmenu = NSMenu()
        for style in PromptStyle.allCases {
            let item = NSMenuItem(title: style.displayName, action: #selector(selectPromptStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = (settingsStore?.promptStyle == style) ? .on : .off
            promptSubmenu.addItem(item)
        }
        promptItem.submenu = promptSubmenu
        menu.addItem(promptItem)

        // Tone submenu
        let toneItem = NSMenuItem(title: L10n.Overlay.toneMenu, action: nil, keyEquivalent: "")
        let toneSubmenu = NSMenu()
        for tone in ToneStyle.allCases {
            let item = NSMenuItem(title: tone.displayName, action: #selector(selectToneStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tone.rawValue
            item.state = (settingsStore?.toneStyle == tone) ? .on : .off
            toneSubmenu.addItem(item)
        }
        toneItem.submenu = toneSubmenu
        menu.addItem(toneItem)

        menu.addItem(.separator())

        // Whisper Mode toggle
        let whisperItem = NSMenuItem(title: L10n.General.whisperMode, action: #selector(toggleWhisperMode(_:)), keyEquivalent: "")
        whisperItem.target = self
        whisperItem.state = (settingsStore?.enableWhisperMode == true) ? .on : .off
        menu.addItem(whisperItem)

        // Continuous STT toggle (only for Apple Speech)
        if settingsStore?.sttEngine == .appleSpeech {
            let continuousItem = NSMenuItem(title: L10n.General.continuousBackgroundSTT, action: #selector(toggleContinuousSTT(_:)), keyEquivalent: "")
            continuousItem.target = self
            continuousItem.state = (settingsStore?.enableContinuousSTT == true) ? .on : .off
            menu.addItem(continuousItem)
        }

        // Context Awareness toggle
        let contextItem = NSMenuItem(title: L10n.General.contextAwareness, action: #selector(toggleContextAwareness(_:)), keyEquivalent: "")
        contextItem.target = self
        contextItem.state = (settingsStore?.enableContextAwareness == true) ? .on : .off
        menu.addItem(contextItem)

        // Sound Feedback toggle
        let soundItem = NSMenuItem(title: L10n.General.soundFeedback, action: #selector(toggleSoundFeedback(_:)), keyEquivalent: "")
        soundItem.target = self
        soundItem.state = (settingsStore?.enableSoundFeedback == true) ? .on : .off
        menu.addItem(soundItem)

        // Smart Send toggle
        let smartSendItem = NSMenuItem(title: L10n.General.smartSend, action: #selector(toggleSmartSend(_:)), keyEquivalent: "")
        smartSendItem.target = self
        smartSendItem.state = (settingsStore?.enableSmartSend == true) ? .on : .off
        menu.addItem(smartSendItem)

        menu.addItem(.separator())

        // Reset position
        let resetPosItem = NSMenuItem(title: L10n.Overlay.resetPosition, action: #selector(resetPosition(_:)), keyEquivalent: "")
        resetPosItem.target = self
        menu.addItem(resetPosItem)

        // Settings...
        let settingsItem = NSMenuItem(title: L10n.Common.settings, action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // About - use zero-width space to prevent system auto-icon
        let aboutItem = NSMenuItem(title: "\u{200B}\(L10n.Common.about)", action: #selector(showAbout(_:)), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(title: L10n.Common.quit, action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - Menu Actions

    @objc private func selectPromptStyle(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let style = PromptStyle(rawValue: rawValue) else { return }
        settingsStore?.promptStyle = style
    }

    @objc private func selectToneStyle(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let tone = ToneStyle(rawValue: rawValue) else { return }
        settingsStore?.toneStyle = tone
    }

    @objc private func toggleWhisperMode(_ sender: NSMenuItem) {
        settingsStore?.enableWhisperMode.toggle()
    }

    @objc private func toggleContextAwareness(_ sender: NSMenuItem) {
        settingsStore?.enableContextAwareness.toggle()
    }

    @objc private func toggleSoundFeedback(_ sender: NSMenuItem) {
        settingsStore?.enableSoundFeedback.toggle()
    }

    @objc private func toggleSmartSend(_ sender: NSMenuItem) {
        settingsStore?.enableSmartSend.toggle()
    }

    @objc private func toggleContinuousSTT(_ sender: NSMenuItem) {
        settingsStore?.enableContinuousSTT.toggle()
    }

    @objc private func resetPosition(_ sender: NSMenuItem) {
        resetPosition()
    }

    /// 把膠囊移回螢幕上方中央
    func resetPosition() {
        // 移到「滑鼠所在螢幕」的上方中央：多螢幕時 NSScreen.main 不一定是使用者正在看的那個
        guard let screen = Self.screenUnderMouse() else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - panelWidth / 2
        let y = screenFrame.maxY - panelHeight - 12
        panel?.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true, animate: true)
        panel?.orderFrontRegardless()
        settingsStore?.hasCustomOverlayPosition = false
    }

    static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        openSettings()
    }

    /// 開啟（或帶到前景）設定視窗；可指定分頁
    func openSettings(tab: SettingsTab? = nil) {
        if let tab { SettingsNavigation.shared.tab = tab }
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
            .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
            .environmentObject(settingsStore ?? SettingsStore())

        let hostingView = NSHostingView(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = L10n.Overlay.settingsWindowTitle
        window.contentView = hostingView
        window.minSize = NSSize(width: 1000, height: 600)

        // Auto-size window to fit content
        let fittingSize = hostingView.fittingSize
        window.setContentSize(NSSize(
            width: max(fittingSize.width, 820),
            height: max(fittingSize.height, 600)
        ))
        window.center()

        NSApp.setActivationPolicy(.regular)
        restoreAccessoryPolicyOnClose(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window
    }

    // MARK: - Activation Policy

    private var closeObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

    /// 視窗關閉時若已沒有其他一般視窗，把 activation policy 改回 .accessory（不留 Dock 圖示 / ⌘Tab）
    private func restoreAccessoryPolicyOnClose(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        if let old = closeObservers[key] { NotificationCenter.default.removeObserver(old) }
        closeObservers[key] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                if let token = self?.closeObservers.removeValue(forKey: key) {
                    NotificationCenter.default.removeObserver(token)
                }
                Self.restoreAccessoryPolicyIfNoWindows(closing: window)
            }
        }
    }

    /// 除了 `closing` 之外已沒有可見（或最小化）的一般視窗 → 改回 .accessory。AppDelegate 的引導 / 教學視窗也共用。
    static func restoreAccessoryPolicyIfNoWindows(closing: NSWindow?) {
        DispatchQueue.main.async {
            let hasOtherWindow = NSApp.windows.contains { window in
                window !== closing
                    && !(window is NSPanel)
                    && window.styleMask.contains(.titled)
                    && (window.isVisible || window.isMiniaturized)
            }
            if !hasOtherWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    // MARK: - Transient Notice

    private var noticePanel: NSPanel?
    private var noticeDismissWork: DispatchWorkItem?

    /// 在膠囊附近短暫顯示一則提示（例如「已學習 X → Y」），可附「撤銷」按鈕；不搶焦點。
    func showTransientNotice(text: String, duration: TimeInterval = 3, undo: (() -> Void)? = nil) {
        noticeDismissWork?.cancel()
        noticePanel?.orderOut(nil)

        let view = TransientNoticeView(text: text, showsUndo: undo != nil) { [weak self] in
            undo?()
            self?.hideTransientNotice()
        }
        let hosting = OverlayHostingView(rootView: view)
        let size = hosting.fittingSize

        let notice = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        notice.isReleasedWhenClosed = false
        notice.level = .floating
        notice.isOpaque = false
        notice.backgroundColor = .clear
        notice.hasShadow = true
        notice.hidesOnDeactivate = false
        notice.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        notice.contentView = hosting

        var origin: NSPoint
        if let panel, panel.isVisible {
            // 膠囊在 panel 中央；提示放在膠囊下方
            origin = NSPoint(x: panel.frame.midX - size.width / 2, y: panel.frame.midY - 60 - size.height)
        } else if let screen = Self.screenUnderMouse() {
            origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 80)
        } else {
            origin = NSPoint(x: 200, y: 200)
        }
        origin = clampToVisibleScreen(NSRect(origin: origin, size: size)).origin
        notice.setFrameOrigin(origin)
        notice.orderFrontRegardless()
        noticePanel = notice

        let work = DispatchWorkItem { [weak self] in self?.hideTransientNotice() }
        noticeDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func hideTransientNotice() {
        noticeDismissWork?.cancel()
        noticeDismissWork = nil
        noticePanel?.orderOut(nil)
        noticePanel = nil
    }

    @objc private func showAbout(_ sender: NSMenuItem) {
        let aboutView = AboutView()
        let hostingView = NSHostingView(rootView: aboutView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = L10n.Common.about
        window.contentView = hostingView
        window.center()

        NSApp.setActivationPolicy(.regular)
        restoreAccessoryPolicyOnClose(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}

// MARK: - Transient Notice View

private struct TransientNoticeView: View {
    let text: String
    let showsUndo: Bool
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "book.closed")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .lineLimit(2)
                .frame(maxWidth: 360, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if showsUndo {
                Button("撤銷", action: onUndo)
                    .buttonStyle(.borderless)
                    .font(.callout.weight(.semibold))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(4)
    }
}

//
//  OverlayWindow.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import AppKit
import SwiftUI

// MARK: - Custom Hosting View (right-click menu + hit-test passthrough)

class OverlayHostingView<Content: View>: NSHostingView<Content> {}

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
    private var settingsWindow: NSWindow?

    // Click vs drag discrimination
    private var mouseDownLocation: NSPoint = .zero
    private var mouseDownTime: Date = .distantPast

    private let panelWidth: CGFloat = 840
    private let panelHeight: CGFloat = 160

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
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        let pipelineRef = self.pipeline
        let capsuleView = CapsuleBarView(
            session: session ?? TranscriptionSession(),
            settingsStore: settingsStore ?? SettingsStore(),
            onConfirmInject: { pipelineRef?.confirmInject() },
            onRegenerate: { pipelineRef?.regenerate() },
            onCancelPreview: { pipelineRef?.cancelPreview() }
        )
        let hostingView = OverlayHostingView(rootView: capsuleView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hostingView.setContentHuggingPriority(.defaultLow, for: .vertical)
        hostingView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hostingView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        panel.contentView = hostingView
        self.panel = panel

        // Right-click context menu via local event monitor
        // (SwiftUI's internal views intercept rightMouseDown, so we monitor at app level)
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, event.window == self.panel else { return event }
            let menu = self.buildContextMenu()
            NSMenu.popUpContextMenu(menu, with: event, for: event.window!.contentView!)
            return nil
        }

        // Left-click monitor: record mouseDown position + time
        leftDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.window == self.panel else { return event }
            self.mouseDownLocation = event.locationInWindow
            self.mouseDownTime = Date()
            return event // pass through so drag still works
        }

        // Left-click monitor: check if it's a tap (not drag)
        leftUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self, event.window == self.panel else { return event }
            let displacement = hypot(
                event.locationInWindow.x - self.mouseDownLocation.x,
                event.locationInWindow.y - self.mouseDownLocation.y
            )
            let elapsed = Date().timeIntervalSince(self.mouseDownTime)
            if displacement < 5 && elapsed < 0.3 {
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
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Position Memory

    private func initialPosition() -> NSPoint {
        guard let screen = NSScreen.main else {
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
        switch session.state {
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
        let whisperItem = NSMenuItem(title: "Whisper Mode", action: #selector(toggleWhisperMode(_:)), keyEquivalent: "")
        whisperItem.target = self
        whisperItem.state = (settingsStore?.enableWhisperMode == true) ? .on : .off
        menu.addItem(whisperItem)

        // Context Awareness toggle
        let contextItem = NSMenuItem(title: "Context Awareness", action: #selector(toggleContextAwareness(_:)), keyEquivalent: "")
        contextItem.target = self
        contextItem.state = (settingsStore?.enableContextAwareness == true) ? .on : .off
        menu.addItem(contextItem)

        // Sound Feedback toggle
        let soundItem = NSMenuItem(title: L10n.General.soundFeedback, action: #selector(toggleSoundFeedback(_:)), keyEquivalent: "")
        soundItem.target = self
        soundItem.state = (settingsStore?.enableSoundFeedback == true) ? .on : .off
        menu.addItem(soundItem)

        // Smart Send toggle
        let smartSendItem = NSMenuItem(title: "Smart Send", action: #selector(toggleSmartSend(_:)), keyEquivalent: "")
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

    @objc private func resetPosition(_ sender: NSMenuItem) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - panelWidth / 2
        let y = screenFrame.maxY - panelHeight - 12
        panel?.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true, animate: true)
        settingsStore?.hasCustomOverlayPosition = false
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
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
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 800),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = L10n.Overlay.settingsWindowTitle
        window.contentView = hostingView
        window.minSize = NSSize(width: 820, height: 600)

        // Auto-size window to fit content
        let fittingSize = hostingView.fittingSize
        window.setContentSize(NSSize(
            width: max(fittingSize.width, 820),
            height: max(fittingSize.height, 600)
        ))
        window.center()

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window
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
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}

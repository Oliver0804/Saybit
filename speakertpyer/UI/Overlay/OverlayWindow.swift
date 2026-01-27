//
//  OverlayWindow.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import AppKit
import SwiftUI

class OverlayWindowController {
    static let shared = OverlayWindowController()

    private var panel: NSPanel?
    private var session: TranscriptionSession?
    private var settingsStore: SettingsStore?

    func configure(session: TranscriptionSession, settingsStore: SettingsStore) {
        self.session = session
        self.settingsStore = settingsStore
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

    private func setupPanel() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame

        // Panel is large enough for expanded content; transparent areas are see-through
        let panelWidth: CGFloat = 360
        let panelHeight: CGFloat = 420
        let margin: CGFloat = 24
        let x = screenFrame.maxX - panelWidth - margin
        let y = screenFrame.minY + margin

        let panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: panelWidth, height: panelHeight),
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

        let overlayView = BubbleView(
            session: session ?? TranscriptionSession(),
            settingsStore: settingsStore ?? SettingsStore()
        )
        let hostingView = NSHostingView(rootView: overlayView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.autoresizingMask = [.width, .height]
        // Prevent hosting view from shrinking to content size
        hostingView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hostingView.setContentHuggingPriority(.defaultLow, for: .vertical)
        hostingView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hostingView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        panel.contentView = hostingView

        self.panel = panel
    }

    func rebuild() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Resize panel when bubble expands
    func resizeForExpanded() {
        guard let panel, let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let margin: CGFloat = 24
        let expandedWidth: CGFloat = 320
        let expandedHeight: CGFloat = 300
        let x = screenFrame.maxX - expandedWidth - margin
        let y = screenFrame.minY + margin
        panel.setFrame(NSRect(x: x, y: y, width: expandedWidth, height: expandedHeight), display: true)
    }

    func resizeForCollapsed() {
        guard let panel, let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let margin: CGFloat = 24
        let w: CGFloat = 72
        let h: CGFloat = 72
        let x = screenFrame.maxX - w - margin
        let y = screenFrame.minY + margin
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }
}

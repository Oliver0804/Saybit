//
//  KeyboardModel.swift
//  SaybitKeyboard
//

import Observation
import UIKit

@Observable
final class KeyboardModel {
    enum Phase: Equatable {
        case ready              // 可以按麥克風
        case launching          // 正在叫醒主 App
        case recording
        case processing
        case inserted(String)   // 剛插入的結果（可撤銷）
        case message(String)    // 錯誤 / 提示
    }

    private(set) var phase: Phase = .ready
    private(set) var partialText = ""
    private(set) var level: Float = 0
    private(set) var hasFullAccess = false
    private(set) var sessionAlive = false
    private(set) var returnKeyTitle = "換行"

    @ObservationIgnored private let fullAccess: () -> Bool
    @ObservationIgnored private let proxy: () -> UITextDocumentProxy?
    @ObservationIgnored private let openURL: (URL) -> Bool
    @ObservationIgnored let advanceToNextInputMode: () -> Void
    @ObservationIgnored private var bridge: KeyboardBridge?
    @ObservationIgnored private var observerToken: UUID?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var startTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var lastInsertedText: String?

    init(
        hasFullAccess: @escaping () -> Bool,
        proxy: @escaping () -> UITextDocumentProxy?,
        openURL: @escaping (URL) -> Bool,
        advanceToNextInputMode: @escaping () -> Void
    ) {
        self.fullAccess = hasFullAccess
        self.proxy = proxy
        self.openURL = openURL
        self.advanceToNextInputMode = advanceToNextInputMode
    }

    // MARK: - Lifecycle

    func activate() {
        hasFullAccess = fullAccess()
        guard hasFullAccess else {
            phase = .message("請到「設定 › 一般 › 鍵盤 › Saybit」開啟「允許完整取用」")
            return
        }
        let bridge = KeyboardBridge()
        self.bridge = bridge
        observerToken = DarwinNotificationCenter.shared.addObserver(KeyboardBridge.Notify.state) { [weak self] in
            MainActor.assumeIsolated { self?.syncFromBridge() }
        }
        // 心跳 / session 狀態用輪詢（Darwin 通知只在狀態改變時才發）
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSession() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        refreshSession()
        refreshReturnKey()
        // 從主 App 回來時，可能已有結果在等著插入
        syncFromBridge()
    }

    func deactivate() {
        if let observerToken { DarwinNotificationCenter.shared.removeObserver(observerToken) }
        observerToken = nil
        pollTimer?.invalidate()
        pollTimer = nil
        startTimeoutTask?.cancel()
    }

    private func refreshSession() {
        sessionAlive = bridge?.isAppSessionAlive() ?? false
    }

    func refreshReturnKey() {
        switch proxy()?.returnKeyType {
        case .send: returnKeyTitle = "傳送"
        case .search, .google, .yahoo: returnKeyTitle = "搜尋"
        case .go: returnKeyTitle = "前往"
        case .done: returnKeyTitle = "完成"
        case .next: returnKeyTitle = "下一個"
        default: returnKeyTitle = "換行"
        }
    }

    // MARK: - Bridge Sync

    private func syncFromBridge() {
        guard let bridge else { return }
        switch bridge.state {
        case .recording:
            startTimeoutTask?.cancel()
            phase = .recording
            partialText = bridge.partialText
            level = bridge.audioLevel
        case .processing:
            phase = .processing
            partialText = bridge.partialText
        case .done:
            if let result = bridge.takeUnconsumedResult() {
                insert(result.text)
            } else if case .processing = phase {
                phase = .ready
            } else if case .recording = phase {
                phase = .ready
            }
        case .error:
            startTimeoutTask?.cancel()
            if phase == .recording || phase == .processing || phase == .launching {
                phase = .message(bridge.errorMessage ?? "發生錯誤")
            }
        case .idle:
            if phase == .recording || phase == .processing {
                phase = .ready
                partialText = ""
            }
        }
    }

    // MARK: - Mic

    func micTapped() {
        guard hasFullAccess, let bridge else {
            phase = .message("請先開啟「允許完整取用」")
            return
        }
        switch phase {
        case .recording:
            bridge.send(.stop)
            phase = .processing
        case .processing, .launching:
            break
        default:
            start(bridge)
        }
    }

    func cancelTapped() {
        bridge?.send(.cancel)
        phase = .ready
        partialText = ""
    }

    private func start(_ bridge: KeyboardBridge) {
        let selected = proxy()?.selectedText
        partialText = ""
        UIDevice.current.playInputClick()

        if bridge.isAppSessionAlive() {
            bridge.send(.start, selectedText: selected)
            phase = .launching
            // App 若 1.5 秒內沒回報 recording（例如剛好被系統暫停），改為叫醒 App
            startTimeoutTask?.cancel()
            startTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, !Task.isCancelled, self.phase == .launching else { return }
                self.launchApp(bridge, selectedText: selected)
            }
        } else {
            launchApp(bridge, selectedText: selected)
        }
    }

    private func launchApp(_ bridge: KeyboardBridge, selectedText: String?) {
        bridge.send(.start, selectedText: selectedText)
        phase = .launching
        if !openURL(SaybitShared.dictateFromKeyboardURL) {
            phase = .message("無法開啟 Saybit，請先打開 Saybit App 啟動「鍵盤待命」")
        }
    }

    // MARK: - Text Editing

    private func insert(_ text: String) {
        guard let proxy = proxy() else { return }
        proxy.insertText(text)
        lastInsertedText = text
        partialText = ""
        phase = .inserted(text)
    }

    /// 撤銷剛插入的結果（逐字刪除）
    func undoInsert() {
        guard let text = lastInsertedText, let proxy = proxy() else { return }
        for _ in 0..<text.count { proxy.deleteBackward() }
        lastInsertedText = nil
        phase = .ready
    }

    func insertCharacter(_ s: String) {
        UIDevice.current.playInputClick()
        proxy()?.insertText(s)
        if case .inserted = phase { phase = .ready }
    }

    func deleteBackward() {
        UIDevice.current.playInputClick()
        proxy()?.deleteBackward()
        if case .inserted = phase { phase = .ready }
    }

    func returnKey() {
        UIDevice.current.playInputClick()
        proxy()?.insertText("\n")
    }

    func dismissMessage() {
        if case .message = phase { phase = .ready }
    }
}

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
    /// 不是本實例等到的結果（例如鍵盤重新出現時才發現）：不自動插入，由使用者點按鈕
    private(set) var pendingResult: BridgeResult?

    @ObservationIgnored private let fullAccess: () -> Bool
    @ObservationIgnored private let proxy: () -> UITextDocumentProxy?
    @ObservationIgnored private let openURL: (URL, @escaping (Bool) -> Void) -> Void
    @ObservationIgnored let advanceToNextInputMode: () -> Void
    @ObservationIgnored private var bridge: KeyboardBridge?
    @ObservationIgnored private var observerToken: UUID?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var startTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var lastInsertedText: String?

    init(
        hasFullAccess: @escaping () -> Bool,
        proxy: @escaping () -> UITextDocumentProxy?,
        openURL: @escaping (URL, @escaping (Bool) -> Void) -> Void,
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
            startTimeoutTask?.cancel()
            if isAwaitingResult {
                // 本實例發起並等待中的結果 → 自動插入
                if let result = bridge.takeUnconsumedResult() {
                    pendingResult = nil
                    insert(result.text)
                } else {
                    phase = .ready
                }
            } else {
                // 舊結果或別的實例發起的：只提示，不自動插進當下的輸入框
                pendingResult = bridge.unconsumedResult()
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

    /// 本實例在 launching / recording / processing 期間才算「正在等結果」
    private var isAwaitingResult: Bool {
        switch phase {
        case .launching, .recording, .processing: return true
        default: return false
        }
    }

    /// 使用者點「插入剛才的結果」
    func insertPendingResult() {
        guard let bridge, let result = pendingResult else { return }
        pendingResult = nil
        // 結果可能已被其他實例插入或已過期
        guard bridge.unconsumedResult()?.id == result.id else { return }
        bridge.markConsumed(result)
        insert(result.text)
    }

    func dismissPendingResult() {
        guard let bridge, let result = pendingResult else { return }
        pendingResult = nil
        bridge.markConsumed(result)
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
        pendingResult = nil
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
        openURL(SaybitShared.dictateFromKeyboardURL) { [weak self] success in
            guard let self, !success, self.phase == .launching else { return }
            self.phase = .message("無法開啟 Saybit，請先打開 Saybit App 啟動「鍵盤待命」")
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

    /// 撤銷剛插入的結果（逐字刪除）；游標前的內容必須仍以該結果結尾，否則不刪
    func undoInsert() {
        guard let text = lastInsertedText, let proxy = proxy() else { return }
        guard Self.context(proxy.documentContextBeforeInput, endsWith: text) else {
            lastInsertedText = nil
            phase = .message("游標位置已改變，無法復原。請手動刪除。")
            return
        }
        for _ in 0..<text.count { proxy.deleteBackward() }
        lastInsertedText = nil
        phase = .ready
    }

    /// 游標移動 / 宿主改了內容：插入的文字已不在游標前就收掉「復原」
    func selectionOrTextChanged() {
        guard case .inserted = phase else { return }
        guard let text = lastInsertedText,
              Self.context(proxy()?.documentContextBeforeInput, endsWith: text) else {
            lastInsertedText = nil
            phase = .ready
            return
        }
    }

    /// `documentContextBeforeInput` 可能被系統截斷，只給最後一段：
    /// 截斷後的 context 本身是 text 的後綴也視為吻合
    private static func context(_ context: String?, endsWith text: String) -> Bool {
        guard let context, !context.isEmpty, !text.isEmpty else { return false }
        if context.hasSuffix(text) { return true }
        return context.count < text.count && text.hasSuffix(context)
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

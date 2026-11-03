//
//  KeyboardBridge.swift
//  SaybitShared（iOS App ⇄ 鍵盤 extension 共用）
//
//  iOS 自訂鍵盤不能用麥克風，所以採「主 App 錄音、鍵盤插字」架構：
//
//    鍵盤 ──(command: start/stop/cancel)──▶ 主 App（背景 audio session 持續運行）
//    鍵盤 ◀──(state / partial / result)──── 主 App
//
//  資料走 App Group UserDefaults，即時通知走 Darwin notification（跨 process、無 payload）。
//  鍵盤必須開啟「允許完整取用」才能讀寫 App Group。
//

import Foundation

enum SaybitShared {
    static let appGroupID = "group.com.bashcat.speakertpyer"
    static let urlScheme = "saybit"

    /// 鍵盤叫醒主 App 用的 URL
    static let dictateFromKeyboardURL = URL(string: "saybit://dictate?source=keyboard")!
}

// MARK: - Wire Types

/// 主 App 回報給鍵盤的狀態
enum BridgeState: String, Codable {
    case idle          // 待命（session 活著，可直接開始）
    case recording     // 錄音中
    case processing    // AI 處理中
    case done          // 有新結果可插入
    case error         // 失敗（看 errorMessage）
}

/// 鍵盤送給主 App 的指令
enum BridgeCommand: String, Codable {
    case start
    case stop
    case cancel
}

/// 一次辨識結果
struct BridgeResult: Codable, Equatable {
    let id: UUID
    let text: String
    let createdAt: Date
}

// MARK: - Bridge

/// 兩邊共用的讀寫介面。所有屬性都直接讀 App Group defaults，跨 process 不快取。
final class KeyboardBridge {
    static let shared = KeyboardBridge()

    /// 鍵盤沒開「完整取用」時為 nil
    let defaults: UserDefaults?

    private enum Key {
        static let heartbeat = "bridge.heartbeat"
        static let state = "bridge.state"
        static let partial = "bridge.partial"
        static let level = "bridge.level"
        static let errorMessage = "bridge.errorMessage"
        static let result = "bridge.result"
        static let consumedResultID = "bridge.consumedResultID"
        static let command = "bridge.command"
        static let commandID = "bridge.commandID"
        static let commandAt = "bridge.commandAt"
        static let selectedText = "bridge.selectedText"
        static let sessionExpiresAt = "bridge.sessionExpiresAt"
    }

    enum Notify {
        /// 鍵盤 → App：有新指令
        static let command = "com.bashcat.speakertpyer.bridge.command"
        /// App → 鍵盤：狀態 / partial / 結果有變化
        static let state = "com.bashcat.speakertpyer.bridge.state"
    }

    init(defaults: UserDefaults? = UserDefaults(suiteName: SaybitShared.appGroupID)) {
        self.defaults = defaults
    }

    var isAvailable: Bool { defaults != nil }

    // MARK: Session heartbeat (App writes)

    /// 主 App 的 session 每秒寫一次心跳；鍵盤以此判斷能否直接開始錄音
    func beat() {
        defaults?.set(Date().timeIntervalSince1970, forKey: Key.heartbeat)
    }

    func clearHeartbeat() {
        defaults?.removeObject(forKey: Key.heartbeat)
    }

    /// 心跳在 `tolerance` 秒內 → 主 App 的錄音 session 還活著
    func isAppSessionAlive(tolerance: TimeInterval = 2.5) -> Bool {
        guard let t = defaults?.object(forKey: Key.heartbeat) as? Double else { return false }
        return Date().timeIntervalSince1970 - t < tolerance
    }

    var sessionExpiresAt: Date? {
        get { (defaults?.object(forKey: Key.sessionExpiresAt) as? Double).map(Date.init(timeIntervalSince1970:)) }
        set { defaults?.set(newValue?.timeIntervalSince1970, forKey: Key.sessionExpiresAt) }
    }

    // MARK: State (App writes, keyboard reads)

    var state: BridgeState {
        BridgeState(rawValue: defaults?.string(forKey: Key.state) ?? "") ?? .idle
    }

    var partialText: String { defaults?.string(forKey: Key.partial) ?? "" }
    var audioLevel: Float { defaults?.float(forKey: Key.level) ?? 0 }
    var errorMessage: String? { defaults?.string(forKey: Key.errorMessage) }

    var latestResult: BridgeResult? {
        guard let data = defaults?.data(forKey: Key.result) else { return nil }
        return try? JSONDecoder().decode(BridgeResult.self, from: data)
    }

    func publish(state: BridgeState, partial: String? = nil, errorMessage: String? = nil) {
        defaults?.set(state.rawValue, forKey: Key.state)
        if let partial {
            // 空字串直接移除，避免轉錄內容殘留在 App Group plist
            if partial.isEmpty { defaults?.removeObject(forKey: Key.partial) } else { defaults?.set(partial, forKey: Key.partial) }
        }
        defaults?.set(errorMessage, forKey: Key.errorMessage)
        DarwinNotificationCenter.post(Notify.state)
    }

    func publish(partial: String, level: Float) {
        defaults?.set(partial, forKey: Key.partial)
        defaults?.set(level, forKey: Key.level)
        DarwinNotificationCenter.post(Notify.state)
    }

    func publish(result text: String) {
        let result = BridgeResult(id: UUID(), text: text, createdAt: Date())
        if let data = try? JSONEncoder().encode(result) {
            defaults?.set(data, forKey: Key.result)
        }
        defaults?.set(BridgeState.done.rawValue, forKey: Key.state)
        defaults?.removeObject(forKey: Key.partial)
        defaults?.set(nil, forKey: Key.errorMessage)
        DarwinNotificationCenter.post(Notify.state)
    }

    /// 清掉轉錄 / 結果 / 選取文字等內容（取消、空結果、關閉結果時呼叫），不改 state
    func clearContent() {
        defaults?.removeObject(forKey: Key.result)
        defaults?.removeObject(forKey: Key.partial)
        defaults?.removeObject(forKey: Key.selectedText)
    }

    // MARK: Result consumption (keyboard)

    /// 查看尚未插入、且夠新的結果（不標記為已消費）；過期結果順手清掉
    func unconsumedResult(maxAge: TimeInterval = 120) -> BridgeResult? {
        guard let result = latestResult else { return nil }
        guard Date().timeIntervalSince(result.createdAt) < maxAge else {
            defaults?.removeObject(forKey: Key.result)
            return nil
        }
        guard defaults?.string(forKey: Key.consumedResultID) != result.id.uuidString else { return nil }
        return result
    }

    /// 標記結果已插入，並把內容從 App Group 移除
    func markConsumed(_ result: BridgeResult) {
        defaults?.set(result.id.uuidString, forKey: Key.consumedResultID)
        if latestResult?.id == result.id {
            defaults?.removeObject(forKey: Key.result)
            defaults?.removeObject(forKey: Key.partial)
        }
    }

    /// 取出尚未插入、且夠新的結果，並標記為已消費
    func takeUnconsumedResult(maxAge: TimeInterval = 120) -> BridgeResult? {
        guard let result = unconsumedResult(maxAge: maxAge) else { return nil }
        markConsumed(result)
        return result
    }

    // MARK: Commands (keyboard writes, App reads)

    func send(_ command: BridgeCommand, selectedText: String? = nil) {
        defaults?.set(command.rawValue, forKey: Key.command)
        defaults?.set(UUID().uuidString, forKey: Key.commandID)
        defaults?.set(Date().timeIntervalSince1970, forKey: Key.commandAt)
        if command == .start {
            if let selectedText, !selectedText.isEmpty {
                defaults?.set(selectedText, forKey: Key.selectedText)
            } else {
                defaults?.removeObject(forKey: Key.selectedText)
            }
        }
        DarwinNotificationCenter.post(Notify.command)
    }

    /// 主 App 取出最新且未處理過的指令（選取文字讀出後即從 App Group 移除）
    func takeCommand(lastHandledID: inout String?) -> (BridgeCommand, selectedText: String?)? {
        guard let id = defaults?.string(forKey: Key.commandID), id != lastHandledID,
              let raw = defaults?.string(forKey: Key.command),
              let command = BridgeCommand(rawValue: raw) else { return nil }
        lastHandledID = id
        return (command, takeSelectedText())
    }

    /// 驗證 URL 冷 / 熱啟動確實來自鍵盤：最近 `window` 秒內有一筆 start 指令。
    /// 成功時回傳該指令 id 與選取文字，並清掉時間戳與選取文字（同一筆指令只能用一次）。
    func takeRecentStartCommand(within window: TimeInterval = 5) -> (id: String, selectedText: String?)? {
        guard let defaults,
              defaults.string(forKey: Key.command) == BridgeCommand.start.rawValue,
              let id = defaults.string(forKey: Key.commandID),
              let at = defaults.object(forKey: Key.commandAt) as? Double else { return nil }
        let age = Date().timeIntervalSince1970 - at
        // 容許少量時鐘誤差（同一台裝置，理論上不會是負的）
        guard age > -1, age <= window else { return nil }
        defaults.removeObject(forKey: Key.commandAt)
        return (id, takeSelectedText())
    }

    private func takeSelectedText() -> String? {
        let text = defaults?.string(forKey: Key.selectedText).flatMap { $0.isEmpty ? nil : $0 }
        defaults?.removeObject(forKey: Key.selectedText)
        return text
    }

    /// 主 App 啟動時標記既有指令為已處理，避免冷啟動誤觸發舊指令
    func currentCommandID() -> String? {
        defaults?.string(forKey: Key.commandID)
    }
}

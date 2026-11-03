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
        if let partial { defaults?.set(partial, forKey: Key.partial) }
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
        defaults?.set(text, forKey: Key.partial)
        defaults?.set(nil, forKey: Key.errorMessage)
        DarwinNotificationCenter.post(Notify.state)
    }

    // MARK: Result consumption (keyboard)

    /// 取出尚未插入、且夠新的結果（避免鍵盤重新出現時插入舊結果）
    func takeUnconsumedResult(maxAge: TimeInterval = 120) -> BridgeResult? {
        guard let result = latestResult,
              Date().timeIntervalSince(result.createdAt) < maxAge,
              defaults?.string(forKey: Key.consumedResultID) != result.id.uuidString else { return nil }
        defaults?.set(result.id.uuidString, forKey: Key.consumedResultID)
        return result
    }

    // MARK: Commands (keyboard writes, App reads)

    func send(_ command: BridgeCommand, selectedText: String? = nil) {
        defaults?.set(command.rawValue, forKey: Key.command)
        defaults?.set(UUID().uuidString, forKey: Key.commandID)
        if command == .start {
            defaults?.set(selectedText, forKey: Key.selectedText)
        }
        DarwinNotificationCenter.post(Notify.command)
    }

    /// 主 App 取出最新且未處理過的指令
    func takeCommand(lastHandledID: inout String?) -> (BridgeCommand, selectedText: String?)? {
        guard let id = defaults?.string(forKey: Key.commandID), id != lastHandledID,
              let raw = defaults?.string(forKey: Key.command),
              let command = BridgeCommand(rawValue: raw) else { return nil }
        lastHandledID = id
        return (command, defaults?.string(forKey: Key.selectedText))
    }

    /// 鍵盤送出 start 時附帶的選取文字（URL 冷啟動路徑使用）
    var storedSelectedText: String? {
        defaults?.string(forKey: Key.selectedText).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 主 App 啟動時標記既有指令為已處理，避免冷啟動誤觸發舊指令
    func currentCommandID() -> String? {
        defaults?.string(forKey: Key.commandID)
    }
}

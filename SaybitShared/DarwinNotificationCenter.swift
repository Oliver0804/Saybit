//
//  DarwinNotificationCenter.swift
//  SaybitShared
//
//  跨 process 通知（App ⇄ 鍵盤 extension）。Darwin notification 不帶 payload，
//  資料一律透過 App Group UserDefaults 交換。
//

import Foundation

nonisolated final class DarwinNotificationCenter {
    static let shared = DarwinNotificationCenter()

    private var handlers: [String: [UUID: () -> Void]] = [:]
    private let lock = NSLock()

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true
        )
    }

    /// 註冊監聽；回傳的 token 用於 `removeObserver`。handler 一律在 main thread 執行。
    @discardableResult
    func addObserver(_ name: String, handler: @escaping () -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        let isFirst = handlers[name] == nil
        handlers[name, default: [:]][token] = handler
        lock.unlock()

        if isFirst {
            let observer = Unmanaged.passUnretained(self).toOpaque()
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                observer,
                { _, observer, name, _, _ in
                    guard let observer, let name = name?.rawValue as String? else { return }
                    let center = Unmanaged<DarwinNotificationCenter>.fromOpaque(observer).takeUnretainedValue()
                    center.fire(name)
                },
                name as CFString,
                nil,
                .deliverImmediately
            )
        }
        return token
    }

    func removeObserver(_ token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        for (name, var map) in handlers where map[token] != nil {
            map[token] = nil
            if map.isEmpty {
                handlers[name] = nil
                CFNotificationCenterRemoveObserver(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    Unmanaged.passUnretained(self).toOpaque(),
                    CFNotificationName(name as CFString),
                    nil
                )
            } else {
                handlers[name] = map
            }
        }
    }

    private func fire(_ name: String) {
        lock.lock()
        let callbacks = handlers[name].map { Array($0.values) } ?? []
        lock.unlock()
        DispatchQueue.main.async {
            callbacks.forEach { $0() }
        }
    }
}

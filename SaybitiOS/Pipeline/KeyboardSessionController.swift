//
//  KeyboardSessionController.swift
//  SaybitiOS
//
//  「鍵盤待命」session：在指定時間內讓 App 於背景保持 audio engine 運行
//  （UIBackgroundModes=audio），鍵盤按下麥克風時不必再跳回 App 就能直接錄音。
//  期間每秒寫一次心跳到 App Group，讓鍵盤判斷 session 是否還活著。
//

import Foundation
import Observation

@Observable
final class KeyboardSessionController {
    private(set) var isActive = false
    private(set) var expiresAt: Date?
    /// 給 UI 倒數用，每秒更新
    private(set) var now = Date()

    /// 由 pipeline 提供：目前是否正在錄音 / 處理（忙碌時不會過期關閉）
    @ObservationIgnored var isBusy: () -> Bool = { false }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let bridge = KeyboardBridge.shared
    @ObservationIgnored private let log = AppLogger.shared

    var remaining: TimeInterval {
        guard let expiresAt else { return 0 }
        return max(0, expiresAt.timeIntervalSince(now))
    }

    /// 啟動或延長 session
    func activate(minutes: Int) {
        expiresAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
        bridge.sessionExpiresAt = expiresAt
        guard !isActive else { return }

        SharedAudioEngine.shared.start()
        guard SharedAudioEngine.shared.isRunning else {
            log.error("鍵盤 session 啟動失敗：audio engine 無法啟動", category: "KeyboardSession")
            expiresAt = nil
            return
        }
        isActive = true
        bridge.beat()
        bridge.publish(state: .idle, partial: "")
        log.info("鍵盤待命 session 啟動 (\(minutes) 分鐘)", category: "KeyboardSession")

        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 使用後延長（有在用就不要斷）
    func touch(minutes: Int) {
        guard isActive else { return }
        expiresAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
        bridge.sessionExpiresAt = expiresAt
    }

    func deactivate() {
        guard isActive else { return }
        timer?.invalidate()
        timer = nil
        isActive = false
        expiresAt = nil
        bridge.sessionExpiresAt = nil
        bridge.clearHeartbeat()
        if !isBusy() {
            SharedAudioEngine.shared.shutdown()
        }
        log.info("鍵盤待命 session 結束", category: "KeyboardSession")
    }

    private func tick() {
        now = Date()
        // engine 可能因中斷 / 權限被拿走而停止 —— 心跳只在真的能錄音時才寫
        if SharedAudioEngine.shared.isRunning {
            bridge.beat()
        }
        if let expiresAt, now >= expiresAt, !isBusy() {
            deactivate()
        }
    }
}

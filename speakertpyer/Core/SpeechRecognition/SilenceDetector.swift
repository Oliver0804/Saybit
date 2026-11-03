//
//  SilenceDetector.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/29.
//

import Foundation

/// 靜音偵測狀態機 — 偵測語音結束後的靜音，觸發 timeout callback
///
/// 執行緒：`update` 會在 audio render thread（以及 Sherpa 的 VAD 回呼經 main）上呼叫，
/// `start/reset` 與屬性設定在 main。所有狀態都由 `lock` 保護；callback 一律在 main queue 執行，
/// 且只在觸發當下的偵測週期（`epoch`）仍有效時才會呼叫，`reset()` 之後排隊中的觸發會被丟棄。
nonisolated final class SilenceDetector: @unchecked Sendable {
    var onSilenceTimeout: (() -> Void)? {
        get { lock.withLock { _onSilenceTimeout } }
        set { lock.withLock { _onSilenceTimeout = newValue } }
    }
    var silenceTimeoutDuration: TimeInterval {
        get { lock.withLock { _silenceTimeoutDuration } }
        set { lock.withLock { _silenceTimeoutDuration = newValue } }
    }

    private let lock = UnfairLock()
    private var _onSilenceTimeout: (() -> Void)?
    private var _silenceTimeoutDuration: TimeInterval = 2.0

    private let silenceThreshold: Float
    private let speechThreshold: Float
    private let noSpeechTimeout: TimeInterval
    // 用 DispatchTime（mach_absolute_time）取代 Date()，避免在 audio render thread 上呼叫 gettimeofday syscall
    private var silenceStartNanos: UInt64?
    private var recordingStartNanos: UInt64?
    private var silenceTimeoutFired = false
    private var hasDetectedSpeech = false
    /// 每次 start/reset 遞增；排隊中的觸發比對不符就丟棄
    private var epoch: UInt64 = 0

    private func nowNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    init(
        silenceThreshold: Float = 0.08,
        speechThreshold: Float = 0.15,
        noSpeechTimeout: TimeInterval = 3.0
    ) {
        self.silenceThreshold = silenceThreshold
        self.speechThreshold = speechThreshold
        self.noSpeechTimeout = noSpeechTimeout
    }

    /// 開始偵測（重置所有狀態）
    func start() {
        let now = nowNanos()
        lock.withLock {
            epoch &+= 1
            silenceStartNanos = nil
            recordingStartNanos = now
            silenceTimeoutFired = false
            hasDetectedSpeech = false
        }
    }

    /// 停止偵測並清除狀態
    func reset() {
        lock.withLock {
            epoch &+= 1
            silenceStartNanos = nil
            recordingStartNanos = nil
            silenceTimeoutFired = false
            hasDetectedSpeech = false
            _onSilenceTimeout = nil
        }
    }

    /// 每次收到 audio buffer 時更新靜音狀態（可在任何執行緒呼叫）
    /// - Parameter rawLevel: 正規化後的音量等級 (0~1，未套用 gain)
    func update(rawLevel: Float) {
        let now = nowNanos()
        lock.lock()
        var fireEpoch: UInt64?
        if rawLevel >= speechThreshold {
            hasDetectedSpeech = true
            silenceStartNanos = nil
            silenceTimeoutFired = false
        } else if recordingStartNanos != nil, rawLevel < silenceThreshold {
            if hasDetectedSpeech {
                if silenceStartNanos == nil {
                    silenceStartNanos = now
                }
                if let start = silenceStartNanos,
                   Self.elapsedSeconds(from: start, to: now) >= _silenceTimeoutDuration,
                   !silenceTimeoutFired {
                    silenceTimeoutFired = true
                    fireEpoch = epoch
                }
            } else if let recStart = recordingStartNanos,
                      Self.elapsedSeconds(from: recStart, to: now) >= noSpeechTimeout,
                      !silenceTimeoutFired {
                silenceTimeoutFired = true
                fireEpoch = epoch
            }
        }
        lock.unlock()

        if let fireEpoch {
            DispatchQueue.main.async { [weak self] in
                self?.fire(epoch: fireEpoch)
            }
        }
    }

    private func fire(epoch expected: UInt64) {
        let callback: (() -> Void)? = lock.withLock {
            epoch == expected ? _onSilenceTimeout : nil
        }
        callback?()
    }

    private static func elapsedSeconds(from startNanos: UInt64, to now: UInt64) -> TimeInterval {
        guard now > startNanos else { return 0 }
        return TimeInterval(now - startNanos) / 1_000_000_000
    }
}

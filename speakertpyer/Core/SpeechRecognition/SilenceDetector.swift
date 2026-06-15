//
//  SilenceDetector.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/29.
//

import Foundation

/// 靜音偵測狀態機 — 偵測語音結束後的靜音，觸發 timeout callback
class SilenceDetector {
    var onSilenceTimeout: (() -> Void)?
    var silenceTimeoutDuration: TimeInterval = 2.0

    private let silenceThreshold: Float
    private let speechThreshold: Float
    private let noSpeechTimeout: TimeInterval
    // 用 DispatchTime（mach_absolute_time）取代 Date()，避免在 audio render thread 上呼叫 gettimeofday syscall
    private var silenceStartNanos: UInt64?
    private var recordingStartNanos: UInt64?
    private var silenceTimeoutFired = false
    private var hasDetectedSpeech = false

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
        silenceStartNanos = nil
        recordingStartNanos = nowNanos()
        silenceTimeoutFired = false
        hasDetectedSpeech = false
    }

    /// 停止偵測並清除狀態
    func reset() {
        silenceStartNanos = nil
        recordingStartNanos = nil
        silenceTimeoutFired = false
        onSilenceTimeout = nil
    }

    /// 每次收到 audio buffer 時更新靜音狀態
    /// - Parameter rawLevel: 正規化後的音量等級 (0~1，未套用 gain)
    func update(rawLevel: Float) {
        if rawLevel >= speechThreshold {
            hasDetectedSpeech = true
            silenceStartNanos = nil
            silenceTimeoutFired = false
        } else if hasDetectedSpeech, rawLevel < silenceThreshold {
            if silenceStartNanos == nil {
                silenceStartNanos = nowNanos()
            }
            if let start = silenceStartNanos,
               elapsedSeconds(since: start) >= silenceTimeoutDuration,
               !silenceTimeoutFired {
                silenceTimeoutFired = true
                DispatchQueue.main.async { [weak self] in
                    self?.onSilenceTimeout?()
                }
            }
        } else if !hasDetectedSpeech, rawLevel < silenceThreshold {
            if let recStart = recordingStartNanos,
               elapsedSeconds(since: recStart) >= noSpeechTimeout,
               !silenceTimeoutFired {
                silenceTimeoutFired = true
                DispatchQueue.main.async { [weak self] in
                    self?.onSilenceTimeout?()
                }
            }
        }
    }

    private func elapsedSeconds(since startNanos: UInt64) -> TimeInterval {
        let now = nowNanos()
        guard now > startNanos else { return 0 }
        return TimeInterval(now - startNanos) / 1_000_000_000
    }
}

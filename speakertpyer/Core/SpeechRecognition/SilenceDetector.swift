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
    private var silenceStartTime: Date?
    private var recordingStartTime: Date?
    private var silenceTimeoutFired = false
    private var hasDetectedSpeech = false

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
        silenceStartTime = nil
        recordingStartTime = Date()
        silenceTimeoutFired = false
        hasDetectedSpeech = false
    }

    /// 停止偵測並清除狀態
    func reset() {
        silenceStartTime = nil
        recordingStartTime = nil
        silenceTimeoutFired = false
        onSilenceTimeout = nil
    }

    /// 每次收到 audio buffer 時更新靜音狀態
    /// - Parameter rawLevel: 正規化後的音量等級 (0~1，未套用 gain)
    func update(rawLevel: Float) {
        if rawLevel >= speechThreshold {
            hasDetectedSpeech = true
            silenceStartTime = nil
            silenceTimeoutFired = false
        } else if hasDetectedSpeech, rawLevel < silenceThreshold {
            if silenceStartTime == nil {
                silenceStartTime = Date()
            }
            if let start = silenceStartTime,
               Date().timeIntervalSince(start) >= silenceTimeoutDuration,
               !silenceTimeoutFired {
                silenceTimeoutFired = true
                DispatchQueue.main.async { [weak self] in
                    self?.onSilenceTimeout?()
                }
            }
        } else if !hasDetectedSpeech, rawLevel < silenceThreshold {
            if let recStart = recordingStartTime,
               Date().timeIntervalSince(recStart) >= noSpeechTimeout,
               !silenceTimeoutFired {
                silenceTimeoutFired = true
                DispatchQueue.main.async { [weak self] in
                    self?.onSilenceTimeout?()
                }
            }
        }
    }
}

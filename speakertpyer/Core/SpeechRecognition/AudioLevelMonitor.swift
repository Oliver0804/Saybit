//
//  AudioLevelMonitor.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/28.
//

import AVFoundation
import Foundation

/// 輕量麥克風監聽器 — 只偵測是否有人說話，不做語音辨識
class AudioLevelMonitor: AudioBufferConsumer {
    let consumerID: String
    var onSpeechDetected: (() -> Void)?
    var onAudioLevel: ((Float) -> Void)?

    private let speechThreshold: Float = 0.15
    private(set) var isMonitoring = false
    private var graceUntil: Date = .distantPast
    private var tapCallbackCount = 0
    private var maxLevelSeen: Float = 0
    private var speechDetected = false
    private let log = AppLogger.shared
    private let levelThrottler = MainThreadThrottler(intervalMs: 50)

    init(id: String = UUID().uuidString) {
        self.consumerID = "AudioLevelMonitor-\(id)"
    }

    func startMonitoring(gracePeriod: TimeInterval = 0) {
        guard !isMonitoring else { return }

        if gracePeriod > 0 {
            graceUntil = Date().addingTimeInterval(gracePeriod)
        }
        tapCallbackCount = 0
        maxLevelSeen = 0
        speechDetected = false
        isMonitoring = true
        levelThrottler.reset()

        SharedAudioEngine.shared.addConsumer(self)
        log.info("AudioLevelMonitor 開始監聽", category: "SmartSend")
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        SharedAudioEngine.shared.removeConsumer(self)
        log.info("AudioLevelMonitor 已停止 (callbacks=\(tapCallbackCount), maxLevel=\(String(format: "%.4f", maxLevelSeen)), threshold=\(speechThreshold))", category: "SmartSend")
        onSpeechDetected = nil
        onAudioLevel = nil
    }

    // MARK: - AudioBufferConsumer

    func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard isMonitoring else { return }

        tapCallbackCount += 1

        guard Date() >= graceUntil else { return }
        guard let rms = AudioUtils.rms(from: buffer) else { return }
        let level = AudioUtils.normalizedLevel(rms: rms)

        if level > maxLevelSeen {
            maxLevelSeen = level
        }

        // Audio tap 在 render thread；節流到 ~20Hz 派發到 main
        if let onLevel = onAudioLevel {
            levelThrottler.dispatch {
                onLevel(level)
            }
        }

        // 語音偵測是 one-shot 事件：用旗標確保只觸發一次，避免連續高音量 buffer 重複派發
        if level >= speechThreshold, !speechDetected {
            speechDetected = true
            DispatchQueue.main.async { [weak self] in
                self?.log.info("語音偵測觸發 (level=\(String(format: "%.3f", level)))", category: "SmartSend")
                self?.onSpeechDetected?()
            }
        }
    }
}

//
//  AudioLevelMonitor.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/28.
//

import AVFoundation
import Foundation

/// 輕量麥克風監聽器 — 只偵測是否有人說話，不做語音辨識
///
/// `handleAudioBuffer` 在 audio render thread；start/stop 在 main。
/// render thread 讀到的旗標 / callback 都經 `stateLock` 取快照，避免與 stopMonitoring 清除 callback 競爭。
class AudioLevelMonitor: AudioBufferConsumer {
    let consumerID: String
    var onSpeechDetected: (() -> Void)? {
        get { stateLock.withLock { _onSpeechDetected } }
        set { stateLock.withLock { _onSpeechDetected = newValue } }
    }
    var onAudioLevel: ((Float) -> Void)? {
        get { stateLock.withLock { _onAudioLevel } }
        set { stateLock.withLock { _onAudioLevel = newValue } }
    }

    private let speechThreshold: Float = 0.15
    private(set) var isMonitoring = false
    private let stateLock = UnfairLock()
    private var _onSpeechDetected: (() -> Void)?
    private var _onAudioLevel: ((Float) -> Void)?
    // 以下由 stateLock 保護
    private var renderMonitoring = false
    /// grace period 結束時間（mach absolute ticks）；render thread 不呼叫 Date()
    private var graceUntilAbs: UInt64 = 0
    private var tapCallbackCount = 0
    private var maxLevelSeen: Float = 0
    private var speechDetected = false
    private let log = AppLogger.shared
    private let levelThrottler = MainThreadThrottler(intervalMs: 50)

    init(id: String = UUID().uuidString) {
        self.consumerID = "AudioLevelMonitor-\(id)"
    }

    private static func machTicks(seconds: TimeInterval) -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ns = UInt64(max(0, seconds) * 1_000_000_000)
        return ns * UInt64(info.denom) / UInt64(info.numer)
    }

    func startMonitoring(gracePeriod: TimeInterval = 0) {
        guard !isMonitoring else { return }

        let graceUntil = gracePeriod > 0 ? mach_absolute_time() + Self.machTicks(seconds: gracePeriod) : 0
        stateLock.withLock {
            graceUntilAbs = graceUntil
            tapCallbackCount = 0
            maxLevelSeen = 0
            speechDetected = false
            renderMonitoring = true
        }
        isMonitoring = true
        levelThrottler.reset()

        SharedAudioEngine.shared.addConsumer(self)
        log.info("AudioLevelMonitor 開始監聽", category: "SmartSend")
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        SharedAudioEngine.shared.removeConsumer(self)
        let (count, maxLevel): (Int, Float) = stateLock.withLock {
            renderMonitoring = false
            _onSpeechDetected = nil
            _onAudioLevel = nil
            return (tapCallbackCount, maxLevelSeen)
        }
        log.info("AudioLevelMonitor 已停止 (callbacks=\(count), maxLevel=\(String(format: "%.4f", maxLevel)), threshold=\(speechThreshold))", category: "SmartSend")
    }

    // MARK: - AudioBufferConsumer

    func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let now = mach_absolute_time()
        stateLock.lock()
        guard renderMonitoring else {
            stateLock.unlock()
            return
        }
        tapCallbackCount += 1
        let inGrace = now < graceUntilAbs
        stateLock.unlock()

        guard !inGrace else { return }
        guard let rms = AudioUtils.rms(from: buffer) else { return }
        let level = AudioUtils.normalizedLevel(rms: rms)

        stateLock.lock()
        if level > maxLevelSeen {
            maxLevelSeen = level
        }
        let onLevel = _onAudioLevel
        // 語音偵測是 one-shot 事件：用旗標確保只觸發一次，避免連續高音量 buffer 重複派發
        let fireSpeech = level >= speechThreshold && !speechDetected
        if fireSpeech { speechDetected = true }
        stateLock.unlock()

        // Audio tap 在 render thread；節流到 ~20Hz 派發到 main
        if let onLevel {
            levelThrottler.dispatch {
                onLevel(level)
            }
        }

        if fireSpeech {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isMonitoring else { return }
                self.log.info("語音偵測觸發 (level=\(String(format: "%.3f", level)))", category: "SmartSend")
                self.onSpeechDetected?()
            }
        }
    }
}

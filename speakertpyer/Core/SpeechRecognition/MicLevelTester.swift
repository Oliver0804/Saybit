//
//  MicLevelTester.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/28.
//

import AVFoundation
import Combine

/// 設定頁面用的麥克風音量即時測試器
class MicLevelTester: ObservableObject, AudioBufferConsumer {
    let consumerID = "MicLevelTester"
    @Published var level: Float = 0

    private var isRunning = false
    /// render thread 讀取的收音旗標（isRunning 只在 main 使用）
    private let renderLock = UnfairLock()
    private var renderRunning = false
    /// render thread 每 ~21ms 一個 buffer；節流到 ~20Hz 再回 main，避免塞滿 main queue
    private let levelThrottler = MainThreadThrottler(intervalMs: 50)

    func start() {
        guard !isRunning else { return }
        isRunning = true
        renderLock.withLock { renderRunning = true }
        levelThrottler.reset()
        SharedAudioEngine.shared.addConsumer(self)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        renderLock.withLock { renderRunning = false }
        SharedAudioEngine.shared.removeConsumer(self)
        DispatchQueue.main.async { [weak self] in
            self?.level = 0
        }
    }

    deinit {
        if isRunning {
            SharedAudioEngine.shared.removeConsumer(self)
        }
    }

    // MARK: - AudioBufferConsumer

    func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard renderLock.withLock({ renderRunning }) else { return }
        guard let rms = AudioUtils.rms(from: buffer) else { return }
        let displayLevel = AudioUtils.normalizedLevel(rms: rms, multiplier: 8.0)

        levelThrottler.dispatch { [weak self] in
            guard let self, self.isRunning else { return }
            self.level = displayLevel
        }
    }
}

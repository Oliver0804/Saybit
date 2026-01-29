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

    func start() {
        guard !isRunning else { return }
        isRunning = true
        SharedAudioEngine.shared.addConsumer(self)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
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
        guard isRunning else { return }
        guard let rms = AudioUtils.rms(from: buffer) else { return }
        let displayLevel = AudioUtils.normalizedLevel(rms: rms, multiplier: 8.0)

        DispatchQueue.main.async { [weak self] in
            self?.level = displayLevel
        }
    }
}

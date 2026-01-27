//
//  AudioLevelMonitor.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/28.
//

import AudioToolbox
import AVFoundation
import Foundation

/// 輕量麥克風監聽器 — 只偵測是否有人說話，不做語音辨識
class AudioLevelMonitor {
    var onSpeechDetected: (() -> Void)?

    private let audioEngine = AVAudioEngine()
    private let speechThreshold: Float = 0.15
    private var isMonitoring = false
    private let log = AppLogger.shared

    func startMonitoring(inputDeviceUID: String = "") {
        guard !isMonitoring else { return }

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)

        // 設定指定輸入裝置
        if !inputDeviceUID.isEmpty,
           let deviceID = AudioSessionManager.deviceID(forUID: inputDeviceUID),
           let audioUnit = inputNode.audioUnit {
            var devID = deviceID
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        let tapFormat = recordingFormat.channelCount > 0 ? recordingFormat : nil

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) {
            [weak self] buffer, _ in
            guard let self, self.isMonitoring else { return }
            guard let channelData = buffer.floatChannelData?[0] else { return }

            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }

            var sum: Float = 0
            for i in 0..<frameLength {
                sum += channelData[i] * channelData[i]
            }
            let rms = sqrtf(sum / Float(frameLength))
            let level = max(0, min(1, rms * 5))

            if level >= self.speechThreshold {
                DispatchQueue.main.async {
                    self.onSpeechDetected?()
                }
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isMonitoring = true
            log.info("AudioLevelMonitor 開始監聽", category: "SmartSend")
        } catch {
            log.error("AudioLevelMonitor 啟動失敗: \(error.localizedDescription)", category: "SmartSend")
        }
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isMonitoring = false
        onSpeechDetected = nil
        log.info("AudioLevelMonitor 已停止", category: "SmartSend")
    }
}

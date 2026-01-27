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
    private var graceUntil: Date = .distantPast
    private var tapCallbackCount = 0
    private var maxLevelSeen: Float = 0
    private let log = AppLogger.shared

    func startMonitoring(inputDeviceUID: String = "", gracePeriod: TimeInterval = 0) {
        guard !isMonitoring else { return }

        if gracePeriod > 0 {
            graceUntil = Date().addingTimeInterval(gracePeriod)
        }
        tapCallbackCount = 0
        maxLevelSeen = 0

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)

        // Prepare engine first so audio unit is fully initialized
        audioEngine.prepare()

        // 設定指定輸入裝置 (after prepare to ensure audioUnit exists)
        if !inputDeviceUID.isEmpty,
           let deviceID = AudioSessionManager.deviceID(forUID: inputDeviceUID),
           let audioUnit = inputNode.audioUnit {
            var devID = deviceID
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                log.error("AudioLevelMonitor 設定輸入裝置失敗 (status=\(status))", category: "SmartSend")
            }
        }

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        let tapFormat = recordingFormat.channelCount > 0 ? recordingFormat : nil
        log.info("AudioLevelMonitor format: \(recordingFormat.sampleRate)Hz, \(recordingFormat.channelCount)ch", category: "SmartSend")

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) {
            [weak self] buffer, _ in
            guard let self, self.isMonitoring else { return }

            self.tapCallbackCount += 1

            // Skip detection during grace period (avoids sound feedback triggering cancel)
            guard Date() >= self.graceUntil else { return }
            guard let channelData = buffer.floatChannelData?[0] else { return }

            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }

            var sum: Float = 0
            for i in 0..<frameLength {
                sum += channelData[i] * channelData[i]
            }
            let rms = sqrtf(sum / Float(frameLength))
            let level = max(0, min(1, rms * 5))

            if level > self.maxLevelSeen {
                self.maxLevelSeen = level
            }

            if level >= self.speechThreshold {
                DispatchQueue.main.async {
                    self.log.info("語音偵測觸發 (level=\(String(format: "%.3f", level)))", category: "SmartSend")
                    self.onSpeechDetected?()
                }
            }
        }

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
        log.info("AudioLevelMonitor 已停止 (callbacks=\(tapCallbackCount), maxLevel=\(String(format: "%.4f", maxLevelSeen)), threshold=\(speechThreshold))", category: "SmartSend")
        onSpeechDetected = nil
    }
}

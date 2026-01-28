//
//  MicLevelTester.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/28.
//

import AudioToolbox
import AVFoundation
import Combine

/// 設定頁面用的麥克風音量即時測試器
class MicLevelTester: ObservableObject {
    @Published var level: Float = 0

    private let audioEngine = AVAudioEngine()
    private var isRunning = false

    func start(inputDeviceUID: String = "") {
        guard !isRunning else { return }

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)

        audioEngine.prepare()

        if !inputDeviceUID.isEmpty,
           let deviceID = AudioSessionManager.deviceID(forUID: inputDeviceUID),
           let audioUnit = inputNode.audioUnit
        {
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

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }

            var sum: Float = 0
            for i in 0..<frameLength {
                sum += channelData[i] * channelData[i]
            }
            let rms = sqrtf(sum / Float(frameLength))
            let displayLevel = max(0, min(1, rms * 8))

            DispatchQueue.main.async {
                self?.level = displayLevel
            }
        }

        do {
            try audioEngine.start()
            isRunning = true
        } catch {
            // Failed to start
        }
    }

    func stop() {
        guard isRunning else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRunning = false
        DispatchQueue.main.async { [weak self] in
            self?.level = 0
        }
    }

    deinit {
        // Don't call stop() here — it has async code that references self
        // Just clean up the audio engine directly
        if isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
    }
}

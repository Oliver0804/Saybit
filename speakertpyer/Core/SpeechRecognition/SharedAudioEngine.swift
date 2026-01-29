//
//  SharedAudioEngine.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/29.
//

import AudioToolbox
import AVFoundation
import Foundation

/// 音訊 buffer 消費者協定
protocol AudioBufferConsumer: AnyObject {
    var consumerID: String { get }
    func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime)
}

/// 全域單一 Audio Engine，持續收音，分發 buffer 給已註冊的消費者
class SharedAudioEngine {
    static let shared = SharedAudioEngine()

    private let audioEngine = AVAudioEngine()
    private let log = AppLogger.shared

    private var consumers: [AudioBufferConsumer] = []
    private let consumersLock = NSLock()

    private(set) var currentInputDeviceUID: String = ""
    private(set) var isRunning = false
    private(set) var inputFormat: AVAudioFormat?

    private init() {}

    // MARK: - Lifecycle

    func start(inputDeviceUID: String = "") {
        guard !isRunning else { return }

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)

        audioEngine.prepare()

        configureInputDevice(uid: inputDeviceUID)

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        let tapFormat = recordingFormat.channelCount > 0 ? recordingFormat : nil
        inputFormat = tapFormat ?? recordingFormat

        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            log.error("SharedAudioEngine 無效音訊格式，放棄啟動", category: "Audio")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, time in
            guard let self else { return }
            self.consumersLock.lock()
            let snapshot = self.consumers
            self.consumersLock.unlock()

            for consumer in snapshot {
                consumer.handleAudioBuffer(buffer, time: time)
            }
        }

        do {
            try audioEngine.start()
            isRunning = true
            currentInputDeviceUID = inputDeviceUID
            log.info("SharedAudioEngine 啟動 (\(recordingFormat.sampleRate)Hz, \(recordingFormat.channelCount)ch)", category: "Audio")
        } catch {
            log.error("SharedAudioEngine 啟動失敗: \(error.localizedDescription)", category: "Audio")
        }
    }

    func stop() {
        guard isRunning else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRunning = false
        log.info("SharedAudioEngine 已停止", category: "Audio")
    }

    // MARK: - Input Device

    func switchInputDevice(uid: String) {
        guard uid != currentInputDeviceUID else { return }
        configureInputDevice(uid: uid)
        currentInputDeviceUID = uid
        log.info("SharedAudioEngine 切換輸入裝置: \(uid.isEmpty ? "系統預設" : uid)", category: "Audio")
    }

    private func configureInputDevice(uid: String) {
        guard !uid.isEmpty,
              let deviceID = AudioSessionManager.deviceID(forUID: uid),
              let audioUnit = audioEngine.inputNode.audioUnit else { return }

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
            log.error("SharedAudioEngine 設定輸入裝置失敗 (status=\(status))", category: "Audio")
        }
    }

    // MARK: - Consumer Management

    func addConsumer(_ consumer: AudioBufferConsumer) {
        consumersLock.lock()
        defer { consumersLock.unlock() }
        guard !consumers.contains(where: { $0.consumerID == consumer.consumerID }) else { return }
        consumers.append(consumer)
        log.info("Audio consumer 加入: \(consumer.consumerID) (total=\(consumers.count))", category: "Audio")
    }

    func removeConsumer(_ consumer: AudioBufferConsumer) {
        consumersLock.lock()
        defer { consumersLock.unlock() }
        consumers.removeAll(where: { $0.consumerID == consumer.consumerID })
        log.info("Audio consumer 移除: \(consumer.consumerID) (total=\(consumers.count))", category: "Audio")
    }
}

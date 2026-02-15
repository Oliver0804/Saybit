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

    // MARK: - Pre-buffer（環形緩衝區）
    // 保留最近 ~3 秒的音訊，讓新消費者加入時可回放，避免開頭語音遺失
    // 需要足夠長以涵蓋：AudioLevelMonitor 偵測延遲 + startRecording() 前置作業 + STT 引擎初始化時間
    private var preBuffer: [(buffer: AVAudioPCMBuffer, time: AVAudioTime)] = []
    private let preBufferLock = NSLock()
    private let preBufferDuration: TimeInterval = 2.0

    private init() {}

    // MARK: - Lifecycle

    func start(inputDeviceUID: String = "") {
        guard !isRunning else { return }

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)

        // Phase 1: prepare 讓 audioUnit 可用，再設定裝置
        audioEngine.prepare()
        configureInputDevice(uid: inputDeviceUID)

        // Phase 2: 裝置變更後 reset + re-prepare 讓 engine 重新取得正確格式
        if !inputDeviceUID.isEmpty {
            audioEngine.reset()
            audioEngine.prepare()
            configureInputDevice(uid: inputDeviceUID)
        }

        let recordingFormat = inputNode.outputFormat(forBus: 0)

        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            log.error("SharedAudioEngine 無效音訊格式，放棄啟動", category: "Audio")
            return
        }

        // 用 nil format 讓系統自動匹配裝置原生格式，避免格式不匹配
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, time in
            guard let self else { return }

            // 寫入 pre-buffer
            self.appendToPreBuffer(buffer, time: time)

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
            // 啟動後讀取實際格式（供 WhisperSTTClient WAV 轉換用）
            inputFormat = inputNode.outputFormat(forBus: 0)
            log.info("SharedAudioEngine 啟動 (\(inputFormat?.sampleRate ?? 0)Hz, \(inputFormat?.channelCount ?? 0)ch)", category: "Audio")
        } catch {
            log.error("SharedAudioEngine 啟動失敗: \(error.localizedDescription)", category: "Audio")
        }
    }

    func stop() {
        guard isRunning else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRunning = false
        clearPreBuffer()
        log.info("SharedAudioEngine 已停止", category: "Audio")
    }

    // MARK: - Pre-buffer Management

    private func appendToPreBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
        preBufferLock.lock()
        preBuffer.append((buffer: copy, time: time))
        trimPreBuffer()
        preBufferLock.unlock()
    }

    /// 移除超過 preBufferDuration 的舊 buffer
    private func trimPreBuffer() {
        guard let format = inputFormat, format.sampleRate > 0 else { return }
        let maxFrames = AVAudioFrameCount(preBufferDuration * format.sampleRate)
        var totalFrames: AVAudioFrameCount = 0
        // 從尾端累計，保留最近 maxFrames
        var keepFrom = 0
        for i in stride(from: preBuffer.count - 1, through: 0, by: -1) {
            totalFrames += preBuffer[i].buffer.frameLength
            if totalFrames >= maxFrames {
                keepFrom = i
                break
            }
        }
        if keepFrom > 0 {
            preBuffer.removeFirst(keepFrom)
        }
    }

    private func clearPreBuffer() {
        preBufferLock.lock()
        preBuffer.removeAll()
        preBufferLock.unlock()
    }

    // MARK: - Input Device

    func switchInputDevice(uid: String) {
        guard uid != currentInputDeviceUID else { return }
        log.info("SharedAudioEngine 切換輸入裝置: \(uid.isEmpty ? "系統預設" : uid)", category: "Audio")
        // 熱切換 AudioUnitSetProperty 後 tap 會失效，必須完整重啟
        stop()
        start(inputDeviceUID: uid)
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

    /// 加入消費者。`replayPreBuffer` 為 true 時會先回放最近 ~1.5 秒的音訊，避免開頭遺失。
    func addConsumer(_ consumer: AudioBufferConsumer, replayPreBuffer: Bool = false) {
        consumersLock.lock()
        guard !consumers.contains(where: { $0.consumerID == consumer.consumerID }) else {
            consumersLock.unlock()
            return
        }
        consumers.append(consumer)
        consumersLock.unlock()

        if replayPreBuffer {
            preBufferLock.lock()
            let snapshot = preBuffer
            preBufferLock.unlock()
            for entry in snapshot {
                consumer.handleAudioBuffer(entry.buffer, time: entry.time)
            }
            log.info("Audio consumer 加入: \(consumer.consumerID) (replay \(snapshot.count) buffers)", category: "Audio")
        } else {
            log.info("Audio consumer 加入: \(consumer.consumerID)", category: "Audio")
        }
    }

    func removeConsumer(_ consumer: AudioBufferConsumer) {
        consumersLock.lock()
        defer { consumersLock.unlock() }
        consumers.removeAll(where: { $0.consumerID == consumer.consumerID })
        log.info("Audio consumer 移除: \(consumer.consumerID) (total=\(consumers.count))", category: "Audio")
    }
}

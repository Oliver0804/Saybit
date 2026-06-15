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
    // os_unfair_lock 支援優先級捐贈，避免 render thread 因 main thread 持鎖被降級（NSLock 無此保證）
    private let consumersLock = os_unfair_lock_t.allocate(capacity: 1)

    private(set) var currentInputDeviceUID: String = ""
    private(set) var isRunning = false
    private(set) var inputFormat: AVAudioFormat?

    /// 人聲帶通濾波器（80Hz – 8kHz）— 在 tap 內 in-place 處理 buffer
    /// 對所有 consumer 與 pre-buffer 一致生效
    private let voiceFilter = VoiceBandpassFilter()

    /// 切換降噪開關（thread-safe — 內部 Bool 在 macOS 上 atomic）
    func setVoiceBandpassEnabled(_ enabled: Bool) {
        voiceFilter.isEnabled = enabled
        log.info("VoiceBandpass \(enabled ? "啟用" : "停用")", category: "Audio")
    }

    /// 期望的 Voice Processing（AEC 回音消除 + 降噪）狀態
    /// 在 start() 內套用於 inputNode；執行中切換需重啟 engine 才能生效
    private var echoCancellationEnabled = false

    /// 切換 Apple 原生 Voice Processing IO（聲學回音消除 / AEC）
    /// 會把「喇叭播放洩漏進麥克風的聲音」用系統播放當參考訊號即時消除
    /// 因屬於 audio unit 層級設定，執行中切換需完整重啟 engine
    func setEchoCancellationEnabled(_ enabled: Bool) {
        guard enabled != echoCancellationEnabled else { return }
        echoCancellationEnabled = enabled
        log.info("EchoCancellation \(enabled ? "啟用" : "停用")", category: "Audio")
        if isRunning {
            let uid = currentInputDeviceUID
            stop()
            start(inputDeviceUID: uid)
        }
    }

    // MARK: - Pre-buffer（環形緩衝區）
    // 保留最近數秒的音訊，讓新消費者加入時可回放，避免開頭語音遺失
    // 需要足夠長以涵蓋：AudioLevelMonitor 偵測延遲 + startRecording() 前置作業 + STT 引擎初始化時間
    private let preBufferRing = PreBufferRing()

    private init() {}

    deinit {
        consumersLock.deinitialize(count: 1)
        consumersLock.deallocate()
    }

    // MARK: - Lifecycle

    func start(inputDeviceUID: String = "") {
        guard !isRunning else { return }

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)

        // Phase 0: 套用 Voice Processing IO（AEC 回音消除）
        // 必須在 audio unit 被 prepare/初始化「之前」呼叫，否則拋 -10849 (kAudioUnitErr_Initialized)
        // 啟用後 inputNode 會切換為 VPIO audio unit，輸出格式可能改變（通常 1ch），故隨後再讀格式
        applyVoiceProcessing(on: inputNode)

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

        // 初始化人聲帶通濾波器（依目前裝置取樣率與通道數配置 biquad 係數）
        voiceFilter.prepare(
            sampleRate: Float(recordingFormat.sampleRate),
            channelCount: Int(recordingFormat.channelCount)
        )

        // 依實際格式預配置 pre-buffer ring，讓 tap callback 只做 memcpy
        preBufferRing.prepare(format: recordingFormat)

        // 用 nil format 讓系統自動匹配裝置原生格式，避免格式不匹配
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, time in
            guard let self else { return }

            // 先做帶通濾波（in-place），下游 consumer 與 pre-buffer 拿到的都是降噪後音訊
            self.voiceFilter.process(buffer)

            // 寫入 pre-buffer（純 memcpy，無 heap 配置）
            self.preBufferRing.write(buffer, time: time)

            // 讀取 consumer 快照（os_unfair_lock 支援優先級捐贈）
            os_unfair_lock_lock(self.consumersLock)
            let snapshot = self.consumers
            os_unfair_lock_unlock(self.consumersLock)

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
            // 安全退路：若啟動失敗且 AEC 為開，極可能是 VPIO 問題 —— 自動關閉後重試，確保麥克風不會變啞
            if echoCancellationEnabled {
                log.error("疑似 VoiceProcessingIO 導致啟動失敗，自動關閉 AEC 後重試", category: "Audio")
                echoCancellationEnabled = false
                audioEngine.inputNode.removeTap(onBus: 0)
                audioEngine.reset()
                start(inputDeviceUID: inputDeviceUID)
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRunning = false
        preBufferRing.clear()
        log.info("SharedAudioEngine 已停止", category: "Audio")
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

    /// 套用 Voice Processing IO 狀態到 inputNode（AEC + 系統降噪）
    /// 必須在 engine 停止、tap 安裝前呼叫，否則 setVoiceProcessingEnabled 會拋錯
    private func applyVoiceProcessing(on inputNode: AVAudioInputNode) {
        guard inputNode.isVoiceProcessingEnabled != echoCancellationEnabled else { return }
        do {
            try inputNode.setVoiceProcessingEnabled(echoCancellationEnabled)
            if echoCancellationEnabled {
                // 關閉 VPIO 內建 AGC，避免自動增益干擾 AudioLevelMonitor 與帶通濾波的位準判斷
                inputNode.isVoiceProcessingAGCEnabled = false
            }
            log.info("VoiceProcessingIO 設為 \(echoCancellationEnabled)", category: "Audio")
        } catch {
            log.error("VoiceProcessingIO 設定失敗: \(error.localizedDescription)", category: "Audio")
        }
    }

    // MARK: - Consumer Management

    /// 加入消費者。`replayPreBuffer` 為 true 時會先回放最近 ~1.5 秒的音訊，避免開頭遺失。
    func addConsumer(_ consumer: AudioBufferConsumer, replayPreBuffer: Bool = false) {
        os_unfair_lock_lock(consumersLock)
        guard !consumers.contains(where: { $0.consumerID == consumer.consumerID }) else {
            os_unfair_lock_unlock(consumersLock)
            return
        }
        consumers.append(consumer)
        os_unfair_lock_unlock(consumersLock)

        if replayPreBuffer {
            let snapshot = preBufferRing.snapshot()
            for entry in snapshot {
                consumer.handleAudioBuffer(entry.buffer, time: entry.time)
            }
            log.info("Audio consumer 加入: \(consumer.consumerID) (replay \(snapshot.count) buffers)", category: "Audio")
        } else {
            log.info("Audio consumer 加入: \(consumer.consumerID)", category: "Audio")
        }
    }

    func removeConsumer(_ consumer: AudioBufferConsumer) {
        os_unfair_lock_lock(consumersLock)
        defer { os_unfair_lock_unlock(consumersLock) }
        consumers.removeAll(where: { $0.consumerID == consumer.consumerID })
        log.info("Audio consumer 移除: \(consumer.consumerID) (total=\(consumers.count))", category: "Audio")
    }
}

//
//  SharedAudioEngine.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/29.
//

import AudioToolbox
import AVFoundation
import Foundation

/// `os_unfair_lock` 包裝（堆積配置 + 正確 initialize）。
/// os_unfair_lock 不能放在 Swift 的 stored property 直接取址使用（值可能被搬動），
/// 也不能只 allocate 不 initialize（殘值會讓 render thread 永久等待或 crash）。
/// 支援優先級捐贈，可在 audio render thread 上短暫持有。
nonisolated final class UnfairLock: @unchecked Sendable {
    private let raw: os_unfair_lock_t

    init() {
        raw = os_unfair_lock_t.allocate(capacity: 1)
        raw.initialize(to: os_unfair_lock())
    }

    deinit {
        raw.deinitialize(count: 1)
        raw.deallocate()
    }

    func lock() { os_unfair_lock_lock(raw) }
    func unlock() { os_unfair_lock_unlock(raw) }

    @inline(__always)
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(raw)
        defer { os_unfair_lock_unlock(raw) }
        return try body()
    }
}

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
    // os_unfair_lock 支援優先級捐贈，避免 render thread 因 main thread 持鎖被降級（NSLock 無此保證）。
    // 同時保護 pre-buffer 寫入與 consumer 分發的原子性（見 addConsumer 回放邏輯）。
    private let consumersLock = UnfairLock()

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

    private init() {
        #if os(iOS)
        installSessionObservers()
        #endif
    }

    // MARK: - Lifecycle

    func start(inputDeviceUID: String = "") {
        guard !isRunning else { return }

        #if os(iOS)
        // iOS 必須先設定並啟用 AVAudioSession，inputNode 才拿得到有效格式
        guard activateAudioSession() else { return }
        #endif

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

            // 寫入 pre-buffer（純 memcpy，無 heap 配置）與讀取 consumer 快照必須在同一把鎖內：
            // addConsumer 靠這個保證「ring 裡的每個 buffer 不是已回放、就是之後會即時送達」，不重複不遺漏
            self.consumersLock.lock()
            self.preBufferRing.write(buffer, time: time)
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
        #if os(iOS)
        // 釋放麥克風（移除橘點）並讓被我們打斷的音樂恢復播放
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
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
        #if os(macOS)
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
        #endif
    }

    #if os(iOS)
    // MARK: - iOS Audio Session

    /// 期望 engine 持續運行（供中斷結束 / 路由變更後自動恢復）
    private var wantsRunning = false

    /// 音訊 session 被來電 / Siri 等中斷（engine 已停止）時呼叫，於 main thread
    var onInterruptionBegan: (() -> Void)?

    /// playAndRecord + mixWithOthers：錄音時不打斷使用者正在聽的音樂；
    /// allowBluetoothHFP 讓 AirPods 麥克風可用；allowBluetoothA2DP 讓不需麥克風時的
    /// 播放可走 A2DP（同時設定時系統仍優先 HFP，完整解法是待命時不保持 engine 運行）。
    private func activateAudioSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
            )
            try session.setActive(true)
            wantsRunning = true
            return true
        } catch {
            log.error("AVAudioSession 啟用失敗: \(error.localizedDescription)", category: "Audio")
            return false
        }
    }

    /// 由 iOS pipeline 呼叫：完全釋放麥克風，且中斷結束後不自動重啟
    func shutdown() {
        wantsRunning = false
        stop()
    }

    private func installSessionObservers() {
        let nc = NotificationCenter.default
        // 來電 / Siri 等中斷：結束後若仍需要就重啟
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
            MainActor.assumeIsolated {
            guard let self else { return }
            switch type {
            case .began:
                self.log.info("Audio session 被中斷", category: "Audio")
                self.audioEngine.stop()
                self.isRunning = false
                self.onInterruptionBegan?()
            case .ended:
                guard self.wantsRunning else { break }
                if shouldResume {
                    self.log.info("Audio session 中斷結束，重啟 engine", category: "Audio")
                    self.restart()
                } else {
                    // 系統未建議恢復（例如通話 App 仍持有音訊）：保持停止，下次 start() 再啟用
                    self.log.info("Audio session 中斷結束但未要求恢復，engine 保持停止", category: "Audio")
                }
            @unknown default:
                break
            }
            }
        }
        // 耳機插拔 / 藍牙切換會讓 engine 的 I/O 格式改變，tap 失效，必須重建
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.wantsRunning else { return }
                self.log.info("Audio engine 設定變更（路由切換），重啟", category: "Audio")
                self.restart()
            }
        }
    }

    private func restart() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRunning = false
        preBufferRing.clear()
        start(inputDeviceUID: currentInputDeviceUID)
    }
    #endif

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
    ///
    /// 回放在「加入 consumers 之前」完成：先回放 ring 快照，再在鎖內確認 ring 沒有更新的 buffer 才加入；
    /// 若回放期間 render thread 又寫了新的 buffer，就補放那幾個再重試。
    /// 因為 tap 的「寫 ring + 取 consumer 快照」在同一把鎖內，加入當下 ring 裡的 buffer 都已回放、
    /// 之後的 buffer 都走即時分發 → 不交錯、不重複、不遺漏，consumer 也不會被 main 與 render 同時呼叫。
    func addConsumer(_ consumer: AudioBufferConsumer, replayPreBuffer: Bool = false) {
        let alreadyAdded = consumersLock.withLock {
            consumers.contains(where: { $0.consumerID == consumer.consumerID })
        }
        guard !alreadyAdded else { return }

        guard replayPreBuffer else {
            consumersLock.withLock {
                if !consumers.contains(where: { $0.consumerID == consumer.consumerID }) {
                    consumers.append(consumer)
                }
            }
            log.info("Audio consumer 加入: \(consumer.consumerID)", category: "Audio")
            return
        }

        var replayed = 0
        var lastTime: AVAudioTime?
        var pending = preBufferRing.snapshot()
        // 正常 1–2 輪就收斂；上限避免極端情況下（回放比即時還慢）無限追趕
        for attempt in 0..<8 {
            for entry in pending {
                consumer.handleAudioBuffer(entry.buffer, time: entry.time)
                lastTime = entry.time
                replayed += 1
            }
            let added: Bool = consumersLock.withLock {
                let newer = Self.entries(in: preBufferRing.snapshot(), after: lastTime)
                if newer.isEmpty || attempt == 7 {
                    if !consumers.contains(where: { $0.consumerID == consumer.consumerID }) {
                        consumers.append(consumer)
                    }
                    return true
                }
                pending = newer
                return false
            }
            if added { break }
        }
        log.info("Audio consumer 加入: \(consumer.consumerID) (replay \(replayed) buffers)", category: "Audio")
    }

    /// 取出 `after` 之後（較新）的 entries；`after == nil` 代表全部
    private static func entries(
        in snapshot: [(buffer: AVAudioPCMBuffer, time: AVAudioTime)],
        after last: AVAudioTime?
    ) -> [(buffer: AVAudioPCMBuffer, time: AVAudioTime)] {
        guard let last else { return snapshot }
        if let idx = snapshot.lastIndex(where: { $0.time === last }) {
            return Array(snapshot[(idx + 1)...])
        }
        return snapshot.filter { entry in
            if entry.time.isSampleTimeValid && last.isSampleTimeValid {
                return entry.time.sampleTime > last.sampleTime
            }
            if entry.time.isHostTimeValid && last.isHostTimeValid {
                return entry.time.hostTime > last.hostTime
            }
            return false
        }
    }

    func removeConsumer(_ consumer: AudioBufferConsumer) {
        let total: Int = consumersLock.withLock {
            consumers.removeAll(where: { $0.consumerID == consumer.consumerID })
            return consumers.count
        }
        log.info("Audio consumer 移除: \(consumer.consumerID) (total=\(total))", category: "Audio")
    }
}

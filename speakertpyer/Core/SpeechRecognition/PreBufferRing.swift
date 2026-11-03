//
//  PreBufferRing.swift
//  speakertpyer
//
//  預先配置的環形音訊緩衝區。
//  render thread（audio tap）只做純 memcpy，不做 heap 配置、不呼叫 Obj-C，
//  避免 AVAudioPCMBuffer.copy() 在 real-time 執行緒上 malloc/dispatch 造成 overrun。
//

import AVFoundation
import Foundation

/// 固定容量的環形緩衝區，保存最近數秒的音訊，供新 consumer 加入時回放。
/// 寫入（render thread）與快照（main/背景）以 os_unfair_lock 互斥；
/// os_unfair_lock 支援優先級捐贈，緩解 NSLock 在 real-time 執行緒上的優先倒轉風險。
final class PreBufferRing {
    private let slotCount: Int
    private let frameCapacity: AVAudioFrameCount

    private var slots: [AVAudioPCMBuffer] = []
    private var slotTimes: [AVAudioTime] = []
    private var slotValid: [Bool] = []
    private var writeIndex = 0

    private let lock = os_unfair_lock_t.allocate(capacity: 1)

    /// 回放時最多取最近幾秒（以時間而非 slot 數計，不受各裝置 tap buffer 大小影響）
    static let replayDuration: Double = 1.5

    /// frameCapacity 要大於實際 tap buffer：macOS 上 48kHz 裝置常是每次 4800 frames（0.1 秒），
    /// 舊值 4096 會讓每次寫入都被略過，pre-buffer 永遠是空的（開頭第一個字遺失）。
    init(slotCount: Int = 96, frameCapacity: AVAudioFrameCount = 8192) {
        self.slotCount = slotCount
        self.frameCapacity = frameCapacity
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// 在非 render thread 呼叫：依目前裝置格式預配置所有 slot（一次性配置，之後 render thread 不再配置）。
    func prepare(format: AVAudioFormat) {
        let newSlots = (0..<slotCount).compactMap {
            _ in AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity)
        }
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        slots = newSlots
        slotTimes = Array(repeating: AVAudioTime(sampleTime: 0, atRate: format.sampleRate), count: newSlots.count)
        slotValid = Array(repeating: false, count: newSlots.count)
        writeIndex = 0
    }

    /// render thread 呼叫：把 buffer 的 sample 資料 memcpy 進下一個 slot（格式無關，逐 mBuffers 複製）。
    func write(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard !slots.isEmpty, buffer.frameLength > 0 else { return }
        let dst = slots[writeIndex]
        guard dst.format.channelCount == buffer.format.channelCount else { return }

        let srcList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let dstList = UnsafeMutableAudioBufferListPointer(dst.mutableAudioBufferList)
        guard srcList.count == dstList.count else { return }

        // 萬一 buffer 仍超過容量，只保留最後 frameCapacity 個 frame（而不是整個丟掉）
        let frames = min(buffer.frameLength, frameCapacity)
        let skipFrames = Int(buffer.frameLength - frames)
        for i in 0..<srcList.count {
            let src = srcList[i]
            guard let srcData = src.mData, let dstData = dstList[i].mData else { return }
            let bytesPerFrame = Int(src.mDataByteSize) / Int(buffer.frameLength)
            let size = Int(frames) * bytesPerFrame
            memcpy(dstData, srcData.advanced(by: skipFrames * bytesPerFrame), size)
            dstList[i].mDataByteSize = UInt32(size)
        }
        dst.frameLength = frames
        slotTimes[writeIndex] = time
        slotValid[writeIndex] = true
        writeIndex = (writeIndex + 1) % slots.count
    }

    /// 非 render thread 呼叫：取得目前所有有效 buffer 的有序拷貝（最舊到最新）。
    /// 拷貝在此處（非 render thread）完成，render thread 永遠不做配置。
    func snapshot() -> [(buffer: AVAudioPCMBuffer, time: AVAudioTime)] {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard !slots.isEmpty else { return [] }
        // 從最新往回取，累積到 replayDuration 為止，再反轉成最舊→最新
        let maxFrames = AVAudioFrameCount(slots[0].format.sampleRate * Self.replayDuration)
        var picked: [Int] = []
        var total: AVAudioFrameCount = 0
        for i in 1...slots.count {
            let idx = (writeIndex - i + slots.count) % slots.count
            guard slotValid[idx] else { break }
            picked.append(idx)
            total += slots[idx].frameLength
            if total >= maxFrames { break }
        }
        var result: [(buffer: AVAudioPCMBuffer, time: AVAudioTime)] = []
        result.reserveCapacity(picked.count)
        for idx in picked.reversed() {
            guard let copy = slots[idx].copy() as? AVAudioPCMBuffer else { continue }
            result.append((copy, slotTimes[idx]))
        }
        return result
    }

    /// 清空（標記所有 slot 失效，保留已配置記憶體供下次重用）。
    func clear() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        for i in slotValid.indices { slotValid[i] = false }
        writeIndex = 0
    }
}

//
//  MainThreadThrottler.swift
//  speakertpyer
//

import Darwin
import Foundation

/// 從 audio render thread（或其他高頻 callback）安全節流派發到 main queue。
///
/// 為什麼：AVAudioEngine tap 每 ~21ms 觸發一次。若每次都 `DispatchQueue.main.async`，
/// 在低端 Mac 上會把 main run loop 塞滿；節流到 ~20Hz 已足夠 UI 動畫，且省電。
///
/// 用法：
/// ```
/// private let throttler = MainThreadThrottler(intervalMs: 50)
/// throttler.dispatch { [weak self] in self?.audioLevel = level }
/// ```
final class MainThreadThrottler {
    private var lastDispatchAbs: UInt64 = 0
    private let intervalAbs: UInt64
    private let lock = os_unfair_lock_s()
    private var lockState = os_unfair_lock()

    init(intervalMs: Double = 50.0) {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ns = UInt64(intervalMs * 1_000_000.0)
        // ns -> mach abs ticks
        self.intervalAbs = ns * UInt64(info.denom) / UInt64(info.numer)
    }

    /// 嘗試把 work 派發到 main queue；若距離上次派發小於 interval 則直接丟棄。
    /// 此方法 thread-safe，可在 audio render thread 上呼叫。
    func dispatch(_ work: @escaping @Sendable () -> Void) {
        let now = mach_absolute_time()
        os_unfair_lock_lock(&lockState)
        let shouldFire = (now &- lastDispatchAbs) >= intervalAbs
        if shouldFire {
            lastDispatchAbs = now
        }
        os_unfair_lock_unlock(&lockState)

        if shouldFire {
            DispatchQueue.main.async(execute: work)
        }
    }

    /// 重設節流計時器，下次 dispatch 一定會發。
    func reset() {
        os_unfair_lock_lock(&lockState)
        lastDispatchAbs = 0
        os_unfair_lock_unlock(&lockState)
    }
}

//
//  SystemAudioDucker.swift
//  speakertpyer
//
//  錄音時把系統輸出音量壓低（音樂 / 影片不會干擾辨識），結束後恢復。
//  原音量同時記在 UserDefaults：App 若在錄音中當掉，下次啟動會自動還原。
//

#if os(macOS)
import AudioToolbox
import CoreAudio
import Foundation

enum SystemAudioDucker {
    private static let restoreKey = "audioDucker.pendingRestore"
    private static var savedVolume: Float32?
    private static var savedDevice: AudioDeviceID?

    /// 壓低到原音量的比例
    static var duckRatio: Float32 = 0.2

    static func duck() {
        guard savedVolume == nil, let device = defaultOutputDevice(),
              let current = volume(of: device), current > 0.05 else { return }
        let target = current * duckRatio
        guard setVolume(target, on: device) else { return }
        savedVolume = current
        savedDevice = device
        UserDefaults.standard.set(["device": Int(device), "volume": Double(current)], forKey: restoreKey)
        AppLogger.shared.info("錄音中降低系統音量 \(Int(current * 100))% → \(Int(target * 100))%", category: "Audio")
    }

    static func restore() {
        guard let volume = savedVolume, let device = savedDevice else { return }
        _ = setVolume(volume, on: device)
        savedVolume = nil
        savedDevice = nil
        UserDefaults.standard.removeObject(forKey: restoreKey)
    }

    /// App 啟動時呼叫：上次錄音中途結束沒還原的音量補還原
    static func restorePendingIfNeeded() {
        guard let pending = UserDefaults.standard.dictionary(forKey: restoreKey),
              let device = pending["device"] as? Int,
              let volume = pending["volume"] as? Double else { return }
        _ = setVolume(Float32(volume), on: AudioDeviceID(device))
        UserDefaults.standard.removeObject(forKey: restoreKey)
        AppLogger.shared.info("還原上次未恢復的系統音量 \(Int(volume * 100))%", category: "Audio")
    }

    // MARK: - CoreAudio

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func volume(of device: AudioDeviceID) -> Float32? {
        var address = volumeAddress
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    @discardableResult
    private static func setVolume(_ value: Float32, on device: AudioDeviceID) -> Bool {
        var address = volumeAddress
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return false }
        var v = max(0, min(1, value))
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }
}
#endif

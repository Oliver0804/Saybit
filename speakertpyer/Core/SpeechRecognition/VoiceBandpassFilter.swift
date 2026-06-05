//
//  VoiceBandpassFilter.swift
//  speakertpyer
//
//  人聲帶通濾波器：high-pass 80Hz + low-pass 8kHz 串聯。
//  在 SharedAudioEngine tap 內 in-place 套用，去除低頻嗡嗡聲、
//  60Hz 電源 hum、高頻 hiss / 滑鼠鍵盤點擊噪音，提升 STT 信噪比。
//

import AVFoundation
import Foundation

/// 單階 biquad，Direct Form II Transposed。係數依 RBJ Audio EQ Cookbook。
private final class BiquadSection {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0
    var a1: Float = 0, a2: Float = 0
    var z1: Float = 0
    var z2: Float = 0

    @inline(__always)
    func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    func reset() { z1 = 0; z2 = 0 }

    /// High-pass at `fc` Hz with Butterworth Q (1/√2)，係數正規化以 a0
    func configureHighPass(cutoff fc: Float, sampleRate fs: Float) {
        let q: Float = 0.7071067
        let w0 = 2 * .pi * fc / fs
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * q)
        let a0 = 1 + alpha
        b0 = (1 + cw) / 2 / a0
        b1 = -(1 + cw) / a0
        b2 = (1 + cw) / 2 / a0
        a1 = -2 * cw / a0
        a2 = (1 - alpha) / a0
    }

    /// Low-pass at `fc` Hz with Butterworth Q
    func configureLowPass(cutoff fc: Float, sampleRate fs: Float) {
        let q: Float = 0.7071067
        let w0 = 2 * .pi * fc / fs
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * q)
        let a0 = 1 + alpha
        b0 = (1 - cw) / 2 / a0
        b1 = (1 - cw) / a0
        b2 = (1 - cw) / 2 / a0
        a1 = -2 * cw / a0
        a2 = (1 - alpha) / a0
    }
}

/// 兩階串聯帶通：high-pass → low-pass。Per-channel 維護獨立 state。
final class VoiceBandpassFilter {
    /// 是否套用濾波（外部可在 audio thread 上安全讀寫；單個 Bool 在 macOS 是 atomic）
    var isEnabled: Bool = true

    private let highPassCutoff: Float
    private let lowPassCutoff: Float

    /// channel × [highPass, lowPass]
    private var sections: [[BiquadSection]] = []
    private var configuredSampleRate: Float = 0
    private var configuredChannels: Int = 0

    init(highPassCutoff: Float = 80, lowPassCutoff: Float = 8000) {
        self.highPassCutoff = highPassCutoff
        self.lowPassCutoff = lowPassCutoff
    }

    /// 在每次 audio engine restart 後呼叫；若 format 沒變則保留現有 state。
    func prepare(sampleRate: Float, channelCount: Int) {
        guard sampleRate > 0, channelCount > 0 else { return }
        if sampleRate == configuredSampleRate, channelCount == configuredChannels {
            // 同格式只重設 delay state，係數不重算
            for ch in sections { ch.forEach { $0.reset() } }
            return
        }
        configuredSampleRate = sampleRate
        configuredChannels = channelCount

        // Nyquist guard：lowPass 不超過 sampleRate / 2 * 0.9
        let safeLP = min(lowPassCutoff, sampleRate * 0.45)

        sections = (0..<channelCount).map { _ in
            let hp = BiquadSection()
            hp.configureHighPass(cutoff: highPassCutoff, sampleRate: sampleRate)
            let lp = BiquadSection()
            lp.configureLowPass(cutoff: safeLP, sampleRate: sampleRate)
            return [hp, lp]
        }
    }

    /// In-place 處理 AVAudioPCMBuffer。僅支援 Float32 deinterleaved（AVAudioEngine input 預設）。
    func process(_ buffer: AVAudioPCMBuffer) {
        guard isEnabled else { return }
        guard buffer.format.commonFormat == .pcmFormatFloat32 else { return }
        guard let channelData = buffer.floatChannelData else { return }

        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount <= sections.count else { return }

        for ch in 0..<channelCount {
            let samples = channelData[ch]
            let chain = sections[ch]
            let hp = chain[0]
            let lp = chain[1]
            // 兩階串聯 — high-pass 後接 low-pass
            for i in 0..<frameLength {
                let x = samples[i]
                samples[i] = lp.process(hp.process(x))
            }
        }
    }

    func reset() {
        for ch in sections { ch.forEach { $0.reset() } }
    }
}

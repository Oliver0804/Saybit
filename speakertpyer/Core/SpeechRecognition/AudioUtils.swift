//
//  AudioUtils.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/29.
//

import AVFoundation

/// 共享音訊工具函式
enum AudioUtils {
    /// 從 PCM buffer 計算 RMS (Root Mean Square)
    static func rms(from buffer: AVAudioPCMBuffer) -> Float? {
        guard let channelData = buffer.floatChannelData?[0] else { return nil }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }

        var sum: Float = 0
        for i in 0..<frameLength {
            sum += channelData[i] * channelData[i]
        }
        return sqrtf(sum / Float(frameLength))
    }

    /// 將 RMS 正規化為 0~1 範圍
    static func normalizedLevel(rms: Float, multiplier: Float = 5.0) -> Float {
        max(0, min(1, rms * multiplier))
    }
}

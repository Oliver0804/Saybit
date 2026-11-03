//
//  FeedbackPlayer.swift
//  SaybitiOS
//
//  iOS 版的回饋（對應 macOS 的 NSSound）：觸覺 + 系統音效。
//

import AudioToolbox
import UIKit

enum FeedbackPlayer {
    enum Event {
        case start, stop, success, cancel, failure
    }

    static func play(_ event: Event, sound: Bool, haptic: Bool) {
        if haptic {
            switch event {
            case .start, .stop:
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case .success:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .cancel:
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case .failure:
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
        if sound {
            // 1113 / 1114 = 系統錄音開始 / 結束音；1057 = 輕觸音（Tink）
            switch event {
            case .start: AudioServicesPlaySystemSound(1113)
            case .stop: AudioServicesPlaySystemSound(1114)
            case .success: AudioServicesPlaySystemSound(1057)
            case .cancel, .failure: break
            }
        }
    }
}

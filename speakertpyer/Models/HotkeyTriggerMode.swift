//
//  HotkeyTriggerMode.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import Foundation

enum HotkeyTriggerMode: String, CaseIterable, Identifiable {
    case toggle
    case hold
    case doubleTap

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .toggle: return "按一下觸發"
        case .hold: return "按住說話"
        case .doubleTap: return "雙擊觸發"
        }
    }

    var description: String {
        switch self {
        case .toggle: return "按一下開始錄音，說完後自動停止（2 秒靜音）"
        case .hold: return "按住開始錄音，放開停止"
        case .doubleTap: return "快速雙擊快捷鍵開始錄音，再雙擊停止"
        }
    }
}

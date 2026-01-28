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

    var displayName: String { L10n.hotkeyTriggerMode(self) }

    var description: String { L10n.hotkeyTriggerModeDesc(self) }
}

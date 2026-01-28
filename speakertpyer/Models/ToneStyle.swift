//
//  ToneStyle.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import Foundation

enum ToneStyle: String, CaseIterable, Identifiable {
    case auto
    case formal
    case casual
    case veryCasual = "very_casual"

    var id: String { rawValue }

    var displayName: String { L10n.toneStyle(self) }
}

enum PromptStyle: String, CaseIterable, Identifiable {
    case typeless
    case wisprFlow = "wispr-flow"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .typeless: return "Typeless"
        case .wisprFlow: return "Wispr Flow"
        }
    }
}

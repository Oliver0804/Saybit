//
//  ProcessingMode.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import Foundation

enum ProcessingMode: String, CaseIterable, Identifiable {
    case dictation
    case command
    case edit

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dictation: return "聽寫"
        case .command: return "指令"
        case .edit: return "編輯"
        }
    }
}

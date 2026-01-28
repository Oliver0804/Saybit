//
//  STTEngine.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/28.
//

import Foundation

enum STTEngine: String, CaseIterable {
    case appleSpeech = "apple_speech"
    case whisperAPI = "whisper_api"

    var displayName: String { L10n.sttEngine(self) }
}

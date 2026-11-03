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
    /// sherpa-onnx SenseVoice 離線辨識
    case sherpaSenseVoice = "sherpa_sensevoice"

    var displayName: String { L10n.sttEngine(self) }
}

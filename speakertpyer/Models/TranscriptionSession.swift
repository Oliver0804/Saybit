//
//  TranscriptionSession.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import Foundation

@Observable
class TranscriptionSession {
    enum State: Equatable {
        case idle
        case recording
        case processing
        case done
        case confirming(remaining: Int)
        case error(String)
    }

    var state: State = .idle
    var rawTranscript: String = ""
    var processedText: String = ""
    var appContext: AppContext = .empty
    var startTime: Date?
    var endTime: Date?
    var audioLevel: Float = 0.0
    var smartSendCancelled: Bool = false
    var modelName: String = ""
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    var totalTokens: Int = 0

    var duration: TimeInterval {
        guard let start = startTime else { return 0 }
        let end = endTime ?? Date()
        return end.timeIntervalSince(start)
    }

    func reset() {
        state = .idle
        rawTranscript = ""
        processedText = ""
        appContext = .empty
        startTime = nil
        endTime = nil
        audioLevel = 0.0
        smartSendCancelled = false
        modelName = ""
        promptTokens = 0
        completionTokens = 0
        totalTokens = 0
    }
}

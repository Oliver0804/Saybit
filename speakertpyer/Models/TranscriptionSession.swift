//
//  TranscriptionSession.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import Foundation

enum PendingAction {
    case createEvent(LLMEventResponse)
    case createReminder(LLMReminderResponse)
}

struct ErrorContext {
    let transcript: String
    let selectedText: String?
    let appContext: AppContext
}

@Observable
class TranscriptionSession {
    enum State: Equatable {
        case idle
        case listening
        case recording
        case processing
        case done
        case previewing
        case confirming(remaining: Int)
        case error(String)
    }

    var state: State = .idle
    var rawTranscript: String = ""
    var processedText: String = ""
    var appContext: AppContext = .empty
    var pendingAction: PendingAction?
    var startTime: Date?
    var endTime: Date?
    var audioLevel: Float = 0.0
    var smartSendCancelled: Bool = false
    var lastErrorContext: ErrorContext?
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
        pendingAction = nil
        startTime = nil
        endTime = nil
        audioLevel = 0.0
        smartSendCancelled = false
        lastErrorContext = nil
        modelName = ""
        promptTokens = 0
        completionTokens = 0
        totalTokens = 0
    }
}

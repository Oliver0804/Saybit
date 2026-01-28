//
//  ActionIntentPayload.swift
//  speakertpyer
//

import Foundation

/// Stage 2 structured response for create_event intent
struct LLMEventResponse: Decodable {
    let title: String
    let date: String                // ISO 8601 (e.g. "2026-01-29T15:00:00+08:00")
    let durationMinutes: Int?       // default 60
    let location: String?
    let notes: String?
    let confirmationText: String    // human-readable confirmation

    enum CodingKeys: String, CodingKey {
        case title, date, location, notes
        case durationMinutes = "duration_minutes"
        case confirmationText = "confirmation_text"
    }
}

/// Stage 2 structured response for create_reminder intent
struct LLMReminderResponse: Decodable {
    let title: String
    let dueDate: String?            // ISO 8601, nil if no specific time
    let notes: String?
    let confirmationText: String

    enum CodingKeys: String, CodingKey {
        case title, notes
        case dueDate = "due_date"
        case confirmationText = "confirmation_text"
    }
}

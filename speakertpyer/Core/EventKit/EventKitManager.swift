//
//  EventKitManager.swift
//  speakertpyer
//

import EventKit
import Foundation

actor EventKitManager {
    static let shared = EventKitManager()

    private let store = EKEventStore()

    // MARK: - Permission

    func requestCalendarAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    func requestReminderAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToReminders()
        } catch {
            return false
        }
    }

    nonisolated var calendarAuthorized: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .fullAccess || status == .authorized
    }

    nonisolated var reminderAuthorized: Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        return status == .fullAccess || status == .authorized
    }

    // MARK: - Create Event

    struct EventParams {
        let title: String
        let startDate: Date
        let endDate: Date
        let location: String?
        let notes: String?
    }

    func createEvent(_ params: EventParams) throws -> String {
        let event = EKEvent(eventStore: store)
        event.title = params.title
        event.startDate = params.startDate
        event.endDate = params.endDate
        event.location = params.location
        event.notes = params.notes
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent)
        return event.eventIdentifier
    }

    // MARK: - Create Reminder

    struct ReminderParams {
        let title: String
        let dueDate: Date?
        let notes: String?
    }

    func createReminder(_ params: ReminderParams) throws -> String {
        let reminder = EKReminder(eventStore: store)
        reminder.title = params.title
        if let due = params.dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due
            )
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        reminder.notes = params.notes
        reminder.calendar = store.defaultCalendarForNewReminders()
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }
}

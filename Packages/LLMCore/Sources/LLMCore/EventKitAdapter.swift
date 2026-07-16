// SPDX-License-Identifier: MIT

#if canImport(EventKit)
import Foundation
import EventKit

/// The real, on-device `EventStoring` backed by `EKEventStore`. Access is requested lazily on first use
/// (iOS 17+/macOS 14+ full-access APIs); a denial surfaces as `EventStoreError.*AccessDenied` which the
/// tools turn into an instructive "enable it in Settings" message. Not unit-tested — device behavior only;
/// LLMCore's tests exercise the tools through a fake conforming to `EventStoring`.
///
/// `@unchecked Sendable`: `EKEventStore` is a reference type that isn't `Sendable`, but the tools call one
/// method at a time and never share the store across concurrent calls, so the single instance is safe here.
public final class EventKitStore: EventStoring, @unchecked Sendable {
    private let store = EKEventStore()
    public init() {}

    private func ensureEventAccess() async throws {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        if !granted { throw EventStoreError.calendarAccessDenied }
    }

    private func ensureReminderAccess() async throws {
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        if !granted { throw EventStoreError.reminderAccessDenied }
    }

    public func createEvent(_ draft: CalendarEventDraft) async throws -> String {
        try await ensureEventAccess()
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw EventStoreError.failed("no writable calendar")
        }
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.end ?? draft.start.addingTimeInterval(3600)
        event.notes = draft.notes
        event.calendar = calendar
        do { try store.save(event, span: .thisEvent) }
        catch { throw EventStoreError.failed(error.localizedDescription) }
        return draft.title
    }

    public func events(daysAhead: Int) async throws -> [CalendarEventInfo] {
        try await ensureEventAccess()
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: max(1, daysAhead), to: now) ?? now
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        return store.events(matching: predicate).map { ev in
            CalendarEventInfo(title: ev.title ?? "(untitled)", start: ev.startDate,
                              end: ev.endDate, calendar: ev.calendar?.title)
        }
    }

    public func createReminder(_ draft: ReminderDraft) async throws -> String {
        try await ensureReminderAccess()
        guard let calendar = store.defaultCalendarForNewReminders() else {
            throw EventStoreError.failed("no writable reminders list")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = draft.title
        reminder.notes = draft.notes
        reminder.calendar = calendar
        if let due = draft.due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
        }
        do { try store.save(reminder, commit: true) }
        catch { throw EventStoreError.failed(error.localizedDescription) }
        return draft.title
    }
}
#endif

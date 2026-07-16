// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Seam types (framework-free, so the tools + tests never touch EventKit)

/// A calendar event the model wants to create.
public struct CalendarEventDraft: Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date?
    public var notes: String?
    public init(title: String, start: Date, end: Date? = nil, notes: String? = nil) {
        self.title = title; self.start = start; self.end = end; self.notes = notes
    }
}

/// A calendar event read back for listing.
public struct CalendarEventInfo: Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date?
    public var calendar: String?
    public init(title: String, start: Date, end: Date? = nil, calendar: String? = nil) {
        self.title = title; self.start = start; self.end = end; self.calendar = calendar
    }
}

/// A reminder the model wants to create.
public struct ReminderDraft: Sendable, Equatable {
    public var title: String
    public var due: Date?
    public var notes: String?
    public init(title: String, due: Date? = nil, notes: String? = nil) {
        self.title = title; self.due = due; self.notes = notes
    }
}

/// Errors the calendar/reminder seam raises; the tools map them to instructive strings.
public enum EventStoreError: Error, Sendable, Equatable {
    case calendarAccessDenied
    case reminderAccessDenied
    case failed(String)
}

/// The EventKit seam. A real `EKEventStore`-backed adapter conforms on-device; tests inject a fake. Kept in
/// plain value types so LLMCore's tool + test code never imports EventKit (only the adapter does).
public protocol EventStoring: Sendable {
    /// Create an event; returns a short human label on success.
    func createEvent(_ draft: CalendarEventDraft) async throws -> String
    /// Events starting within the next `daysAhead` days, soonest first.
    func events(daysAhead: Int) async throws -> [CalendarEventInfo]
    /// Create a reminder; returns a short human label on success.
    func createReminder(_ draft: ReminderDraft) async throws -> String
}

// MARK: - ISO 8601 parsing

/// Lenient ISO 8601 parsing: full internet date-time (with or without fractional seconds / timezone), plus
/// zone-less local forms and a bare date. Zone-less strings are interpreted in the device's current
/// timezone. Returns nil for anything unparseable so the tools can reject garbage with a clear message.
enum ISO8601Parsing {
    static func date(from raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            df.dateFormat = fmt
            if let d = df.date(from: s) { return d }
        }
        return nil
    }

    /// Human-readable local rendering for confirmations / listings.
    static func display(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: date)
    }
}

// MARK: - Tools

/// Add an event to the user's calendar.
public struct CreateCalendarEventTool: Tool {
    private let store: any EventStoring
    public init(store: any EventStoring) { self.store = store }

    public var schema: ToolSchema {
        ToolSchema(name: "create_calendar_event",
                   description: "Add an event to the user's calendar. Use when the user asks to schedule, "
                              + "book, or add something at a specific date/time.",
                   parameters: [
                       ToolParam(name: "title", kind: .string, description: "Event title"),
                       ToolParam(name: "start", kind: .string,
                                 description: "Start, ISO 8601, e.g. 2026-07-20T15:00"),
                       ToolParam(name: "end", kind: .string,
                                 description: "End, ISO 8601 (optional; defaults to one hour)", required: false),
                       ToolParam(name: "notes", kind: .string, description: "Optional notes", required: false),
                   ])
    }

    public func execute(argumentsJSON: String) async -> String {
        let call = ToolCall(name: "create_calendar_event", argumentsJSON: argumentsJSON)
        guard let title = call.arg("title")?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return "Error: missing event 'title'."
        }
        guard let startRaw = call.arg("start"), let start = ISO8601Parsing.date(from: startRaw) else {
            return "Error: couldn't read 'start' as a date/time — use ISO 8601 like 2026-07-20T15:00."
        }
        var end: Date?
        if let endRaw = call.arg("end"), !endRaw.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let parsed = ISO8601Parsing.date(from: endRaw) else {
                return "Error: couldn't read 'end' as a date/time — use ISO 8601 like 2026-07-20T16:00."
            }
            end = parsed
        }
        let draft = CalendarEventDraft(title: title, start: start, end: end, notes: call.arg("notes"))
        do {
            _ = try await store.createEvent(draft)
            return "Added \"\(title)\" to your calendar on \(ISO8601Parsing.display(start))."
        } catch EventStoreError.calendarAccessDenied {
            return "Calendar access is off — enable it in Settings to add events."
        } catch {
            return "Couldn't add the event: \(errorText(error))."
        }
    }
}

/// List the user's upcoming calendar events.
public struct ListCalendarEventsTool: Tool {
    private let store: any EventStoring
    public init(store: any EventStoring) { self.store = store }

    public var schema: ToolSchema {
        ToolSchema(name: "list_calendar_events",
                   description: "List the user's upcoming calendar events. Use when asked what's on their "
                              + "schedule or if they're free.",
                   parameters: [ToolParam(name: "daysAhead", kind: .number,
                                          description: "How many days ahead to look (1–14, default 7)",
                                          required: false)])
    }

    public func execute(argumentsJSON: String) async -> String {
        let call = ToolCall(name: "list_calendar_events", argumentsJSON: argumentsJSON)
        let requested = call.arg("daysAhead").flatMap { Int(Double($0) ?? -1) } ?? 7
        let days = min(14, max(1, requested))   // clamp to the documented window
        do {
            let events = try await store.events(daysAhead: days)
            guard !events.isEmpty else { return "No events in the next \(days) day\(days == 1 ? "" : "s")." }
            let lines = events.sorted { $0.start < $1.start }.map { e -> String in
                "• \(e.title) — \(ISO8601Parsing.display(e.start))"
            }
            return "Events in the next \(days) day\(days == 1 ? "" : "s"):\n" + lines.joined(separator: "\n")
        } catch EventStoreError.calendarAccessDenied {
            return "Calendar access is off — enable it in Settings to see events."
        } catch {
            return "Couldn't read the calendar: \(errorText(error))."
        }
    }
}

/// Create a reminder for the user.
public struct CreateReminderTool: Tool {
    private let store: any EventStoring
    public init(store: any EventStoring) { self.store = store }

    public var schema: ToolSchema {
        ToolSchema(name: "create_reminder",
                   description: "Create a reminder in the user's Reminders. Use when the user asks to be "
                              + "reminded to do something, optionally by a due time.",
                   parameters: [
                       ToolParam(name: "title", kind: .string, description: "What to be reminded of"),
                       ToolParam(name: "due", kind: .string,
                                 description: "Due date/time, ISO 8601 (optional)", required: false),
                       ToolParam(name: "notes", kind: .string, description: "Optional notes", required: false),
                   ])
    }

    public func execute(argumentsJSON: String) async -> String {
        let call = ToolCall(name: "create_reminder", argumentsJSON: argumentsJSON)
        guard let title = call.arg("title")?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return "Error: missing reminder 'title'."
        }
        var due: Date?
        if let dueRaw = call.arg("due"), !dueRaw.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let parsed = ISO8601Parsing.date(from: dueRaw) else {
                return "Error: couldn't read 'due' as a date/time — use ISO 8601 like 2026-07-20T09:00."
            }
            due = parsed
        }
        let draft = ReminderDraft(title: title, due: due, notes: call.arg("notes"))
        do {
            _ = try await store.createReminder(draft)
            if let due { return "Reminder set: \"\(title)\" for \(ISO8601Parsing.display(due))." }
            return "Reminder set: \"\(title)\"."
        } catch EventStoreError.reminderAccessDenied {
            return "Reminders access is off — enable it in Settings to add reminders."
        } catch {
            return "Couldn't set the reminder: \(errorText(error))."
        }
    }
}

/// A short user-facing string for an unexpected store error.
private func errorText(_ error: Error) -> String {
    if case EventStoreError.failed(let m) = error { return m }
    return "\(error)"
}

// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

/// The calendar/reminder tools driven through a fake `EventStoring`: create/list/reminder happy paths, the
/// ISO-8601 parser rejecting garbage before any store call, the `daysAhead` clamp, and access-denied paths
/// returning instructive strings (never a throw/crash).
final class CalendarToolsTests: XCTestCase {

    // MARK: create_calendar_event

    func testCreateEventSuccess() async {
        let store = FakeEventStore()
        let out = await CreateCalendarEventTool(store: store)
            .execute(argumentsJSON: #"{"title":"Dentist","start":"2026-07-20T15:00:00Z","notes":"molar"}"#)
        XCTAssertTrue(out.contains("Added"), out)
        let created = await store.createdEvents
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created.first?.title, "Dentist")
        XCTAssertEqual(created.first?.notes, "molar")
    }

    func testCreateEventParsesEnd() async {
        let store = FakeEventStore()
        _ = await CreateCalendarEventTool(store: store)
            .execute(argumentsJSON: #"{"title":"Mtg","start":"2026-07-20T15:00","end":"2026-07-20T16:00"}"#)
        let created = await store.createdEvents
        XCTAssertNotNil(created.first?.end)
    }

    func testCreateEventBadStartRejectedBeforeStore() async {
        let store = FakeEventStore()
        let out = await CreateCalendarEventTool(store: store)
            .execute(argumentsJSON: #"{"title":"X","start":"whenever"}"#)
        XCTAssertTrue(out.hasPrefix("Error"), out)
        let created = await store.createdEvents
        XCTAssertTrue(created.isEmpty, "store must not be called for an unparseable date")
    }

    func testCreateEventBadEndRejected() async {
        let out = await CreateCalendarEventTool(store: FakeEventStore())
            .execute(argumentsJSON: #"{"title":"X","start":"2026-07-20T15:00","end":"nope"}"#)
        XCTAssertTrue(out.hasPrefix("Error"), out)
    }

    func testCreateEventMissingTitle() async {
        let out = await CreateCalendarEventTool(store: FakeEventStore())
            .execute(argumentsJSON: #"{"start":"2026-07-20T15:00"}"#)
        XCTAssertTrue(out.contains("missing"), out)
    }

    func testCreateEventAccessDenied() async {
        let out = await CreateCalendarEventTool(store: FakeEventStore(denyCalendar: true))
            .execute(argumentsJSON: #"{"title":"X","start":"2026-07-20T15:00:00Z"}"#)
        XCTAssertTrue(out.contains("Calendar access is off"), out)
    }

    // MARK: list_calendar_events

    func testListEventsRendersSortedByStart() async {
        let d1 = Date(timeIntervalSince1970: 2_000_000)
        let d2 = Date(timeIntervalSince1970: 1_000_000)
        let store = FakeEventStore(events: [CalendarEventInfo(title: "Later", start: d1),
                                            CalendarEventInfo(title: "Sooner", start: d2)])
        let out = await ListCalendarEventsTool(store: store).execute(argumentsJSON: #"{"daysAhead":3}"#)
        XCTAssertTrue(out.contains("Sooner"))
        XCTAssertTrue(out.contains("Later"))
        XCTAssertLessThan(out.range(of: "Sooner")!.lowerBound, out.range(of: "Later")!.lowerBound)
        let days = await store.lastDaysAhead
        XCTAssertEqual(days, 3)
    }

    func testListEventsEmpty() async {
        let out = await ListCalendarEventsTool(store: FakeEventStore()).execute(argumentsJSON: #"{"daysAhead":5}"#)
        XCTAssertTrue(out.contains("No events"), out)
    }

    func testListEventsClampsDaysAhead() async {
        let store = FakeEventStore()
        _ = await ListCalendarEventsTool(store: store).execute(argumentsJSON: #"{"daysAhead":30}"#)
        let high = await store.lastDaysAhead
        XCTAssertEqual(high, 14, "must clamp to the 14-day window")

        let store2 = FakeEventStore()
        _ = await ListCalendarEventsTool(store: store2).execute(argumentsJSON: #"{"daysAhead":0}"#)
        let low = await store2.lastDaysAhead
        XCTAssertEqual(low, 1)

        let store3 = FakeEventStore()
        _ = await ListCalendarEventsTool(store: store3).execute(argumentsJSON: "{}")
        let unset = await store3.lastDaysAhead
        XCTAssertEqual(unset, 7, "default window when unspecified")
    }

    func testListEventsAccessDenied() async {
        let out = await ListCalendarEventsTool(store: FakeEventStore(denyCalendar: true))
            .execute(argumentsJSON: #"{"daysAhead":3}"#)
        XCTAssertTrue(out.contains("Calendar access is off"), out)
    }

    // MARK: create_reminder

    func testCreateReminderWithDue() async {
        let store = FakeEventStore()
        let out = await CreateReminderTool(store: store)
            .execute(argumentsJSON: #"{"title":"Call mom","due":"2026-07-20T09:00:00Z"}"#)
        XCTAssertTrue(out.contains("Reminder set"), out)
        let created = await store.createdReminders
        XCTAssertEqual(created.first?.title, "Call mom")
        XCTAssertNotNil(created.first?.due)
    }

    func testCreateReminderNoDue() async {
        let store = FakeEventStore()
        let out = await CreateReminderTool(store: store).execute(argumentsJSON: #"{"title":"Buy milk"}"#)
        XCTAssertTrue(out.contains("Reminder set"), out)
        let created = await store.createdReminders
        XCTAssertNil(created.first?.due)
    }

    func testCreateReminderBadDue() async {
        let out = await CreateReminderTool(store: FakeEventStore())
            .execute(argumentsJSON: #"{"title":"X","due":"soon"}"#)
        XCTAssertTrue(out.hasPrefix("Error"), out)
    }

    func testCreateReminderAccessDenied() async {
        let out = await CreateReminderTool(store: FakeEventStore(denyReminders: true))
            .execute(argumentsJSON: #"{"title":"X"}"#)
        XCTAssertTrue(out.contains("Reminders access is off"), out)
    }

    // MARK: ISO 8601 parsing

    func testISO8601ParsingAcceptsCommonFormsRejectsGarbage() {
        XCTAssertNotNil(ISO8601Parsing.date(from: "2026-07-20T15:00:00Z"))
        XCTAssertNotNil(ISO8601Parsing.date(from: "2026-07-20T15:00:00+02:00"))
        XCTAssertNotNil(ISO8601Parsing.date(from: "2026-07-20T15:00"))
        XCTAssertNotNil(ISO8601Parsing.date(from: "2026-07-20"))
        XCTAssertNil(ISO8601Parsing.date(from: "tomorrow"))
        XCTAssertNil(ISO8601Parsing.date(from: ""))
    }
}

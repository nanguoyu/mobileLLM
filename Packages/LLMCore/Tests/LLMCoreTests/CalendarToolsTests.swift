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
        XCTAssertNil(ISO8601Parsing.date(from: ""))
        XCTAssertNil(ISO8601Parsing.date(from: "whenever you feel like it"))
    }

    /// The on-device failure this pins: a 2B model asked for a 1-hour reminder emitted `now + 1 hour`,
    /// the tool rejected it, and the model gave up. The parser now speaks the relative grammar small
    /// models actually produce, in English and Chinese, with a deterministic injected `now`.
    func testRelativeDateParsing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func delta(_ raw: String) -> TimeInterval? {
            ISO8601Parsing.date(from: raw, now: now).map { $0.timeIntervalSince(now) }
        }
        XCTAssertEqual(delta("now"), 0)
        XCTAssertEqual(delta("now + 1 hour"), 3600)
        XCTAssertEqual(delta("Now+30min"), 1800)
        XCTAssertEqual(delta("now - 15 minutes"), -900)
        XCTAssertEqual(delta("in 90 seconds"), 90)
        XCTAssertEqual(delta("2 hours from now"), 7200)
        XCTAssertEqual(delta("1小时后"), 3600)
        XCTAssertEqual(delta("30分钟后"), 1800)
        XCTAssertEqual(delta("2天后"), 172_800)

        // "tomorrow 09:00" lands on the next calendar day at 09:00 local.
        let tomorrow = ISO8601Parsing.date(from: "tomorrow 09:00", now: now)
        XCTAssertNotNil(tomorrow)
        if let d = tomorrow {
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            XCTAssertEqual(c.hour, 9); XCTAssertEqual(c.minute, 0)
            XCTAssertGreaterThan(d, now)
        }
        XCTAssertNotNil(ISO8601Parsing.date(from: "明天 9:30", now: now))
        XCTAssertNotNil(ISO8601Parsing.date(from: "后天", now: now))
    }

    /// End-to-end: the reminder tool accepts the exact string the device model emitted.
    func testCreateReminderAcceptsRelativeDue() async {
        let store = FakeEventStore()
        let tool = CreateReminderTool(store: store)
        let out = await tool.execute(argumentsJSON: #"{"title":"闹钟提醒","due":"now + 1 hour"}"#)
        XCTAssertFalse(out.hasPrefix("Error"), "relative due must parse, got: \(out)")
        let created = await store.createdReminders
        XCTAssertEqual(created.count, 1)
        if let due = created.first?.due {
            XCTAssertEqual(due.timeIntervalSinceNow, 3600, accuracy: 30)
        } else {
            XCTFail("due missing")
        }
    }
}

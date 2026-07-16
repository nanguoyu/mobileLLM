// SPDX-License-Identifier: MIT

import Foundation
import AppRuntime
@testable import LLMCore

// Shared in-memory fakes for the injectable tool seams, so the memory / calendar / location / assembly
// tests drive the tools without touching disk, EventKit, or CoreLocation (no permission prompts).

/// A `MemoryStoring` backed by an array. Insertion order preserved; no persistence. `search` is left to
/// the protocol's default (rank over `list()`), which is what the real store does too.
actor FakeMemoryStore: MemoryStoring {
    private(set) var facts: [MemoryFact]
    init(_ seed: [MemoryFact] = []) { facts = seed }

    @discardableResult func save(_ text: String, source: MemoryFact.Source) -> MemoryFact {
        let fact = MemoryFact(text: text.trimmingCharacters(in: .whitespacesAndNewlines), source: source)
        facts.append(fact)
        return fact
    }
    func list() -> [MemoryFact] { facts }
    func update(id: String, text: String) {
        guard let i = facts.firstIndex(where: { $0.id == id }) else { return }
        let old = facts[i]
        facts[i] = MemoryFact(id: old.id, text: text, createdAt: old.createdAt, source: old.source)
    }
    func delete(id: String) { facts.removeAll { $0.id == id } }
    func deleteAll() { facts.removeAll() }
}

/// An `EventStoring` that records drafts and can simulate access denial. Reads happen via actor awaits.
actor FakeEventStore: EventStoring {
    private(set) var createdEvents: [CalendarEventDraft] = []
    private(set) var createdReminders: [ReminderDraft] = []
    private(set) var lastDaysAhead: Int?
    private let toReturn: [CalendarEventInfo]
    private let denyCalendar: Bool
    private let denyReminders: Bool

    init(events: [CalendarEventInfo] = [], denyCalendar: Bool = false, denyReminders: Bool = false) {
        toReturn = events; self.denyCalendar = denyCalendar; self.denyReminders = denyReminders
    }

    func createEvent(_ draft: CalendarEventDraft) throws -> String {
        if denyCalendar { throw EventStoreError.calendarAccessDenied }
        createdEvents.append(draft); return draft.title
    }
    func events(daysAhead: Int) throws -> [CalendarEventInfo] {
        if denyCalendar { throw EventStoreError.calendarAccessDenied }
        lastDaysAhead = daysAhead; return toReturn
    }
    func createReminder(_ draft: ReminderDraft) throws -> String {
        if denyReminders { throw EventStoreError.reminderAccessDenied }
        createdReminders.append(draft); return draft.title
    }
}

/// A `LocationProviding` that returns a canned result.
struct FakeLocationProvider: LocationProviding {
    let result: Result<LocationFix, LocationError>
    func currentLocation() async throws -> LocationFix { try result.get() }
}

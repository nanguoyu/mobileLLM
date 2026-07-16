// SPDX-License-Identifier: MIT

import Foundation
import Observation
import AppRuntime

/// The @MainActor state owner for what the assistant remembers about you. Mirrors `AppRuntime.MemoryStore`
/// — the durable actor behind the `remember` / `recall` tools — into an observable list that the memory
/// screen renders and `ChatStore` reads *synchronously* while composing a turn's system prompt (the
/// injector and the context meter both run where there is nowhere to await a store read).
///
/// Two writers share one store: this book (what the user types on the memory screen) and the tools (what
/// the model saves mid-answer, straight to the actor — a tool call runs in the agent loop and must not hop
/// through the UI). So the mirror is re-read rather than assumed: `refresh()` runs at launch, before every
/// send, and whenever the screen appears. It's cheap — the store serves its cache, so this costs one actor
/// hop, not a disk read.
@MainActor
@Observable
public final class MemoryBook {

    /// Every saved fact, newest first — the order the management list shows. `internal(set)` so previews
    /// can seed it without disk I/O; the app mutates through the methods below.
    public internal(set) var facts: [MemoryFact] = []

    /// The durable seam. Exposed because `ChatStore` hands it to the `remember` / `recall` tools: they run
    /// off the main actor inside the agent loop, and both paths must reach the SAME store or the model and
    /// the memory screen would disagree about what is saved.
    public let store: any MemoryStoring

    public init(store: any MemoryStoring) { self.store = store }

    public var count: Int { facts.count }
    public var isEmpty: Bool { facts.isEmpty }
    /// How many the user wrote themselves (the rest are the model's) — the settings row's summary.
    public var userAuthoredCount: Int { facts.count { $0.source == .user } }

    /// Re-read the store into the mirror. Idempotent, and the only way a fact the MODEL saved becomes
    /// visible to the screen and to the next turn's prompt.
    public func refresh() async {
        facts = Self.newestFirst(await store.list())
    }

    /// Save a fact the user typed. Tagged `.user`, so the screen can show it as theirs rather than
    /// implying the model noticed it. Blank text is ignored.
    public func add(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await store.save(trimmed, source: .user)
        await refresh()
    }

    /// Correct a fact's text in place (the inline editor). Keeps its id, date, and source — see
    /// `MemoryStore.update`.
    public func update(id: String, text: String) async {
        await store.update(id: id, text: text)
        await refresh()
    }

    public func delete(id: String) async {
        await store.delete(id: id)
        await refresh()
    }

    /// Forget everything (the confirmed "Forget everything" action).
    public func deleteAll() async {
        await store.deleteAll()
        await refresh()
    }

    /// The store keeps insertion order (oldest first); the UI wants the freshest note on top.
    static func newestFirst(_ facts: [MemoryFact]) -> [MemoryFact] {
        facts.sorted { $0.createdAt > $1.createdAt }
    }
}

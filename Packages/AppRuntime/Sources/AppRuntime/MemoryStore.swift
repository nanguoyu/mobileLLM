// SPDX-License-Identifier: MIT

import Foundation

/// One fact/preference the assistant has been asked to remember across turns and launches. `id` is a
/// stable UUID string the UI can use as a list identity + delete key; `createdAt` drives newest-first
/// recall ranking so the freshest note wins a tie.
public struct MemoryFact: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let text: String
    public let createdAt: Date
    public init(id: String = UUID().uuidString, text: String, createdAt: Date = Date()) {
        self.id = id; self.text = text; self.createdAt = createdAt
    }
}

/// The persistence seam the memory tools (`remember` / `recall`) talk to — injected so the tools stay
/// unit-testable with a fake and the UI can later swap the backing store. `list` returns every saved fact
/// (insertion order, oldest first); ranking/limiting is the tool's job, so a management UI and the recall
/// tool observe the same raw set.
public protocol MemoryStoring: Sendable {
    @discardableResult func save(_ text: String) async -> MemoryFact
    func list() async -> [MemoryFact]
    func delete(id: String) async
}

/// A durable, atomic memory store on top of `DurableStore<MemoryFact>` — the same crash-safe,
/// corruption-resistant record store that backs conversations (losing a user's saved facts is annoying, so
/// it inherits the back-up-not-wipe posture). Facts persist under an injected file URL (tests) or
/// Application Support (the app). Saved text is whitespace-trimmed; the tool guards against blank input.
public actor MemoryStore: MemoryStoring {
    private let store: DurableStore<MemoryFact>
    private var cache: [MemoryFact]?

    /// Persist at an explicit file URL (tests pass a temp path).
    public init(fileURL: URL) { store = DurableStore<MemoryFact>(fileURL: fileURL) }

    /// Persist at `<Application Support>/<name>` (the app default).
    public init(applicationSupportFilename name: String = "memory.json") {
        store = DurableStore<MemoryFact>(applicationSupportFilename: name)
    }

    /// Every saved fact in insertion order (oldest first). Read from disk once, then served from cache.
    public func list() async -> [MemoryFact] {
        if let cache { return cache }
        let loaded = await store.load()
        cache = loaded
        return loaded
    }

    @discardableResult
    public func save(_ text: String) async -> MemoryFact {
        let fact = MemoryFact(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        var facts = await list()
        facts.append(fact)
        cache = facts
        try? await store.save(facts)
        return fact
    }

    public func delete(id: String) async {
        var facts = await list()
        facts.removeAll { $0.id == id }
        cache = facts
        try? await store.save(facts)
    }
}

// SPDX-License-Identifier: MIT

import Foundation

/// One fact/preference the assistant has been asked to remember across turns and launches. `id` is a
/// stable UUID string the UI can use as a list identity + delete key; `createdAt` drives newest-first
/// recall ranking so the freshest note wins a tie.
public struct MemoryFact: Codable, Sendable, Hashable, Identifiable {

    /// Where the fact came from: the model calling `remember` mid-conversation, or the user typing it into
    /// the memory screen. The management UI labels the two differently — you can't fairly judge a note you
    /// don't recognize without knowing who wrote it.
    public enum Source: String, Codable, Sendable, Hashable {
        case model
        case user
    }

    public let id: String
    public let text: String
    public let createdAt: Date
    public let source: Source

    public init(id: String = UUID().uuidString, text: String, createdAt: Date = Date(),
                source: Source = .model) {
        self.id = id; self.text = text; self.createdAt = createdAt; self.source = source
    }

    private enum CodingKeys: String, CodingKey { case id, text, createdAt, source }

    /// Facts written before `source` existed decode as `.model` — the tool was the only writer then, so
    /// that's the truth. Hand-rolled because the synthesized decoder would reject those records outright
    /// and `DurableStore` drops a record it can't decode: a stock upgrade would silently forget everything
    /// the user had already saved.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .model
    }
}

/// Ranks saved facts against a query. Shared by `MemoryStore.search`, the `recall` tool, and the prompt's
/// auto-injected memory block, so all three agree on what "most relevant" means (it began as one
/// tool-private function; the store and the injector need the same answer, not a lookalike).
public enum MemoryRanking {

    /// A fact scores by how many query tokens it contains (case-insensitive substring), ties broken
    /// newest-first, capped at `limit`. A blank query returns the most recent facts. Pure + unit-tested.
    /// (Deliberately simple: no stemming or fuzzy matching.)
    public static func rank(_ facts: [MemoryFact], query: String, limit: Int) -> [MemoryFact] {
        let byRecency = facts.sorted { $0.createdAt > $1.createdAt }
        let tokens = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !tokens.isEmpty else { return Array(byRecency.prefix(limit)) }
        let scored: [(fact: MemoryFact, score: Int)] = byRecency.compactMap { fact in
            let hay = fact.text.lowercased()
            let score = tokens.reduce(0) { $0 + (hay.contains($1) ? 1 : 0) }
            return score > 0 ? (fact, score) : nil
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.fact.createdAt > $1.fact.createdAt }
            .prefix(limit)
            .map(\.fact)
    }
}

/// The persistence seam the memory tools (`remember` / `recall`) and the management UI talk to — injected
/// so the tools stay unit-testable with a fake. `list` returns every saved fact (insertion order, oldest
/// first), so the UI and the tools observe the same raw set; `search` is the ranked view the `recall` tool
/// and the prompt injector share.
public protocol MemoryStoring: Sendable {
    @discardableResult func save(_ text: String, source: MemoryFact.Source) async -> MemoryFact
    func list() async -> [MemoryFact]
    /// Rewrite a fact's text in place, keeping its id, date, and source. No-op for an unknown id.
    func update(id: String, text: String) async
    func delete(id: String) async
    func deleteAll() async
    /// The best matches for `query`, most relevant first, capped at `limit`.
    func search(_ query: String, limit: Int) async -> [MemoryFact]
}

public extension MemoryStoring {
    /// Ranking over the full list — correct for any store, so a conformer only has to be able to `list()`.
    /// `MemoryStore` overrides it to rank its own cache without the extra hop.
    func search(_ query: String, limit: Int) async -> [MemoryFact] {
        MemoryRanking.rank(await list(), query: query, limit: max(1, limit))
    }
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

    /// The best matches for `query` (see `MemoryRanking`), served from the cache — the prompt injector
    /// searches on every send, and that must cost an actor hop, not a disk read.
    public func search(_ query: String, limit: Int) async -> [MemoryFact] {
        MemoryRanking.rank(await list(), query: query, limit: max(1, limit))
    }

    @discardableResult
    public func save(_ text: String, source: MemoryFact.Source = .model) async -> MemoryFact {
        let fact = MemoryFact(text: text.trimmingCharacters(in: .whitespacesAndNewlines), source: source)
        var facts = await list()
        facts.append(fact)
        await persist(facts)
        return fact
    }

    /// Rewrite a fact's text in place. Id, creation date, and source survive: an edit corrects a note
    /// rather than replacing it, so the list doesn't reshuffle under the user's cursor and provenance
    /// stays honest. Blank text is ignored — the store's own guard, independent of the UI's disabled Save.
    public func update(id: String, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var facts = await list()
        guard !trimmed.isEmpty, let i = facts.firstIndex(where: { $0.id == id }) else { return }
        let old = facts[i]
        facts[i] = MemoryFact(id: old.id, text: trimmed, createdAt: old.createdAt, source: old.source)
        await persist(facts)
    }

    public func delete(id: String) async {
        var facts = await list()
        facts.removeAll { $0.id == id }
        await persist(facts)
    }

    /// Forget everything. Writes an empty manifest instead of removing the file, so the store stays valid
    /// (and a half-deleted file can't read back as "unreadable" and get backed up as corrupt).
    public func deleteAll() async {
        await persist([])
    }

    private func persist(_ facts: [MemoryFact]) async {
        cache = facts
        try? await store.save(facts)
    }
}

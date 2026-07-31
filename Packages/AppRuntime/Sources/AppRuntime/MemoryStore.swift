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
    /// The user's own words for this fact, kept ONLY so the ranker can find it again.
    ///
    /// Notes are stored canonically in English (one vocabulary for every model and conversation, and it
    /// measurably improves what a 2B model saves: 9/10 vs 7/10 on `llama-smoke --memory-eval`). But
    /// retrieval is word overlap, and an English note scores ZERO against a Chinese question — measured
    /// 0/7 on a realistic store, which silently demoted memory to "the five most recent notes" for anyone
    /// not asking in English. Keeping the original phrasing as a search alias takes both wins: the model
    /// still reads one canonical English note, and the user's own words are what the query matches.
    /// Never shown and never sent to the model — `MemoryView` and the prompt block both render `text`.
    public let sourceText: String?

    public init(id: String = UUID().uuidString, text: String, createdAt: Date = Date(),
                source: Source = .model, sourceText: String? = nil) {
        self.id = id; self.text = text; self.createdAt = createdAt; self.source = source
        // A verbatim copy adds nothing to score and doubles the record; only a genuinely different
        // phrasing (i.e. a translated note) is worth keeping.
        self.sourceText = sourceText.flatMap { $0 == text ? nil : $0 }
    }

    private enum CodingKeys: String, CodingKey { case id, text, createdAt, source, sourceText }

    /// Facts written before `source` existed decode as `.model` — the tool was the only writer then, so
    /// that's the truth. Hand-rolled because the synthesized decoder would reject those records outright
    /// and `DurableStore` drops a record it can't decode: a stock upgrade would silently forget everything
    /// the user had already saved. `sourceText` is decoded the same forgiving way, so notes saved before
    /// the alias existed simply rank on their English text as they do today.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .model
        sourceText = try c.decodeIfPresent(String.self, forKey: .sourceText)
    }
}

/// Ranks saved facts against a query. Shared by `MemoryStore.search`, the `recall` tool, and the prompt's
/// auto-injected memory block, so all three agree on what "most relevant" means (it began as one
/// tool-private function; the store and the injector need the same answer, not a lookalike).
public enum MemoryRanking {

    /// Split a query into words. Uses Foundation's ICU word segmentation rather than splitting on
    /// non-alphanumerics, because that rule cannot see a word boundary in a language without spaces: every
    /// CJK character is `isLetter`, so "我叫什么名字" came out as ONE token and `contains` it against a saved
    /// fact was never true. Chinese queries therefore scored 0 against every fact and the injected memory
    /// block was always nil — memory looked dead in Chinese while working in English. ICU segments it to
    /// ["我","叫","什么","名字"], and "名字" matches.
    ///
    /// `.byWords` without `.localized` on purpose: this ranker is shared by the store, the `recall` tool and
    /// the injector, so it must give the same answer regardless of the device's locale (and its tests must
    /// be stable). Verified to segment zh / ja / mixed CJK+Latin identically either way.
    static func tokenize(_ query: String) -> [String] {
        var tokens: [String] = []
        query.enumerateSubstrings(in: query.startIndex..<query.endIndex, options: .byWords) { word, _, _, _ in
            if let w = word?.lowercased(), !w.isEmpty { tokens.append(w) }
        }
        return tokens
    }

    /// A fact scores by how many query tokens it contains (case-insensitive substring), ties broken
    /// newest-first, capped at `limit`. A blank query returns the most recent facts. Pure + unit-tested.
    /// (Deliberately simple: no stemming or fuzzy matching.)
    ///
    /// Both the canonical English note AND the user's original phrasing (`sourceText`) are searched, which
    /// is what makes a Chinese question find a note stored in English. Scoring the two separately and
    /// taking the better of them — rather than concatenating — keeps a bilingual record from outscoring a
    /// single-language one just for having more text to match against.
    public static func rank(_ facts: [MemoryFact], query: String, limit: Int) -> [MemoryFact] {
        let byRecency = facts.sorted { $0.createdAt > $1.createdAt }
        let tokens = tokenize(query)
        guard !tokens.isEmpty else { return Array(byRecency.prefix(limit)) }
        func score(_ haystack: String) -> Int {
            let hay = haystack.lowercased()
            return tokens.reduce(0) { $0 + (hay.contains($1) ? 1 : 0) }
        }
        let scored: [(fact: MemoryFact, score: Int)] = byRecency.compactMap { fact in
            let score = max(score(fact.text), fact.sourceText.map(score) ?? 0)
            return score > 0 ? (fact, score) : nil
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.fact.createdAt > $1.fact.createdAt }
            .prefix(limit)
            .map(\.fact)
    }
}

/// One canonical equivalence key for durable memory facts. Keeping this beside `MemoryStoring` makes
/// duplicate detection a store transaction instead of a tool-side `list()` followed by a separate
/// `save()` — that split can race when two generations remember the same fact at once.
public enum MemoryDeduplication {
    /// Case, compatibility forms, whitespace, and punctuation do not make a new durable fact.
    public static func key(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var words: [String] = []
        folded.enumerateSubstrings(in: folded.startIndex..<folded.endIndex, options: .byWords) {
            word, _, _, _ in
            if let word, !word.isEmpty { words.append(word) }
        }
        return words.joined(separator: " ")
    }
}

/// The result of the atomic remember-if-new transaction. Returning the existing fact lets callers report
/// a duplicate without a second read (which would reopen the race the transaction is meant to close).
public enum MemorySaveResult: Sendable, Hashable {
    case saved(MemoryFact)
    case duplicate(MemoryFact)
}

/// The persistence seam the memory tools (`remember` / `recall`) and the management UI talk to — injected
/// so the tools stay unit-testable with a fake. `list` returns every saved fact (insertion order, oldest
/// first), so the UI and the tools observe the same raw set; `search` is the ranked view the `recall` tool
/// and the prompt injector share.
public protocol MemoryStoring: Sendable {
    @discardableResult func save(_ text: String, source: MemoryFact.Source) async throws -> MemoryFact
    /// Atomically compare the normalized text against every fact and save only when it is new.
    @discardableResult
    func saveIfAbsent(_ text: String, source: MemoryFact.Source) async throws -> MemorySaveResult
    func list() async -> [MemoryFact]
    /// Rewrite a fact's text in place, keeping its id, date, and source. No-op for an unknown id.
    func update(id: String, text: String) async throws
    func delete(id: String) async throws
    func deleteAll() async throws
    /// The best matches for `query`, most relevant first, capped at `limit`.
    func search(_ query: String, limit: Int) async -> [MemoryFact]
}

public struct MemoryDataDeletionError: LocalizedError, Sendable {
    public let failures: [String]
    public var errorDescription: String? {
        "Some memory data could not be removed:\n" + failures.joined(separator: "\n")
    }
}

public extension MemoryStoring {
    /// Ranking over the full list — correct for any store, so a conformer only has to be able to `list()`.
    /// `MemoryStore` overrides it to rank its own cache without the extra hop.
    func search(_ query: String, limit: Int) async -> [MemoryFact] {
        MemoryRanking.rank(await list(), query: query, limit: max(1, limit))
    }

    /// Save with the user's original phrasing attached as a search alias. Defaulted here rather than added
    /// to the protocol so every existing conformer (the test fakes especially) keeps compiling; a store
    /// that doesn't retain aliases simply drops it, which costs only cross-language ranking.
    @discardableResult
    func saveIfAbsent(_ text: String, source: MemoryFact.Source,
                      sourceText: String?) async throws -> MemorySaveResult {
        try await saveIfAbsent(text, source: source)
    }
}

/// A durable, atomic memory store on top of `DurableStore<MemoryFact>` — the same crash-safe,
/// corruption-resistant record store that backs conversations (losing a user's saved facts is annoying, so
/// it inherits the back-up-not-wipe posture). Facts persist under an injected file URL (tests) or
/// Application Support (the app). Saved text is whitespace-trimmed; the tool guards against blank input.
public actor MemoryStore: MemoryStoring {
    private let store: DurableStore<MemoryFact>
    private var cache: [MemoryFact]?
    private var initialLoad: Task<[MemoryFact], Never>?

    // Actor methods are re-entrant at every `await`. The durable store is a separate actor, so a plain
    // read-modify-save sequence is not exclusive: two saves can both read the same snapshot and the later
    // write drops one fact. This explicit lane remains owned while the durable write is suspended.
    private var mutationActive = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    // Internal deterministic interleaving hooks used only by the concurrency tests. Production
    // initializers leave them nil, so they add no work to the app's mutation path.
    private let mutationRequested: (@Sendable () async -> Void)?
    private let beforePersist: (@Sendable () async throws -> Void)?
    private let afterInitialLoad: (@Sendable () async -> Void)?

    /// Persist at an explicit file URL (tests pass a temp path).
    public init(fileURL: URL) {
        store = DurableStore<MemoryFact>(fileURL: fileURL)
        mutationRequested = nil
        beforePersist = nil
        afterInitialLoad = nil
    }

    init(fileURL: URL,
         mutationRequested: (@Sendable () async -> Void)?,
         beforePersist: (@Sendable () async throws -> Void)?,
         afterInitialLoad: (@Sendable () async -> Void)?) {
        store = DurableStore<MemoryFact>(fileURL: fileURL)
        self.mutationRequested = mutationRequested
        self.beforePersist = beforePersist
        self.afterInitialLoad = afterInitialLoad
    }

    /// Persist at `<Application Support>/<name>` (the app default).
    public init(applicationSupportFilename name: String = "memory.json") {
        store = DurableStore<MemoryFact>(applicationSupportFilename: name)
        mutationRequested = nil
        beforePersist = nil
        afterInitialLoad = nil
    }

    /// Every saved fact in insertion order (oldest first). Read from disk once, then served from cache.
    public func list() async -> [MemoryFact] {
        if let cache { return cache }
        if initialLoad == nil {
            let durableStore = store
            let loadHook = afterInitialLoad
            initialLoad = Task {
                let loaded = await durableStore.load()
                if let loadHook { await loadHook() }
                return loaded
            }
        }
        let loaded = await initialLoad!.value
        // A delete/save may have committed while the disk load was suspended. Its published cache is the
        // newer linearized state; never overwrite it with the stale load snapshot.
        if cache == nil { cache = loaded }
        return cache ?? loaded
    }

    /// The best matches for `query` (see `MemoryRanking`), served from the cache — the prompt injector
    /// searches on every send, and that must cost an actor hop, not a disk read.
    public func search(_ query: String, limit: Int) async -> [MemoryFact] {
        MemoryRanking.rank(await list(), query: query, limit: max(1, limit))
    }

    @discardableResult
    public func save(_ text: String, source: MemoryFact.Source = .model) async throws -> MemoryFact {
        if let mutationRequested { await mutationRequested() }
        await acquireMutationLane()
        defer { releaseMutationLane() }

        let fact = MemoryFact(text: text.trimmingCharacters(in: .whitespacesAndNewlines), source: source)
        var facts = await list()
        facts.append(fact)
        try await persist(facts)
        return fact
    }

    @discardableResult
    public func saveIfAbsent(_ text: String,
                             source: MemoryFact.Source = .model) async throws -> MemorySaveResult {
        try await saveIfAbsent(text, source: source, sourceText: nil)
    }

    /// `sourceText` is the user's own phrasing, kept only so the ranker can match a question asked in the
    /// language the fact was originally stated in — see `MemoryFact.sourceText`. Dedup still keys on the
    /// canonical text alone, so the same fact restated in another language does not create a second note.
    public func saveIfAbsent(_ text: String, source: MemoryFact.Source = .model,
                             sourceText: String?) async throws -> MemorySaveResult {
        if let mutationRequested { await mutationRequested() }
        await acquireMutationLane()
        defer { releaseMutationLane() }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = MemoryDeduplication.key(trimmed)
        var facts = await list()
        if let existing = facts.first(where: { MemoryDeduplication.key($0.text) == key }) {
            return .duplicate(existing)
        }
        let fact = MemoryFact(text: trimmed, source: source,
                              sourceText: sourceText?.trimmingCharacters(in: .whitespacesAndNewlines))
        facts.append(fact)
        try await persist(facts)
        return .saved(fact)
    }

    /// Rewrite a fact's text in place. Id, creation date, and source survive: an edit corrects a note
    /// rather than replacing it, so the list doesn't reshuffle under the user's cursor and provenance
    /// stays honest. Blank text is ignored — the store's own guard, independent of the UI's disabled Save.
    public func update(id: String, text: String) async throws {
        if let mutationRequested { await mutationRequested() }
        await acquireMutationLane()
        defer { releaseMutationLane() }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var facts = await list()
        guard !trimmed.isEmpty, let i = facts.firstIndex(where: { $0.id == id }) else { return }
        let old = facts[i]
        facts[i] = MemoryFact(id: old.id, text: trimmed, createdAt: old.createdAt, source: old.source)
        try await persist(facts)
    }

    public func delete(id: String) async throws {
        if let mutationRequested { await mutationRequested() }
        await acquireMutationLane()
        defer { releaseMutationLane() }

        var facts = await list()
        facts.removeAll { $0.id == id }
        try await persist(facts)
    }

    /// Forget everything. Writes an empty manifest instead of removing the file, so the store stays valid
    /// (and a half-deleted file can't read back as "unreadable" and get backed up as corrupt).
    public func deleteAll() async throws {
        if let mutationRequested { await mutationRequested() }
        await acquireMutationLane()
        defer { releaseMutationLane() }

        try await persist([])
        // A prior recovery backup can contain the very facts the user asked to forget. Remove only the two
        // sibling artifacts DurableStore itself owns, and surface any failure instead of claiming erasure.
        let manifestURL = store.fileURL
        let backupURL = await store.corruptBackupURL
        var failures: [String] = []
        for url in [backupURL, manifestURL.appendingPathExtension("tmp")] {
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        if !failures.isEmpty { throw MemoryDataDeletionError(failures: failures) }
    }

    /// Publish the new cache only after the atomic write lands. A failed write therefore leaves both the
    /// caller and subsequent reads looking at the last durable state instead of a fact that will disappear
    /// on relaunch.
    private func persist(_ facts: [MemoryFact]) async throws {
        if let beforePersist { try await beforePersist() }
        try await store.save(facts)
        cache = facts
    }

    private func acquireMutationLane() async {
        if !mutationActive {
            mutationActive = true
            return
        }
        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    private func releaseMutationLane() {
        guard !mutationWaiters.isEmpty else {
            mutationActive = false
            return
        }
        mutationWaiters.removeFirst().resume()
    }
}

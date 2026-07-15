// SPDX-License-Identifier: MIT

import Foundation
import AppRuntime

/// Durable chat persistence (DESIGN §2.4): one `conversation-<uuid>.json` record per thread plus a
/// lightweight `index.json` for fast list rendering. Both are `DurableStore`s so every write is
/// atomic and a corrupt manifest is backed up (never wiped) rather than losing a long chat. Being an
/// actor makes it the single writer (critique G1).
///
/// Soft-delete is a tombstone on the index entry — the conversation file is kept so a delete can be
/// undone; `hardDelete` (used by "Delete all data") removes the file for good.
public actor ConversationStore {

    private let directory: URL
    /// The index is one file holding every thread's light projection.
    private let index: DurableStore<ConversationIndexEntry>

    /// Store under an explicit directory (tests pass a temp dir; the app passes Application Support).
    public init(directory: URL) {
        self.directory = directory
        self.index = DurableStore(fileURL: directory.appending(component: "index.json"), version: 1)
    }

    /// Default app location: `<Application Support>/mobileLLM/Conversations`.
    public init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appending(component: "mobileLLM").appending(component: "Conversations")
        self.init(directory: dir)
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appending(component: "conversation-\(id.uuidString).json")
    }

    private func recordStore(for id: UUID) -> DurableStore<Conversation> {
        DurableStore(fileURL: fileURL(for: id), version: 1)
    }

    // MARK: - Index

    /// The live (non-tombstoned) index entries, newest first, pinned on top — for list rendering.
    public func liveIndex() async -> [ConversationIndexEntry] {
        await index.load()
            .filter { !$0.isDeleted }
            .sorted { a, b in
                if a.pinned != b.pinned { return a.pinned }
                return a.updatedAt > b.updatedAt
            }
    }

    /// The full index, including tombstones (for consistency checks / recovery).
    public func allIndex() async -> [ConversationIndexEntry] { await index.load() }

    private func writeIndex(_ entries: [ConversationIndexEntry]) async throws {
        try await index.save(entries)
    }

    private func upsertIndex(_ entry: ConversationIndexEntry) async throws {
        var entries = await index.load()
        if let i = entries.firstIndex(where: { $0.id == entry.id }) {
            // Preserve any tombstone unless the caller is explicitly reviving it.
            var merged = entry
            merged.deletedAt = entry.deletedAt ?? entries[i].deletedAt
            entries[i] = merged
        } else {
            entries.append(entry)
        }
        try await writeIndex(entries)
    }

    // MARK: - CRUD

    /// Load one full conversation (nil if missing or tombstoned-and-gone).
    public func load(_ id: UUID) async -> Conversation? {
        await recordStore(for: id).load().first
    }

    /// Load every live conversation, newest first. Bad/missing records are skipped (DurableStore
    /// drops undecodable elements), so one corrupt thread never blocks the rest.
    public func loadAllLive() async -> [Conversation] {
        var result: [Conversation] = []
        for entry in await liveIndex() {
            if let conversation = await load(entry.id) { result.append(conversation) }
        }
        return result
    }

    /// Atomically persist a conversation and refresh its index entry (single-writer autosave path).
    public func save(_ conversation: Conversation) async throws {
        try await recordStore(for: conversation.id).save([conversation])
        try await upsertIndex(conversation.indexEntry)
    }

    /// Soft-delete: tombstone the index entry, keeping the file so the delete can be undone.
    public func softDelete(_ id: UUID) async throws {
        var entries = await index.load()
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].deletedAt = Date()
        try await writeIndex(entries)
    }

    /// Undo a soft-delete: clear the tombstone. The full record was never removed.
    public func restore(_ id: UUID) async throws {
        var entries = await index.load()
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].deletedAt = nil
        try await writeIndex(entries)
    }

    /// Permanently remove a conversation's file and index entry (irreversible — used by "Delete all").
    public func hardDelete(_ id: UUID) async throws {
        var entries = await index.load()
        entries.removeAll { $0.id == id }
        try await writeIndex(entries)
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    /// Remove every conversation + index (Settings → Delete all data).
    public func deleteAll() async throws {
        for entry in await index.load() {
            try? FileManager.default.removeItem(at: fileURL(for: entry.id))
        }
        try await writeIndex([])
    }

    // MARK: - Search

    /// Full-text search over titles + message bodies, newest first (DESIGN §4). Empty query → live
    /// index. Titles match from the index alone; body matches load the thread's messages.
    public func search(_ query: String) async -> [ConversationIndexEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return await liveIndex() }
        var hits: [ConversationIndexEntry] = []
        for entry in await liveIndex() {
            if entry.title.lowercased().contains(needle) { hits.append(entry); continue }
            if let conversation = await load(entry.id),
               conversation.messages.contains(where: {
                   $0.answer.lowercased().contains(needle)
                       || ($0.reasoning?.lowercased().contains(needle) ?? false)
               }) {
                hits.append(entry)
            }
        }
        return hits
    }

    /// Total on-disk bytes used by conversation records (Settings → storage).
    public func storageBytes() async -> Int64 {
        var total: Int64 = 0
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) {
            for url in items {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        return total
    }
}

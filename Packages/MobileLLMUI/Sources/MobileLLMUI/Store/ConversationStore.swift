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

    /// The base directory holding the conversation records. Exposed (immutable → safe to read across the
    /// actor boundary) so a sibling on-device store can be placed *beside* it — e.g. the tool memory store.
    public nonisolated let directory: URL
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

    // MARK: - Attachments (image bytes stored as files, never inline in the conversation JSON)

    /// The directory holding attachment image files (`attachments/<uuid>.jpg`) beside the records.
    private var attachmentsDirectory: URL { directory.appending(component: "attachments") }

    private func attachmentURL(for id: UUID) -> URL {
        attachmentsDirectory.appending(component: "\(id.uuidString).jpg")
    }

    /// Persist one attachment's encoded (downscaled JPEG) bytes to disk, keyed by its `ImageRef.id`.
    /// Written before generation so history replay + follow-ups can reload it; kept out of the record
    /// JSON so a record load never drags multi-MB pixels through the decoder.
    public func writeAttachment(_ data: Data, id: UUID) throws {
        try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
        try data.write(to: attachmentURL(for: id), options: .atomic)
    }

    /// Load one attachment's bytes (nil if it was never written / already purged).
    public func attachmentData(_ id: UUID) -> Data? {
        try? Data(contentsOf: attachmentURL(for: id))
    }

    /// Remove the files backing a set of attachment refs. Best-effort — a missing file is already the
    /// desired state. Public because truncation flows (regenerate / edit-and-resend) drop image-bearing
    /// turns from LIVE threads and must purge their pixels too, not just hard-delete.
    public func removeAttachments(_ refs: [ImageRef]) {
        for ref in refs { try? FileManager.default.removeItem(at: attachmentURL(for: ref.id)) }
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

    /// Permanently remove a conversation's file, its attachment images, and its index entry (irreversible
    /// — used by "Delete all" and the tombstone sweep). Purging the attachment files with the thread is
    /// the privacy promise: a hard-deleted chat leaves no pixels behind.
    public func hardDelete(_ id: UUID) async throws {
        // Load the record first to find the attachment files to purge (before its JSON is removed).
        if let conversation = await load(id) {
            removeAttachments(conversation.messages.flatMap { $0.attachments ?? [] })
        }
        var entries = await index.load()
        entries.removeAll { $0.id == id }
        try await writeIndex(entries)
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    /// Hard-delete every tombstone whose deletion is older than `age` (the retention window) — the
    /// privacy promise that a soft-deleted chat doesn't linger on disk indefinitely. Returns the swept
    /// ids. `now` is injectable for tests. Live (non-tombstoned) threads are never touched.
    @discardableResult
    public func sweepExpiredTombstones(olderThan age: TimeInterval, now: Date = Date()) async -> [UUID] {
        var swept: [UUID] = []
        for entry in await index.load() {
            if let deletedAt = entry.deletedAt, now.timeIntervalSince(deletedAt) >= age {
                try? await hardDelete(entry.id)
                swept.append(entry.id)
            }
        }
        return swept
    }

    /// Remove every conversation + index + attachment image (Settings → Delete all data).
    public func deleteAll() async throws {
        for entry in await index.load() {
            try? FileManager.default.removeItem(at: fileURL(for: entry.id))
        }
        try? FileManager.default.removeItem(at: attachmentsDirectory)   // purge all attachment pixels
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

    /// Total on-disk bytes used by conversation records + their attachment images (Settings → storage).
    public func storageBytes() async -> Int64 {
        var total: Int64 = 0
        let fm = FileManager.default
        for dir in [directory, attachmentsDirectory] {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for url in items {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        return total
    }
}

// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A small durable, atomic, corruption-resistant record store — the recovery skeleton distilled from
/// a proven durable-store pattern, made generic. Backs `ConversationStore` / `ModelRegistryStore`
/// in the app layer (losing a long chat is worse than losing a regenerable image, so this keeps the
/// same defensive posture).
///
/// Guarantees:
///   • **Versioned Codable manifest** under Application Support (or any injected URL, for tests).
///   • **Atomic writes** (write a sibling `.tmp` → rename over the destination) so a crash mid-write
///     never leaves a half-written manifest.
///   • **Corrupt manifest → back-up-not-wipe**: an unreadable manifest is moved aside to
///     `<name>.corrupt` (never deleted), and load returns empty rather than crashing — the data is
///     preserved for forensic/manual recovery, and the next `save` rebuilds a clean file.
///   • **Bad-record skipping**: within a readable manifest, records that fail to decode are dropped
///     individually instead of failing the whole load.
public actor DurableStore<Record: Codable & Sendable> {

    /// The on-disk envelope: a schema version plus the record array (records are lossily decoded so a
    /// single bad element is skipped, not fatal).
    private struct Manifest: Codable {
        var version: Int
        var records: [Lossy]
    }

    /// Decodes to `nil` on per-element failure without derailing the surrounding array decode.
    private struct Lossy: Codable {
        let value: Record?
        init(value: Record?) { self.value = value }
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            value = try? c.decode(Record.self)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(value)
        }
    }

    public let fileURL: URL
    public let version: Int
    private let fm = FileManager.default

    /// Store at an explicit file URL. Tests pass a temp path; the app passes an Application Support URL.
    public init(fileURL: URL, version: Int = 1) {
        self.fileURL = fileURL
        self.version = version
    }

    /// Store at `<Application Support>/<name>` (creating the directory). Falls back to the temp
    /// directory if Application Support can't be resolved.
    public init(applicationSupportFilename name: String, version: Int = 1) {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        self.fileURL = base.appending(component: name)
        self.version = version
    }

    /// URL of the backup written when a corrupt manifest is recovered from.
    public var corruptBackupURL: URL { fileURL.appendingPathExtension("corrupt") }

    /// Load the records. Missing file → empty (first launch). Present-but-unreadable → back it up and
    /// return empty (never wipe). Readable → decoded records with any bad element skipped.
    public func load() -> [Record] {
        guard fm.fileExists(atPath: fileURL.path) else { return [] }  // genuinely empty
        do {
            let data = try Data(contentsOf: fileURL)
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            return manifest.records.compactMap(\.value)
        } catch {
            // The file is PRESENT but unreadable. Do NOT report empty and let a subsequent save
            // overwrite it — back the bad file up so the data survives for manual recovery.
            try? backupCorruptFile()
            return []
        }
    }

    /// Atomically persist `records` (temp → rename). Creates the parent directory if needed.
    public func save(_ records: [Record]) throws {
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let manifest = Manifest(version: version, records: records.map { Lossy(value: $0) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)

        // temp → rename: write a sibling then swap it in, so a reader never sees a partial file.
        let tmpURL = fileURL.appendingPathExtension("tmp")
        try data.write(to: tmpURL, options: .atomic)
        if fm.fileExists(atPath: fileURL.path) {
            _ = try fm.replaceItemAt(fileURL, withItemAt: tmpURL)
        } else {
            try fm.moveItem(at: tmpURL, to: fileURL)
        }
    }

    /// Move an undecodable manifest aside so the next save() rebuilds a clean one without overwriting
    /// the evidence (and without us mistaking it for "empty").
    private func backupCorruptFile() throws {
        let backup = corruptBackupURL
        if fm.fileExists(atPath: backup.path) { try? fm.removeItem(at: backup) }
        try fm.moveItem(at: fileURL, to: backup)
    }
}

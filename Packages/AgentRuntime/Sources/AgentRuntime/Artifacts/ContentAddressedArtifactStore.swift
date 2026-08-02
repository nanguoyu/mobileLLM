// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

/// Durable, content-addressed artifact storage. The actor is the single mutation boundary for one
/// root; a process-wide advisory file lock prevents a second store instance from using stale index
/// state.
public actor ContentAddressedArtifactStore {
    public nonisolated let configuration: ArtifactStoreConfiguration
    public nonisolated let rootURL: URL
    public nonisolated let startupCleanupReport: ArtifactCleanupReport

    private let fileSystem: ArtifactFileSystem
    private let clock: ArtifactStoreClock
    private let idGenerator: ArtifactStoreIDGenerator
    private let temporaryNameGenerator: ArtifactStoreTemporaryNameGenerator
    private let faultInjector: ArtifactStoreFaultInjector?
    private var index: ArtifactIndex

    public init(
        configuration: ArtifactStoreConfiguration,
        clock: @escaping ArtifactStoreClock = {
            (try? AgentTimestamp(Date())) ?? AgentTimestamp(rawValue: 0)
        },
        idGenerator: @escaping ArtifactStoreIDGenerator = { ArtifactID() },
        temporaryNameGenerator: @escaping ArtifactStoreTemporaryNameGenerator = {
            UUID().uuidString.lowercased()
        },
        faultInjector: ArtifactStoreFaultInjector? = nil
    ) throws {
        self.configuration = configuration
        self.clock = clock
        self.idGenerator = idGenerator
        self.temporaryNameGenerator = temporaryNameGenerator
        self.faultInjector = faultInjector

        let fileSystem = try ArtifactFileSystem(configuration: configuration)
        self.fileSystem = fileSystem
        rootURL = fileSystem.rootURL

        let loaded: ArtifactIndex
        if let encoded = try fileSystem.readIndex() {
            do {
                loaded = try JSONDecoder().decode(ArtifactIndex.self, from: encoded)
            } catch let error as ArtifactStoreError {
                throw error
            } catch {
                throw ArtifactStoreError.metadataCorrupt
            }
            guard loaded.version == ArtifactIndex.currentVersion else {
                throw ArtifactStoreError.unsupportedMetadataVersion(loaded.version)
            }
            try Self.validate(loaded, fileSystem: fileSystem)
        } else {
            loaded = .empty
            try Self.writeIndex(
                loaded,
                fileSystem: fileSystem,
                temporaryName: temporaryNameGenerator()
            )
        }

        let recovered = try Self.recover(
            loaded,
            fileSystem: fileSystem,
            temporaryNameGenerator: temporaryNameGenerator
        )
        index = recovered.index
        startupCleanupReport = recovered.report
    }

    /// Atomically publishes verified content before durably creating its reference.
    public func commit(_ request: ArtifactCommitRequest) throws -> ArtifactReference {
        let byteCount = UInt64(request.data.count)
        guard byteCount <= configuration.maximumArtifactBytes else {
            throw ArtifactStoreError.artifactTooLarge(
                limit: configuration.maximumArtifactBytes,
                actual: byteCount
            )
        }
        guard request.sensitivity != .secret else {
            throw ArtifactStoreError.secretContentProhibited
        }
        guard !ArtifactSecretDetector.containsProhibitedSecret(
            request.data,
            mimeType: request.mimeType
        ) else { throw ArtifactStoreError.secretContentProhibited }
        try Self.validateInitialOwner(request.initialOwner, for: request)

        let digest = StableDigest.sha256(request.data)
        if let expected = request.expectedDigest, expected != digest {
            throw ArtifactStoreError.expectedDigestMismatch
        }
        if let expected = request.expectedByteCount, expected != byteCount {
            throw ArtifactStoreError.expectedByteCountMismatch
        }

        let artifactID = request.artifactID ?? idGenerator()
        if let existing = index.record(for: artifactID) {
            guard Self.matches(existing, request: request, digest: digest, byteCount: byteCount),
                  existing.owners.contains(request.initialOwner)
            else { throw ArtifactStoreError.artifactIDCollision(artifactID) }
            return try verifiedReference(for: artifactID)
        }

        let locator = try fileSystem.locator(for: digest)
        let reference: ArtifactReference
        do {
            reference = try ArtifactReference(
                id: artifactID,
                contentDigest: digest,
                byteCount: byteCount,
                mimeType: request.mimeType,
                semanticType: request.semanticType,
                provenance: request.provenance,
                createdAt: clock(),
                retentionPolicy: request.retentionPolicy,
                locator: locator,
                sensitivity: request.sensitivity,
                integrityStatus: .verified
            )
        } catch {
            throw ArtifactStoreError.invalidArtifactMetadata
        }

        try inject(.beforeStagingWrite)
        let stagingURL = try fileSystem.stagingFileURL(name: temporaryNameGenerator())
        try fileSystem.writeExclusive(request.data, to: stagingURL)
        try inject(.afterStagingSync)
        _ = try fileSystem.publish(stagedURL: stagingURL, digest: digest, byteCount: byteCount)
        try inject(.afterObjectPublish)

        var candidate = index
        candidate.insert(ArtifactStoredRecord(reference: reference, owners: [request.initialOwner]))
        try commitIndex(candidate)
        return reference
    }

    /// Reads an artifact only after exact byte-count and SHA-256 verification.
    public func data(for artifactID: ArtifactID, maximumBytes: UInt64? = nil) throws -> Data {
        guard let record = index.record(for: artifactID) else {
            throw ArtifactStoreError.artifactNotFound(artifactID)
        }
        return try readAndUpdateIntegrity(record, maximumBytes: maximumBytes)
    }

    /// Rejects forged or stale metadata before reading the referenced body.
    public func data(
        for reference: ArtifactReference,
        maximumBytes: UInt64? = nil
    ) throws -> Data {
        guard let record = index.record(for: reference.id) else {
            throw ArtifactStoreError.artifactNotFound(reference.id)
        }
        guard Self.sameStableMetadata(record.reference, reference) else {
            throw ArtifactStoreError.staleReference(reference.id)
        }
        return try readAndUpdateIntegrity(record, maximumBytes: maximumBytes)
    }

    /// Rechecks bytes and returns newly persisted integrity metadata. Missing or corrupt content is
    /// represented in the returned reference rather than being mistaken for verified content.
    public func verify(_ artifactID: ArtifactID) throws -> ArtifactReference {
        guard let record = index.record(for: artifactID) else {
            throw ArtifactStoreError.artifactNotFound(artifactID)
        }
        do {
            _ = try readAndUpdateIntegrity(record, maximumBytes: nil)
            return index.record(for: artifactID)!.reference
        } catch ArtifactStoreError.missingContent {
            return index.record(for: artifactID)!.reference
        } catch ArtifactStoreError.integrityMismatch {
            return index.record(for: artifactID)!.reference
        }
    }

    /// Adds one durable owner idempotently.
    public func addReference(to artifactID: ArtifactID, owner: ArtifactOwner) throws {
        guard var record = index.record(for: artifactID) else {
            throw ArtifactStoreError.artifactNotFound(artifactID)
        }
        guard !record.owners.contains(owner) else { return }
        record.owners.append(owner)
        record.owners.sort()
        var candidate = index
        candidate.replace(record)
        try commitIndex(candidate)
    }

    /// Removes one durable owner idempotently and collects newly unowned non-user-managed data.
    @discardableResult
    public func removeReference(from artifactID: ArtifactID, owner: ArtifactOwner) throws -> Bool {
        guard var record = index.record(for: artifactID) else {
            throw ArtifactStoreError.artifactNotFound(artifactID)
        }
        guard let ownerIndex = record.owners.firstIndex(of: owner) else { return false }
        record.owners.remove(at: ownerIndex)

        var candidate = index
        var removedDigest: StableDigest?
        if record.owners.isEmpty, record.reference.retentionPolicy != .userManaged {
            candidate.remove(artifactID)
            if !candidate.contains(digest: record.reference.contentDigest) {
                removedDigest = record.reference.contentDigest
            }
        } else {
            candidate.replace(record)
        }
        try commitIndex(candidate)
        if let removedDigest { try removeObjectAfterMetadata(removedDigest) }
        return true
    }

    /// Removes an owner's references in one metadata transaction. Shared bytes remain until every
    /// durable record has released the same digest.
    public func deleteArtifactsOwned(by owner: ArtifactOwner) throws -> ArtifactCleanupReport {
        var candidate = index
        var removedIDs: [ArtifactID] = []
        for original in index.records {
            guard original.owners.contains(owner) else { continue }
            var record = original
            record.owners.removeAll { $0 == owner }
            if record.owners.isEmpty, record.reference.retentionPolicy != .userManaged {
                candidate.remove(record.reference.id)
                removedIDs.append(record.reference.id)
            } else {
                candidate.replace(record)
            }
        }
        guard !removedIDs.isEmpty || candidate != index else { return ArtifactCleanupReport() }
        let removedDigests = Self.unreferencedDigests(from: index, after: candidate)
        try commitIndex(candidate)
        for digest in removedDigests { try removeObjectAfterMetadata(digest) }
        return ArtifactCleanupReport(
            removedArtifactIDs: removedIDs,
            removedObjectDigests: removedDigests
        )
    }

    /// Deletes one unreferenced record. User-managed ownership can be released only by the explicit
    /// user-request path; unrelated durable references always block deletion.
    public func deleteArtifact(
        _ artifactID: ArtifactID,
        reason: ArtifactDeletionReason
    ) throws -> ArtifactCleanupReport {
        guard let record = index.record(for: artifactID) else {
            throw ArtifactStoreError.artifactNotFound(artifactID)
        }
        switch reason {
        case .garbageCollection:
            guard record.reference.retentionPolicy != .userManaged else {
                throw ArtifactStoreError.userManagedArtifactRequiresExplicitDeletion(artifactID)
            }
            guard record.owners.isEmpty else {
                throw ArtifactStoreError.artifactStillReferenced(artifactID)
            }
        case .explicitUserRequest:
            guard record.owners.allSatisfy({ $0.kind == .userManaged }) else {
                throw ArtifactStoreError.artifactStillReferenced(artifactID)
            }
        }

        var candidate = index
        candidate.remove(artifactID)
        let removeObject = !candidate.contains(digest: record.reference.contentDigest)
        try commitIndex(candidate)
        if removeObject { try removeObjectAfterMetadata(record.reference.contentDigest) }
        return ArtifactCleanupReport(
            removedArtifactIDs: [artifactID],
            removedObjectDigests: removeObject ? [record.reference.contentDigest] : []
        )
    }

    /// Deterministically removes abandoned staging/index files, impossible zero-owner records, and
    /// content objects with no metadata record.
    public func cleanupOrphans() throws -> ArtifactCleanupReport {
        let temporary = try fileSystem.cleanupTemporaryFiles()
        var candidate = index
        let impossibleRecords = candidate.records.filter {
            $0.owners.isEmpty && $0.reference.retentionPolicy != .userManaged
        }
        for record in impossibleRecords { candidate.remove(record.reference.id) }
        if candidate != index { try commitIndex(candidate) }

        let referenced = Set(candidate.records.map(\.reference.contentDigest))
        let orphaned = try fileSystem.allObjectDigests().subtracting(referenced)
            .sorted { $0.rawValue < $1.rawValue }
        for digest in orphaned { try removeObjectAfterMetadata(digest) }
        return ArtifactCleanupReport(
            removedArtifactIDs: impossibleRecords.map(\.reference.id),
            removedObjectDigests: orphaned,
            removedStagingFileCount: temporary.staging,
            removedMetadataTemporaryFileCount: temporary.metadata
        )
    }

    public func reference(for artifactID: ArtifactID) -> ArtifactReference? {
        index.record(for: artifactID)?.reference
    }

    public func owners(for artifactID: ArtifactID) throws -> [ArtifactOwner] {
        guard let record = index.record(for: artifactID) else {
            throw ArtifactStoreError.artifactNotFound(artifactID)
        }
        return record.owners
    }

    public func allReferences() -> [ArtifactReference] {
        index.records.map(\.reference)
    }

    public func snapshot() throws -> ArtifactStoreSnapshot {
        let objects = try fileSystem.allObjectDigests()
        return ArtifactStoreSnapshot(
            entries: index.records.map {
                .init(reference: $0.reference, owners: $0.owners)
            },
            physicalObjectCount: objects.count
        )
    }

    private func readAndUpdateIntegrity(
        _ record: ArtifactStoredRecord,
        maximumBytes: UInt64?
    ) throws -> Data {
        let reference = record.reference
        let readLimit = maximumBytes ?? reference.byteCount
        guard reference.byteCount <= readLimit else {
            throw ArtifactStoreError.artifactTooLarge(
                limit: readLimit,
                actual: reference.byteCount
            )
        }
        let url = try fileSystem.objectURL(for: reference.contentDigest, createParent: false)
        do {
            try inject(.beforeObjectRead)
            let data = try fileSystem.readVerifiedFile(
                at: url,
                expectedDigest: reference.contentDigest,
                expectedByteCount: reference.byteCount,
                maximumBytes: readLimit
            )
            try inject(.afterObjectRead)
            if reference.integrityStatus != .verified {
                try updateIntegrity(of: reference.id, to: .verified)
            }
            return data
        } catch ArtifactStoreError.ioFailure(let operation, let code)
            where operation == "missing-file" || code == ENOENT
        {
            try updateIntegrity(of: reference.id, to: .missing)
            throw ArtifactStoreError.missingContent(reference.id)
        } catch ArtifactStoreError.expectedByteCountMismatch {
            try updateIntegrity(of: reference.id, to: .corrupt)
            throw ArtifactStoreError.integrityMismatch(reference.id)
        } catch ArtifactStoreError.expectedDigestMismatch {
            try updateIntegrity(of: reference.id, to: .corrupt)
            throw ArtifactStoreError.integrityMismatch(reference.id)
        }
    }

    private func verifiedReference(for artifactID: ArtifactID) throws -> ArtifactReference {
        guard let record = index.record(for: artifactID) else {
            throw ArtifactStoreError.artifactNotFound(artifactID)
        }
        _ = try readAndUpdateIntegrity(record, maximumBytes: nil)
        return index.record(for: artifactID)!.reference
    }

    private func updateIntegrity(
        of artifactID: ArtifactID,
        to status: ArtifactIntegrityStatus
    ) throws {
        guard var record = index.record(for: artifactID) else {
            throw ArtifactStoreError.artifactNotFound(artifactID)
        }
        guard record.reference.integrityStatus != status else { return }
        record.reference = try Self.copy(record.reference, integrityStatus: status)
        var candidate = index
        candidate.replace(record)
        try commitIndex(candidate)
    }

    private func removeObjectAfterMetadata(_ digest: StableDigest) throws {
        try inject(.beforeObjectDelete)
        try fileSystem.removeObject(digest)
        try inject(.afterObjectDelete)
    }

    private func commitIndex(_ candidateValue: ArtifactIndex) throws {
        var candidate = candidateValue
        guard index.generation < UInt64.max else { throw ArtifactStoreError.metadataCorrupt }
        candidate.generation = index.generation + 1
        candidate.canonicalize()
        try Self.validate(candidate, fileSystem: fileSystem)
        let data = try Self.encoded(candidate)
        try inject(.beforeIndexReplace)
        try fileSystem.replaceIndex(with: data, temporaryName: temporaryNameGenerator())
        index = candidate
        try inject(.afterIndexReplace)
    }

    private func inject(_ point: ArtifactStoreFaultPoint) throws {
        try faultInjector?(point)
    }

    private static func validateInitialOwner(
        _ owner: ArtifactOwner,
        for request: ArtifactCommitRequest
    ) throws {
        switch request.retentionPolicy {
        case .run:
            guard owner.kind == .run,
                  request.provenance.runID?.description == owner.identifier
            else { throw ArtifactStoreError.retentionOwnerMismatch }
        case .conversation:
            guard owner.kind == .conversation || owner.kind == .message else {
                throw ArtifactStoreError.retentionOwnerMismatch
            }
        case .userManaged:
            guard owner.kind == .userManaged else {
                throw ArtifactStoreError.retentionOwnerMismatch
            }
        case .transient:
            guard owner.kind == .transient else {
                throw ArtifactStoreError.retentionOwnerMismatch
            }
        }
    }

    private static func matches(
        _ existing: ArtifactStoredRecord,
        request: ArtifactCommitRequest,
        digest: StableDigest,
        byteCount: UInt64
    ) -> Bool {
        let reference = existing.reference
        return reference.contentDigest == digest
            && reference.byteCount == byteCount
            && reference.mimeType == request.mimeType
            && reference.semanticType == request.semanticType
            && reference.provenance == request.provenance
            && reference.retentionPolicy == request.retentionPolicy
            && reference.sensitivity == request.sensitivity
    }

    private static func sameStableMetadata(
        _ durable: ArtifactReference,
        _ supplied: ArtifactReference
    ) -> Bool {
        durable.id == supplied.id
            && durable.contentDigest == supplied.contentDigest
            && durable.byteCount == supplied.byteCount
            && durable.mimeType == supplied.mimeType
            && durable.semanticType == supplied.semanticType
            && durable.provenance == supplied.provenance
            && durable.createdAt == supplied.createdAt
            && durable.retentionPolicy == supplied.retentionPolicy
            && durable.locator == supplied.locator
            && durable.sensitivity == supplied.sensitivity
    }

    private static func copy(
        _ reference: ArtifactReference,
        integrityStatus: ArtifactIntegrityStatus
    ) throws -> ArtifactReference {
        try ArtifactReference(
            id: reference.id,
            contentDigest: reference.contentDigest,
            byteCount: reference.byteCount,
            mimeType: reference.mimeType,
            semanticType: reference.semanticType,
            provenance: reference.provenance,
            createdAt: reference.createdAt,
            retentionPolicy: reference.retentionPolicy,
            locator: reference.locator,
            sensitivity: reference.sensitivity,
            integrityStatus: integrityStatus
        )
    }

    private static func unreferencedDigests(
        from previous: ArtifactIndex,
        after candidate: ArtifactIndex
    ) -> [StableDigest] {
        let before = Set(previous.records.map(\.reference.contentDigest))
        let after = Set(candidate.records.map(\.reference.contentDigest))
        return before.subtracting(after).sorted { $0.rawValue < $1.rawValue }
    }

    private static func validate(
        _ index: ArtifactIndex,
        fileSystem: ArtifactFileSystem
    ) throws {
        guard index.version == ArtifactIndex.currentVersion else {
            throw ArtifactStoreError.unsupportedMetadataVersion(index.version)
        }
        guard Set(index.records.map(\.reference.id)).count == index.records.count else {
            throw ArtifactStoreError.metadataCorrupt
        }
        guard index.records.map({ $0.reference.id.description })
            == index.records.map({ $0.reference.id.description }).sorted()
        else { throw ArtifactStoreError.metadataCorrupt }
        for record in index.records {
            guard Set(record.owners).count == record.owners.count,
                  record.owners == record.owners.sorted(),
                  record.reference.sensitivity != .secret,
                  record.reference.locator.kind == .managedRelativePath,
                  record.reference.locator.providerID == nil,
                  record.reference.locator.value
                    == fileSystem.relativeObjectPath(for: record.reference.contentDigest)
            else { throw ArtifactStoreError.metadataCorrupt }
        }
    }

    private static func recover(
        _ loaded: ArtifactIndex,
        fileSystem: ArtifactFileSystem,
        temporaryNameGenerator: ArtifactStoreTemporaryNameGenerator
    ) throws -> (index: ArtifactIndex, report: ArtifactCleanupReport) {
        let temporary = try fileSystem.cleanupTemporaryFiles()
        var candidate = loaded
        let impossible = candidate.records.filter {
            $0.owners.isEmpty && $0.reference.retentionPolicy != .userManaged
        }
        for record in impossible { candidate.remove(record.reference.id) }
        if candidate != loaded {
            guard loaded.generation < UInt64.max else { throw ArtifactStoreError.metadataCorrupt }
            candidate.generation = loaded.generation + 1
            candidate.canonicalize()
            try writeIndex(
                candidate,
                fileSystem: fileSystem,
                temporaryName: temporaryNameGenerator()
            )
        }
        let referenced = Set(candidate.records.map(\.reference.contentDigest))
        let orphaned = try fileSystem.allObjectDigests().subtracting(referenced)
            .sorted { $0.rawValue < $1.rawValue }
        for digest in orphaned { try fileSystem.removeObject(digest) }
        try fileSystem.syncRoot()
        return (
            candidate,
            ArtifactCleanupReport(
                removedArtifactIDs: impossible.map(\.reference.id),
                removedObjectDigests: orphaned,
                removedStagingFileCount: temporary.staging,
                removedMetadataTemporaryFileCount: temporary.metadata
            )
        )
    }

    private static func writeIndex(
        _ index: ArtifactIndex,
        fileSystem: ArtifactFileSystem,
        temporaryName: String
    ) throws {
        try fileSystem.replaceIndex(with: encoded(index), temporaryName: temporaryName)
    }

    private static func encoded(_ index: ArtifactIndex) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do { return try encoder.encode(index) }
        catch { throw ArtifactStoreError.metadataCorrupt }
    }
}

private struct ArtifactIndex: Hashable, Codable, Sendable {
    static let currentVersion = 1
    static let empty = Self(version: currentVersion, generation: 0, records: [])

    let version: Int
    var generation: UInt64
    var records: [ArtifactStoredRecord]

    func record(for id: ArtifactID) -> ArtifactStoredRecord? {
        records.first { $0.reference.id == id }
    }

    func contains(digest: StableDigest) -> Bool {
        records.contains { $0.reference.contentDigest == digest }
    }

    mutating func insert(_ record: ArtifactStoredRecord) {
        records.append(record)
        canonicalize()
    }

    mutating func replace(_ record: ArtifactStoredRecord) {
        guard let offset = records.firstIndex(where: { $0.reference.id == record.reference.id })
        else { return }
        records[offset] = record
        canonicalize()
    }

    mutating func remove(_ id: ArtifactID) {
        records.removeAll { $0.reference.id == id }
    }

    mutating func canonicalize() {
        for offset in records.indices { records[offset].owners.sort() }
        records.sort { $0.reference.id.description < $1.reference.id.description }
    }
}

private struct ArtifactStoredRecord: Hashable, Codable, Sendable {
    var reference: ArtifactReference
    var owners: [ArtifactOwner]
}

private enum ArtifactSecretDetector {
    static func containsProhibitedSecret(_ data: Data, mimeType: String) -> Bool {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8)
        else { return false }
        let lowercase = text.lowercased()
        if lowercase.contains("-----begin private key-----")
            || lowercase.contains("-----begin rsa private key-----")
            || lowercase.contains("-----begin openssh private key-----")
        {
            return true
        }
        for line in lowercase.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for prefix in ["authorization: bearer ", "proxy-authorization: bearer "]
                where trimmed.hasPrefix(prefix)
            {
                let token = trimmed.dropFirst(prefix.count)
                if token.count >= 8, !token.contains(where: \.isWhitespace) { return true }
            }
        }
        // A JWT used directly as a bearer token is also prohibited even when the header name was
        // stripped by an adapter. Requiring all three substantial base64url components avoids
        // classifying ordinary prose about bearer authentication as secret content.
        for word in lowercase.split(whereSeparator: \.isWhitespace) {
            let components = word.split(separator: ".", omittingEmptySubsequences: false)
            if components.count == 3,
               components[0].hasPrefix("eyj"),
               components.allSatisfy({ $0.count >= 8 && $0.allSatisfy(isBase64URL) })
            {
                return true
            }
        }
        _ = mimeType // MIME validation is performed by ArtifactReference.
        return false
    }

    private static func isBase64URL(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_"
    }
}

/// A capability-scoped adapter supplied to one authorized tool invocation. It cannot choose
/// provenance or ownership and therefore cannot write artifacts outside the invocation's run.
public struct ScopedToolArtifactWriter: ToolArtifactWriting, Sendable {
    private let store: ContentAddressedArtifactStore
    private let provenance: ArtifactProvenance
    private let owner: ArtifactOwner
    private let allowedRetentionPolicies: Set<ArtifactRetentionPolicy>

    public init(
        store: ContentAddressedArtifactStore,
        provenance: ArtifactProvenance,
        owner: ArtifactOwner,
        allowedRetentionPolicies: Set<ArtifactRetentionPolicy> = [.run]
    ) throws {
        guard !allowedRetentionPolicies.isEmpty,
              !allowedRetentionPolicies.contains(.userManaged),
              provenance.runID != nil
        else { throw ArtifactStoreError.retentionOwnerMismatch }
        self.store = store
        self.provenance = provenance
        self.owner = owner
        self.allowedRetentionPolicies = allowedRetentionPolicies
    }

    public func commit(
        data: Data,
        mimeType: String,
        semanticType: String?,
        retention: ArtifactRetentionPolicy,
        sensitivity: RedactionClassification
    ) async throws -> ArtifactReference {
        guard allowedRetentionPolicies.contains(retention) else {
            throw ArtifactStoreError.retentionOwnerMismatch
        }
        return try await store.commit(
            ArtifactCommitRequest(
                data: data,
                mimeType: mimeType,
                semanticType: semanticType,
                provenance: provenance,
                retentionPolicy: retention,
                sensitivity: sensitivity,
                initialOwner: owner
            )
        )
    }
}

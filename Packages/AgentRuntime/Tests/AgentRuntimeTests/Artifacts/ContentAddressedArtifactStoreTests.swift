// SPDX-License-Identifier: MIT

import AgentContracts
@testable import AgentRuntime
import Darwin
import Foundation
import XCTest

final class ContentAddressedArtifactStoreTests: XCTestCase, @unchecked Sendable {
    func testCoverageClosureOwnerIdentityRetentionAndLastOwnerRemoval() async throws {
        let root = uniqueRoot("owner-identity-coverage")
        let runID = id(AgentRunIDDomain.self, 900)
        let artifactID = id(ArtifactIDDomain.self, 901)
        let store = try makeStore(
            root: root,
            sequence: DeterministicNames(ids: [artifactID])
        )
        let data = Data("owner identity coverage".utf8)
        let committed = try await store.commit(
            ArtifactCommitRequest(
                data: data,
                mimeType: "text/plain",
                provenance: try ArtifactProvenance(runID: runID),
                retentionPolicy: .run,
                sensitivity: .internalMetadata,
                initialOwner: .run(runID)
            )
        )

        // A foreign owner is a no-op, not an error.
        let foreignOwner = try ArtifactOwner(kind: .durableRecord, identifier: "foreign")
        let removedNothing = try await store.removeReference(
            from: committed.id,
            owner: foreignOwner
        )
        XCTAssertFalse(removedNothing)

        // Deleting by an owner with no references yields an empty report.
        let emptyReport = try await store.deleteArtifactsOwned(by: foreignOwner)
        XCTAssertEqual(emptyReport.removedArtifactIDs, [])
        XCTAssertEqual(emptyReport.removedObjectDigests, [])

        // Removing the last durable owner removes both metadata and the object.
        let removed = try await store.removeReference(from: committed.id, owner: .run(runID))
        XCTAssertTrue(removed)
        await XCTAssertThrowsArtifactError(
            .artifactNotFound(committed.id),
            try await store.data(for: committed.id)
        )
    }

    func testCoverageClosureRetentionOwnerMismatchForEveryPolicy() async throws {
        let root = uniqueRoot("retention-owner-mismatch")
        let runID = id(AgentRunIDDomain.self, 910)
        let conversationID = id(ConversationIDDomain.self, 911)
        let store = try makeStore(
            root: root,
            sequence: DeterministicNames()
        )
        let provenance = try ArtifactProvenance(runID: runID)
        let scenarios: [(ArtifactRetentionPolicy, ArtifactOwner)] = [
            (.run, try ArtifactOwner(kind: .transient, identifier: "wrong")),
            (.userManaged, try ArtifactOwner(kind: .run, identifier: runID.description)),
            (.transient, try ArtifactOwner(kind: .conversation, identifier: conversationID.description)),
        ]
        for (retentionPolicy, initialOwner) in scenarios {
            await XCTAssertThrowsArtifactError(
                .retentionOwnerMismatch,
                try await store.commit(
                    ArtifactCommitRequest(
                        data: Data("mismatch".utf8),
                        mimeType: "text/plain",
                        provenance: provenance,
                        retentionPolicy: retentionPolicy,
                        sensitivity: .internalMetadata,
                        initialOwner: initialOwner
                    )
                )
            )
        }
    }

    func testDeleteArtifactKeepsSharedObjectBytesWhileAnotherRecordReferencesThem() async throws {
        let root = uniqueRoot("shared-digest-deletion")
        let runID = id(AgentRunIDDomain.self, 920)
        let firstID = id(ArtifactIDDomain.self, 921)
        let secondID = id(ArtifactIDDomain.self, 922)
        let store = try makeStore(
            root: root,
            sequence: DeterministicNames(ids: [firstID, secondID])
        )
        let data = Data("shared object bytes".utf8)
        let first = try await store.commit(
            ArtifactCommitRequest(
                data: data,
                mimeType: "text/plain",
                provenance: try ArtifactProvenance(runID: runID),
                retentionPolicy: .userManaged,
                sensitivity: .internalMetadata,
                initialOwner: try ArtifactOwner(kind: .userManaged, identifier: "user-1")
            )
        )
        let second = try await store.commit(
            ArtifactCommitRequest(
                data: data,
                mimeType: "text/plain",
                provenance: try ArtifactProvenance(
                    runID: runID,
                    stepID: id(AgentStepIDDomain.self, 923)
                ),
                retentionPolicy: .run,
                sensitivity: .internalMetadata,
                initialOwner: .run(runID)
            )
        )
        XCTAssertEqual(first.contentDigest, second.contentDigest)
        XCTAssertNotEqual(first.id, second.id)

        let report = try await store.deleteArtifact(first.id, reason: .explicitUserRequest)
        XCTAssertEqual(report.removedArtifactIDs, [first.id])
        XCTAssertEqual(report.removedObjectDigests, [])
        let remaining = try await store.data(for: second.id)
        XCTAssertEqual(remaining, data)
    }

    func testCommitPersistsExactMetadataAndVerifiedBytesAcrossReopen() async throws {
        let root = uniqueRoot("round-trip")
        let runID = id(AgentRunIDDomain.self, 1)
        let stepID = id(AgentStepIDDomain.self, 2)
        let invocationID = id(ToolInvocationIDDomain.self, 3)
        let artifactID = id(ArtifactIDDomain.self, 4)
        let provenance = try ArtifactProvenance(
            runID: runID,
            stepID: stepID,
            invocationID: invocationID,
            externalOperationFingerprint: StableDigest.sha256(Data("external-plan".utf8)),
            providerID: "local.tool"
        )
        let data = Data("durable artifact".utf8)
        let sequence = DeterministicNames(ids: [artifactID], names: ["initial-index", "object", "index"])
        var store: ContentAddressedArtifactStore? = try makeStore(
            root: root,
            sequence: sequence,
            timestamp: 123_456
        )
        let committed = try await store!.commit(
            ArtifactCommitRequest(
                data: data,
                expectedDigest: StableDigest.sha256(data),
                expectedByteCount: UInt64(data.count),
                mimeType: "text/plain",
                semanticType: "tool-output",
                provenance: provenance,
                retentionPolicy: .run,
                sensitivity: .personalData,
                initialOwner: .run(runID)
            )
        )

        XCTAssertEqual(committed.id, artifactID)
        XCTAssertEqual(committed.contentDigest, StableDigest.sha256(data))
        XCTAssertEqual(committed.byteCount, UInt64(data.count))
        XCTAssertEqual(committed.mimeType, "text/plain")
        XCTAssertEqual(committed.semanticType, "tool-output")
        XCTAssertEqual(committed.provenance, provenance)
        XCTAssertEqual(committed.createdAt, AgentTimestamp(rawValue: 123_456))
        XCTAssertEqual(committed.retentionPolicy, .run)
        XCTAssertEqual(committed.sensitivity, .personalData)
        XCTAssertEqual(committed.integrityStatus, .verified)
        XCTAssertEqual(committed.locator.kind, .managedRelativePath)
        XCTAssertEqual(
            committed.locator.value,
            "objects/\(committed.contentDigest.rawValue.prefix(2))/\(committed.contentDigest.rawValue).blob"
        )
        let loaded = try await store!.data(for: committed)
        XCTAssertEqual(loaded, data)
        let owners = try await store!.owners(for: artifactID)
        XCTAssertEqual(owners, [.run(runID)])
        let firstSnapshot = try await store!.snapshot()
        XCTAssertEqual(firstSnapshot.physicalObjectCount, 1)
        XCTAssertEqual(firstSnapshot.entries.count, 1)

        store = nil
        let reopened = try makeStore(root: root, sequence: DeterministicNames())
        let reopenedData = try await reopened.data(for: artifactID)
        let reopenedReference = await reopened.reference(for: artifactID)
        XCTAssertEqual(reopenedData, data)
        XCTAssertEqual(reopenedReference, committed)
        XCTAssertEqual(reopened.startupCleanupReport, ArtifactCleanupReport())
    }

    func testConcurrentCommitsDeduplicatePhysicalContentAndOwnerDeletionIsAtomic() async throws {
        let root = uniqueRoot("concurrent-dedup")
        let runID = id(AgentRunIDDomain.self, 10)
        let provenance = try ArtifactProvenance(runID: runID)
        let sequence = DeterministicNames(
            ids: (100 ..< 132).map { id(ArtifactIDDomain.self, $0) }
        )
        let store = try makeStore(root: root, sequence: sequence)
        let body = Data(repeating: 0x5a, count: 32_768)

        let references = try await withThrowingTaskGroup(of: ArtifactReference.self) { group in
            for _ in 0 ..< 32 {
                group.addTask {
                    try await store.commit(
                        ArtifactCommitRequest(
                            data: body,
                            mimeType: "application/octet-stream",
                            provenance: provenance,
                            retentionPolicy: .run,
                            sensitivity: .internalMetadata,
                            initialOwner: .run(runID)
                        )
                    )
                }
            }
            var values: [ArtifactReference] = []
            for try await reference in group { values.append(reference) }
            return values
        }

        XCTAssertEqual(Set(references.map(\.id)).count, 32)
        XCTAssertEqual(Set(references.map(\.contentDigest)).count, 1)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.entries.count, 32)
        XCTAssertEqual(snapshot.physicalObjectCount, 1)

        let report = try await store.deleteArtifactsOwned(by: .run(runID))
        XCTAssertEqual(report.removedArtifactIDs.count, 32)
        XCTAssertEqual(report.removedObjectDigests, [StableDigest.sha256(body)])
        let empty = try await store.snapshot()
        XCTAssertTrue(empty.entries.isEmpty)
        XCTAssertEqual(empty.physicalObjectCount, 0)
    }

    func testReferenceCountingRetentionAndPhysicalDeduplication() async throws {
        let root = uniqueRoot("reference-counts")
        let runID = id(AgentRunIDDomain.self, 20)
        let conversationID = id(ConversationIDDomain.self, 21)
        let firstID = id(ArtifactIDDomain.self, 22)
        let secondID = id(ArtifactIDDomain.self, 23)
        let body = Data("shared physical content".utf8)
        let store = try makeStore(
            root: root,
            sequence: DeterministicNames(ids: [firstID, secondID])
        )
        let first = try await store.commit(
            ArtifactCommitRequest(
                data: body,
                mimeType: "text/plain",
                provenance: try ArtifactProvenance(runID: runID),
                retentionPolicy: .run,
                sensitivity: .sensitive,
                initialOwner: .run(runID)
            )
        )
        let conversationOwner = ArtifactOwner.conversation(conversationID)
        try await store.addReference(to: first.id, owner: conversationOwner)
        try await store.addReference(to: first.id, owner: conversationOwner)
        let initialOwners = try await store.owners(for: first.id)
        XCTAssertEqual(initialOwners.count, 2)

        let userOwner = try ArtifactOwner(kind: .userManaged, identifier: "saved-export")
        let second = try await store.commit(
            ArtifactCommitRequest(
                data: body,
                mimeType: "text/plain",
                provenance: try ArtifactProvenance(providerID: "user.export"),
                retentionPolicy: .userManaged,
                sensitivity: .sensitive,
                initialOwner: userOwner
            )
        )
        let deduplicatedSnapshot = try await store.snapshot()
        XCTAssertEqual(deduplicatedSnapshot.physicalObjectCount, 1)

        _ = try await store.deleteArtifactsOwned(by: .run(runID))
        let firstAfterRunDeletion = await store.reference(for: first.id)
        let ownersAfterRunDeletion = try await store.owners(for: first.id)
        let bodyAfterRunDeletion = try await store.data(for: first.id)
        XCTAssertNotNil(firstAfterRunDeletion)
        XCTAssertEqual(ownersAfterRunDeletion, [conversationOwner])
        XCTAssertEqual(bodyAfterRunDeletion, body)

        let removedFirstOwner = try await store.removeReference(
            from: first.id,
            owner: conversationOwner
        )
        let removedFirstReference = await store.reference(for: first.id)
        let retainedSecondReference = await store.reference(for: second.id)
        let retainedPhysicalSnapshot = try await store.snapshot()
        XCTAssertTrue(removedFirstOwner)
        XCTAssertNil(removedFirstReference)
        XCTAssertNotNil(retainedSecondReference)
        XCTAssertEqual(retainedPhysicalSnapshot.physicalObjectCount, 1)

        let removedUserOwner = try await store.removeReference(from: second.id, owner: userOwner)
        let retainedUserManagedReference = await store.reference(for: second.id)
        XCTAssertTrue(removedUserOwner)
        XCTAssertNotNil(retainedUserManagedReference)
        await XCTAssertThrowsArtifactError(
            .userManagedArtifactRequiresExplicitDeletion(second.id),
            try await store.deleteArtifact(second.id, reason: .garbageCollection)
        )
        let deletion = try await store.deleteArtifact(second.id, reason: .explicitUserRequest)
        XCTAssertEqual(deletion.removedArtifactIDs, [second.id])
        let deletedSnapshot = try await store.snapshot()
        XCTAssertEqual(deletedSnapshot.physicalObjectCount, 0)
    }

    func testExplicitDeletionCannotBreakAnUnrelatedDurableReference() async throws {
        let root = uniqueRoot("explicit-delete")
        let artifactID = id(ArtifactIDDomain.self, 30)
        let store = try makeStore(
            root: root,
            sequence: DeterministicNames(ids: [artifactID])
        )
        let userOwner = try ArtifactOwner(kind: .userManaged, identifier: "export-30")
        let reference = try await store.commit(
            ArtifactCommitRequest(
                data: Data("export".utf8),
                mimeType: "text/plain",
                provenance: try ArtifactProvenance(providerID: "user.export"),
                retentionPolicy: .userManaged,
                sensitivity: .publicMetadata,
                initialOwner: userOwner
            )
        )
        let durableOwner = try ArtifactOwner(kind: .durableRecord, identifier: "journal-30")
        try await store.addReference(to: reference.id, owner: durableOwner)
        await XCTAssertThrowsArtifactError(
            .artifactStillReferenced(reference.id),
            try await store.deleteArtifact(reference.id, reason: .explicitUserRequest)
        )
        let retainedData = try await store.data(for: reference.id)
        XCTAssertEqual(retainedData, Data("export".utf8))
    }

    func testIntegrityTransitionsAreDurableAndRecoverWhenBytesAreRestored() async throws {
        let root = uniqueRoot("integrity")
        let runID = id(AgentRunIDDomain.self, 40)
        let artifactID = id(ArtifactIDDomain.self, 41)
        let store = try makeStore(
            root: root,
            sequence: DeterministicNames(ids: [artifactID])
        )
        let original = Data("original".utf8)
        let reference = try await store.commit(
            ArtifactCommitRequest(
                data: original,
                mimeType: "text/plain",
                provenance: try ArtifactProvenance(runID: runID),
                retentionPolicy: .run,
                sensitivity: .internalMetadata,
                initialOwner: .run(runID)
            )
        )
        let objectURL = root.appendingPathComponent(reference.locator.value)
        try Data("tampered".utf8).write(to: objectURL)

        let corrupt = try await store.verify(reference.id)
        XCTAssertEqual(corrupt.integrityStatus, .corrupt)
        await XCTAssertThrowsArtifactError(
            .integrityMismatch(reference.id),
            try await store.data(for: reference.id)
        )

        try original.write(to: objectURL)
        let restored = try await store.verify(reference.id)
        XCTAssertEqual(restored.integrityStatus, .verified)
        let restoredData = try await store.data(for: reference)
        XCTAssertEqual(restoredData, original)

        try FileManager.default.removeItem(at: objectURL)
        let missing = try await store.verify(reference.id)
        XCTAssertEqual(missing.integrityStatus, .missing)
        await XCTAssertThrowsArtifactError(
            .missingContent(reference.id),
            try await store.data(for: reference.id)
        )

        try original.write(to: objectURL)
        try FileManager.default.removeItem(at: objectURL.deletingLastPathComponent())
        let missingParent = try await store.verify(reference.id)
        XCTAssertEqual(missingParent.integrityStatus, .missing)
    }

    func testReadLimitAndForgedReferenceFailBeforeReturningBytes() async throws {
        let root = uniqueRoot("read-boundaries")
        let runID = id(AgentRunIDDomain.self, 50)
        let artifactID = id(ArtifactIDDomain.self, 51)
        let store = try makeStore(
            root: root,
            sequence: DeterministicNames(ids: [artifactID])
        )
        let body = Data("bounded bytes".utf8)
        let reference = try await store.commit(
            ArtifactCommitRequest(
                data: body,
                mimeType: "text/plain",
                provenance: try ArtifactProvenance(runID: runID),
                retentionPolicy: .run,
                sensitivity: .publicMetadata,
                initialOwner: .run(runID)
            )
        )
        await XCTAssertThrowsArtifactError(
            .artifactTooLarge(limit: 2, actual: UInt64(body.count)),
            try await store.data(for: reference.id, maximumBytes: 2)
        )
        let otherDigest = StableDigest.sha256(Data("other".utf8))
        let forged = try ArtifactReference(
            id: reference.id,
            contentDigest: otherDigest,
            byteCount: reference.byteCount,
            mimeType: reference.mimeType,
            semanticType: reference.semanticType,
            provenance: reference.provenance,
            createdAt: reference.createdAt,
            retentionPolicy: reference.retentionPolicy,
            locator: ArtifactLocator(
                kind: .managedRelativePath,
                value: "objects/\(otherDigest.rawValue.prefix(2))/\(otherDigest.rawValue).blob"
            ),
            sensitivity: reference.sensitivity,
            integrityStatus: .verified
        )
        await XCTAssertThrowsArtifactError(
            .staleReference(reference.id),
            try await store.data(for: forged)
        )
    }

    func testInputPolicyRejectsOversizeDigestSizeMetadataRetentionAndSecretsWithoutMutation() async throws {
        let root = uniqueRoot("input-policy")
        let runID = id(AgentRunIDDomain.self, 60)
        let artifactID = id(ArtifactIDDomain.self, 61)
        let store = try makeStore(
            root: root,
            sequence: DeterministicNames(ids: [artifactID]),
            maximumBytes: 64
        )
        let provenance = try ArtifactProvenance(runID: runID)
        let base = ArtifactCommitRequest(
            data: Data("okay".utf8),
            mimeType: "text/plain",
            provenance: provenance,
            retentionPolicy: .run,
            sensitivity: .publicMetadata,
            initialOwner: .run(runID)
        )

        await XCTAssertThrowsArtifactError(
            .artifactTooLarge(limit: 64, actual: 65),
            try await store.commit(
                ArtifactCommitRequest(
                    data: Data(repeating: 0x5a, count: 65),
                    mimeType: "text/plain",
                    provenance: provenance,
                    retentionPolicy: .run,
                    sensitivity: .publicMetadata,
                    initialOwner: .run(runID)
                )
            )
        )
        await XCTAssertThrowsArtifactError(
            .expectedDigestMismatch,
            try await store.commit(
                ArtifactCommitRequest(
                    data: base.data,
                    expectedDigest: StableDigest.sha256(Data("wrong".utf8)),
                    mimeType: base.mimeType,
                    provenance: provenance,
                    retentionPolicy: .run,
                    sensitivity: .publicMetadata,
                    initialOwner: .run(runID)
                )
            )
        )
        await XCTAssertThrowsArtifactError(
            .expectedByteCountMismatch,
            try await store.commit(
                ArtifactCommitRequest(
                    data: base.data,
                    expectedByteCount: 3,
                    mimeType: base.mimeType,
                    provenance: provenance,
                    retentionPolicy: .run,
                    sensitivity: .publicMetadata,
                    initialOwner: .run(runID)
                )
            )
        )
        await XCTAssertThrowsArtifactError(
            .secretContentProhibited,
            try await store.commit(
                ArtifactCommitRequest(
                    data: base.data,
                    mimeType: base.mimeType,
                    provenance: provenance,
                    retentionPolicy: .run,
                    sensitivity: .secret,
                    initialOwner: .run(runID)
                )
            )
        )
        await XCTAssertThrowsArtifactError(
            .secretContentProhibited,
            try await store.commit(
                ArtifactCommitRequest(
                    data: Data("eyJabcdefgh.abcdefghijk.abcdefghijk".utf8),
                    mimeType: "text/plain",
                    provenance: provenance,
                    retentionPolicy: .run,
                    sensitivity: .sensitive,
                    initialOwner: .run(runID)
                )
            )
        )
        await XCTAssertThrowsArtifactError(
            .secretContentProhibited,
            try await store.commit(
                ArtifactCommitRequest(
                    data: Data("Authorization: Bearer abcdefghijklmnop".utf8),
                    mimeType: "text/plain",
                    provenance: provenance,
                    retentionPolicy: .run,
                    sensitivity: .sensitive,
                    initialOwner: .run(runID)
                )
            )
        )
        await XCTAssertThrowsArtifactError(
            .retentionOwnerMismatch,
            try await store.commit(
                ArtifactCommitRequest(
                    data: base.data,
                    mimeType: base.mimeType,
                    provenance: provenance,
                    retentionPolicy: .conversation,
                    sensitivity: .publicMetadata,
                    initialOwner: .run(runID)
                )
            )
        )
        await XCTAssertThrowsArtifactError(
            .invalidArtifactMetadata,
            try await store.commit(
                ArtifactCommitRequest(
                    data: base.data,
                    mimeType: "TEXT/PLAIN; charset=utf-8",
                    provenance: provenance,
                    retentionPolicy: .run,
                    sensitivity: .publicMetadata,
                    initialOwner: .run(runID)
                )
            )
        )
        let rejectedReferences = await store.allReferences()
        let rejectedSnapshot = try await store.snapshot()
        XCTAssertTrue(rejectedReferences.isEmpty)
        XCTAssertEqual(rejectedSnapshot.physicalObjectCount, 0)
    }

    func testExplicitIDMakesCommitRetryIdempotentAndRejectsCollisions() async throws {
        let root = uniqueRoot("idempotent-id")
        let runID = id(AgentRunIDDomain.self, 70)
        let artifactID = id(ArtifactIDDomain.self, 71)
        let store = try makeStore(root: root, sequence: DeterministicNames())
        let request = ArtifactCommitRequest(
            artifactID: artifactID,
            data: Data("same".utf8),
            mimeType: "text/plain",
            provenance: try ArtifactProvenance(runID: runID),
            retentionPolicy: .run,
            sensitivity: .internalMetadata,
            initialOwner: .run(runID)
        )
        let first = try await store.commit(request)
        let retried = try await store.commit(request)
        XCTAssertEqual(first, retried)
        let idempotentReferences = await store.allReferences()
        XCTAssertEqual(idempotentReferences.count, 1)

        await XCTAssertThrowsArtifactError(
            .artifactIDCollision(artifactID),
            try await store.commit(
                ArtifactCommitRequest(
                    artifactID: artifactID,
                    data: Data("different".utf8),
                    mimeType: "text/plain",
                    provenance: request.provenance,
                    retentionPolicy: .run,
                    sensitivity: .internalMetadata,
                    initialOwner: .run(runID)
                )
            )
        )
    }

    func testRootAndObjectSymlinksAreRejectedWithoutReadingExternalData() async throws {
        let container = uniqueRoot("symlink-container")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let realRoot = container.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        let linkedRoot = container.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)
        XCTAssertThrowsError(
            try ContentAddressedArtifactStore(
                configuration: ArtifactStoreConfiguration(
                    rootURL: linkedRoot,
                    excludeFromBackup: false,
                    verifyPlatformProtection: false
                )
            )
        ) { XCTAssertEqual($0 as? ArtifactStoreError, .symbolicLinkEncountered) }

        let root = uniqueRoot("object-symlink")
        let runID = id(AgentRunIDDomain.self, 80)
        let artifactID = id(ArtifactIDDomain.self, 81)
        let store = try makeStore(
            root: root,
            sequence: DeterministicNames(ids: [artifactID])
        )
        let reference = try await store.commit(
            ArtifactCommitRequest(
                data: Data("inside".utf8),
                mimeType: "text/plain",
                provenance: try ArtifactProvenance(runID: runID),
                retentionPolicy: .run,
                sensitivity: .publicMetadata,
                initialOwner: .run(runID)
            )
        )
        let object = root.appendingPathComponent(reference.locator.value)
        let external = container.appendingPathComponent("external-secret")
        let externalBody = Data("must never be read".utf8)
        try externalBody.write(to: external)
        try FileManager.default.removeItem(at: object)
        try FileManager.default.createSymbolicLink(at: object, withDestinationURL: external)

        await XCTAssertThrowsArtifactError(
            .symbolicLinkEncountered,
            try await store.data(for: reference.id)
        )
        XCTAssertEqual(try Data(contentsOf: external), externalBody)
    }

    func testStoreLockAndMetadataValidationFailClosed() async throws {
        let root = uniqueRoot("lock-and-metadata")
        var first: ContentAddressedArtifactStore? = try makeStore(root: root)
        XCTAssertNotNil(first)
        XCTAssertThrowsError(try makeStore(root: root)) {
            XCTAssertEqual($0 as? ArtifactStoreError, .storeAlreadyOpen)
        }
        first = nil

        let indexURL = root.appendingPathComponent("metadata/artifact-index-v1.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any]
        )
        object["version"] = 999
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(
            to: indexURL,
            options: .atomic
        )
        XCTAssertThrowsError(try makeStore(root: root)) {
            XCTAssertEqual($0 as? ArtifactStoreError, .unsupportedMetadataVersion(999))
        }
    }

    #if os(macOS)
    func testCrossProcessPOSIXLockBlocksASecondStore() throws {
        let environment = ProcessInfo.processInfo.environment
        if environment["MOBILELLM_ARTIFACT_LOCK_HELPER_PATH"] != nil {
            try runPOSIXLockHelper(environment: environment)
            return
        }

        let root = uniqueRoot("cross-process-lock")
        var bootstrap: ContentAddressedArtifactStore? = try makeStore(root: root)
        XCTAssertNotNil(bootstrap)
        bootstrap = nil

        let lockPath = root.appendingPathComponent(".artifact-store.lock").path
        let readyURL = root.appendingPathComponent("lock-helper.ready")
        let releaseURL = root.appendingPathComponent("lock-helper.release")
        let childOutput = Pipe()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = [
            "xctest",
            "-XCTest",
            "AgentRuntimeTests.ContentAddressedArtifactStoreTests/testCrossProcessPOSIXLockBlocksASecondStore",
            Bundle(for: ContentAddressedArtifactStoreTests.self).bundleURL.path,
        ]
        var childEnvironment = ProcessInfo.processInfo.environment
        childEnvironment["MOBILELLM_ARTIFACT_LOCK_HELPER_PATH"] = lockPath
        childEnvironment["MOBILELLM_ARTIFACT_LOCK_HELPER_READY"] = readyURL.path
        childEnvironment["MOBILELLM_ARTIFACT_LOCK_HELPER_RELEASE"] = releaseURL.path
        childEnvironment["LLVM_PROFILE_FILE"] = root.appendingPathComponent("helper-%p.profraw").path
        child.environment = childEnvironment
        child.standardOutput = childOutput
        child.standardError = childOutput
        try child.run()
        defer {
            if child.isRunning {
                child.terminate()
                child.waitUntilExit()
            }
        }

        let readyDeadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: readyURL.path),
              child.isRunning,
              Date() < readyDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard FileManager.default.fileExists(atPath: readyURL.path) else {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
            let output = childOutput.fileHandleForReading.readDataToEndOfFile()
            XCTFail("lock helper failed before readiness: \(String(decoding: output, as: UTF8.self))")
            return
        }

        XCTAssertThrowsError(try makeStore(root: root)) {
            XCTAssertEqual($0 as? ArtifactStoreError, .storeAlreadyOpen)
        }
        try Data([1]).write(to: releaseURL, options: .atomic)
        child.waitUntilExit()
        let output = childOutput.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(
            child.terminationStatus,
            0,
            "lock helper failed: \(String(decoding: output, as: UTF8.self))"
        )
    }

    private func runPOSIXLockHelper(environment: [String: String]) throws {
        let lockPath = try XCTUnwrap(environment["MOBILELLM_ARTIFACT_LOCK_HELPER_PATH"])
        let readyPath = try XCTUnwrap(environment["MOBILELLM_ARTIFACT_LOCK_HELPER_READY"])
        let releasePath = try XCTUnwrap(environment["MOBILELLM_ARTIFACT_LOCK_HELPER_RELEASE"])
        let descriptor = Darwin.open(lockPath, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }

        var lock = Darwin.flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        XCTAssertEqual(Darwin.fcntl(descriptor, F_SETLK, &lock), 0)
        defer {
            lock.l_type = Int16(F_UNLCK)
            _ = Darwin.fcntl(descriptor, F_SETLK, &lock)
        }

        try Data([1]).write(to: URL(fileURLWithPath: readyPath), options: .atomic)
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: releasePath), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: releasePath))
    }
    #endif

    func testOrphanAndTemporaryCleanupIsDeterministicOnReopen() async throws {
        let root = uniqueRoot("orphan-cleanup")
        var store: ContentAddressedArtifactStore? = try makeStore(root: root)
        XCTAssertNotNil(store)
        store = nil

        let orphans = distinctOrderedOrphans()
        for orphan in orphans {
            let objectDirectory = root.appendingPathComponent(
                "objects/\(orphan.digest.rawValue.prefix(2))",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: objectDirectory, withIntermediateDirectories: true)
            try orphan.data.write(
                to: objectDirectory.appendingPathComponent("\(orphan.digest.rawValue).blob")
            )
        }
        try Data("stage".utf8).write(
            to: root.appendingPathComponent("staging/manual.stage")
        )
        try Data("temp".utf8).write(
            to: root.appendingPathComponent("metadata/index.manual.tmp")
        )

        let reopened = try makeStore(root: root)
        XCTAssertEqual(
            reopened.startupCleanupReport.removedObjectDigests,
            orphans.map(\.digest).sorted { $0.rawValue < $1.rawValue }
        )
        XCTAssertEqual(reopened.startupCleanupReport.removedStagingFileCount, 1)
        XCTAssertEqual(reopened.startupCleanupReport.removedMetadataTemporaryFileCount, 1)
        let reopenedSnapshot = try await reopened.snapshot()
        XCTAssertEqual(reopenedSnapshot.physicalObjectCount, 0)
    }

    func testCoverageClosureExercisesDefaultsManualCleanupAndDistinctDigestDeletion() async throws {
        let root = uniqueRoot("coverage-defaults")
        let configuration = try ArtifactStoreConfiguration(
            rootURL: root,
            excludeFromBackup: false,
            verifyPlatformProtection: false
        )
        let store = try ContentAddressedArtifactStore(configuration: configuration)
        let runID = id(AgentRunIDDomain.self, 500)
        let first = try await store.commit(
            ArtifactCommitRequest(
                data: Data("first-distinct".utf8),
                mimeType: "text/plain",
                provenance: try ArtifactProvenance(runID: runID),
                retentionPolicy: .run,
                sensitivity: .internalMetadata,
                initialOwner: .run(runID)
            )
        )
        let second = try await store.commit(
            ArtifactCommitRequest(
                data: Data("second-distinct".utf8),
                mimeType: "text/plain",
                provenance: try ArtifactProvenance(runID: runID),
                retentionPolicy: .run,
                sensitivity: .internalMetadata,
                initialOwner: .run(runID)
            )
        )
        XCTAssertNotEqual(first.contentDigest, second.contentDigest)

        let deletion = try await store.deleteArtifactsOwned(by: .run(runID))
        XCTAssertEqual(deletion.removedArtifactIDs.count, 2)
        XCTAssertEqual(deletion.removedObjectDigests.count, 2)

        let retainedRunID = id(AgentRunIDDomain.self, 502)
        _ = try await store.commit(
            ArtifactCommitRequest(
                data: Data("retained-through-cleanup".utf8),
                mimeType: "text/plain",
                provenance: try ArtifactProvenance(runID: retainedRunID),
                retentionPolicy: .run,
                sensitivity: .internalMetadata,
                initialOwner: .run(retainedRunID)
            )
        )

        let messageOwner = ArtifactOwner.message(id(MessageIDDomain.self, 501))
        XCTAssertEqual(messageOwner.kind, .message)
        let sortedReport = ArtifactCleanupReport(
            removedObjectDigests: [
                StableDigest.sha256(Data("z".utf8)),
                StableDigest.sha256(Data("a".utf8)),
            ]
        )
        XCTAssertEqual(
            sortedReport.removedObjectDigests,
            sortedReport.removedObjectDigests.sorted { $0.rawValue < $1.rawValue }
        )

        let orphans = distinctOrderedOrphans()
        for orphan in orphans {
            let directory = root.appendingPathComponent(
                "objects/\(orphan.digest.rawValue.prefix(2))",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try orphan.data.write(
                to: directory.appendingPathComponent("\(orphan.digest.rawValue).blob")
            )
        }
        try Data("manual-stage".utf8).write(
            to: root.appendingPathComponent("staging/manual-coverage.stage")
        )
        try Data("manual-index-temp".utf8).write(
            to: root.appendingPathComponent("metadata/index.coverage.tmp")
        )
        let cleanup = try await store.cleanupOrphans()
        XCTAssertEqual(cleanup.removedObjectDigests.count, orphans.count)
        XCTAssertEqual(cleanup.removedStagingFileCount, 1)
        XCTAssertEqual(cleanup.removedMetadataTemporaryFileCount, 1)
    }

    func testCoverageClosurePOSIXConfinementAndFailureClassification() async throws {
        let runID = id(AgentRunIDDomain.self, 560)
        let provenance = try ArtifactProvenance(runID: runID)

        let unwritableRoot = uniqueRoot("unwritable-existing-root")
        try FileManager.default.createDirectory(at: unwritableRoot, withIntermediateDirectories: true)
        XCTAssertEqual(Darwin.chmod(unwritableRoot.path, S_IRUSR | S_IXUSR), 0)
        XCTAssertThrowsError(try makeStore(root: unwritableRoot)) {
            guard case .ioFailure(let operation, _) = $0 as? ArtifactStoreError else {
                return XCTFail("Unexpected error: \($0)")
            }
            XCTAssertEqual(operation, "create-directory")
        }
        XCTAssertEqual(Darwin.chmod(unwritableRoot.path, S_IRWXU), 0)

        let stagingRoot = uniqueRoot("unwritable-stage")
        let stagingStore = try makeStore(root: stagingRoot)
        let stagingDirectory = stagingRoot.appendingPathComponent("staging", isDirectory: true)
        XCTAssertEqual(Darwin.chmod(stagingDirectory.path, S_IRUSR | S_IXUSR), 0)
        do {
            _ = try await stagingStore.commit(
                ArtifactCommitRequest(
                    data: Data("cannot-stage".utf8),
                    mimeType: "text/plain",
                    provenance: provenance,
                    retentionPolicy: .run,
                    sensitivity: .internalMetadata,
                    initialOwner: .run(runID)
                )
            )
            XCTFail("Expected staging create failure")
        } catch let error as ArtifactStoreError {
            guard case .ioFailure(let operation, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(operation, "create-file")
        }
        XCTAssertEqual(Darwin.chmod(stagingDirectory.path, S_IRWXU), 0)

        let objectDirectoryRoot = uniqueRoot("unwritable-object-directory")
        let objectDirectoryStore = try makeStore(root: objectDirectoryRoot)
        let objectDirectory = objectDirectoryRoot.appendingPathComponent("objects", isDirectory: true)
        XCTAssertEqual(Darwin.chmod(objectDirectory.path, S_IRUSR | S_IXUSR), 0)
        do {
            _ = try await objectDirectoryStore.commit(
                ArtifactCommitRequest(
                    data: Data("cannot-create-prefix".utf8),
                    mimeType: "text/plain",
                    provenance: provenance,
                    retentionPolicy: .run,
                    sensitivity: .internalMetadata,
                    initialOwner: .run(runID)
                )
            )
            XCTFail("Expected object-directory create failure")
        } catch let error as ArtifactStoreError {
            guard case .ioFailure(let operation, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(operation, "create-object-directory")
        }
        XCTAssertEqual(Darwin.chmod(objectDirectory.path, S_IRWXU), 0)

        let publishRoot = uniqueRoot("unwritable-publish")
        let publishStore = try makeStore(root: publishRoot)
        let publishBody = Data("cannot-link-object".utf8)
        let publishDigest = StableDigest.sha256(publishBody)
        let publishDirectory = publishRoot.appendingPathComponent(
            "objects/\(publishDigest.rawValue.prefix(2))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: publishDirectory, withIntermediateDirectories: true)
        XCTAssertEqual(Darwin.chmod(publishDirectory.path, S_IRUSR | S_IXUSR), 0)
        do {
            _ = try await publishStore.commit(
                ArtifactCommitRequest(
                    data: publishBody,
                    mimeType: "text/plain",
                    provenance: provenance,
                    retentionPolicy: .run,
                    sensitivity: .internalMetadata,
                    initialOwner: .run(runID)
                )
            )
            XCTFail("Expected atomic publish failure")
        } catch let error as ArtifactStoreError {
            guard case .ioFailure(let operation, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(operation, "publish-object")
        }
        XCTAssertEqual(Darwin.chmod(publishDirectory.path, S_IRWXU), 0)

        let unreadableRoot = uniqueRoot("unreadable-object")
        let unreadableStore = try makeStore(root: unreadableRoot)
        let unreadable = try await unreadableStore.commit(
            ArtifactCommitRequest(
                data: Data("unreadable".utf8),
                mimeType: "text/plain",
                provenance: provenance,
                retentionPolicy: .run,
                sensitivity: .internalMetadata,
                initialOwner: .run(runID)
            )
        )
        let unreadableURL = unreadableRoot.appendingPathComponent(unreadable.locator.value)
        XCTAssertEqual(Darwin.chmod(unreadableURL.path, 0), 0)
        do {
            _ = try await unreadableStore.data(for: unreadable.id)
            XCTFail("Expected unreadable object failure")
        } catch let error as ArtifactStoreError {
            guard case .ioFailure(let operation, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(operation, "open-file")
        }
        XCTAssertEqual(Darwin.chmod(unreadableURL.path, S_IRUSR | S_IWUSR), 0)

        let nonregularRoot = uniqueRoot("nonregular-object")
        let nonregularStore = try makeStore(root: nonregularRoot)
        let nonregular = try await nonregularStore.commit(
            ArtifactCommitRequest(
                data: Data("nonregular".utf8),
                mimeType: "text/plain",
                provenance: provenance,
                retentionPolicy: .run,
                sensitivity: .internalMetadata,
                initialOwner: .run(runID)
            )
        )
        let nonregularURL = nonregularRoot.appendingPathComponent(nonregular.locator.value)
        try FileManager.default.removeItem(at: nonregularURL)
        try FileManager.default.createDirectory(at: nonregularURL, withIntermediateDirectories: false)
        await XCTAssertThrowsArtifactError(
            .symbolicLinkEncountered,
            try await nonregularStore.data(for: nonregular.id)
        )
    }

    func testCoverageClosureMetadataAndObjectNodeTypesFailClosed() async throws {
        let indexSymlinkRoot = uniqueRoot("index-symlink")
        var indexSymlinkStore: ContentAddressedArtifactStore? = try makeStore(root: indexSymlinkRoot)
        XCTAssertNotNil(indexSymlinkStore)
        indexSymlinkStore = nil
        let indexURL = indexSymlinkRoot.appendingPathComponent("metadata/artifact-index-v1.json")
        let indexBackup = indexSymlinkRoot.appendingPathComponent("index-backup")
        try FileManager.default.moveItem(at: indexURL, to: indexBackup)
        try FileManager.default.createSymbolicLink(at: indexURL, withDestinationURL: indexBackup)
        XCTAssertThrowsError(try makeStore(root: indexSymlinkRoot)) {
            XCTAssertEqual($0 as? ArtifactStoreError, .symbolicLinkEncountered)
        }

        let indexDirectoryRoot = uniqueRoot("index-directory")
        var indexDirectoryStore: ContentAddressedArtifactStore? = try makeStore(root: indexDirectoryRoot)
        XCTAssertNotNil(indexDirectoryStore)
        indexDirectoryStore = nil
        let directoryIndexURL = indexDirectoryRoot
            .appendingPathComponent("metadata/artifact-index-v1.json")
        try FileManager.default.removeItem(at: directoryIndexURL)
        try FileManager.default.createDirectory(
            at: directoryIndexURL,
            withIntermediateDirectories: false
        )
        XCTAssertThrowsError(try makeStore(root: indexDirectoryRoot)) {
            XCTAssertEqual($0 as? ArtifactStoreError, .metadataCorrupt)
        }

        let objectSymlinkRoot = uniqueRoot("object-node-symlink")
        let runID = id(AgentRunIDDomain.self, 570)
        let objectSymlinkStore = try makeStore(root: objectSymlinkRoot)
        let symlinkReference = try await objectSymlinkStore.commit(
            ArtifactCommitRequest(
                data: Data("object-node".utf8),
                mimeType: "text/plain",
                provenance: try ArtifactProvenance(runID: runID),
                retentionPolicy: .run,
                sensitivity: .internalMetadata,
                initialOwner: .run(runID)
            )
        )
        let symlinkObject = objectSymlinkRoot.appendingPathComponent(symlinkReference.locator.value)
        let symlinkTarget = objectSymlinkRoot.appendingPathComponent("target")
        try Data("target".utf8).write(to: symlinkTarget)
        try FileManager.default.removeItem(at: symlinkObject)
        try FileManager.default.createSymbolicLink(at: symlinkObject, withDestinationURL: symlinkTarget)
        await XCTAssertThrowsArtifactError(
            .symbolicLinkEncountered,
            try await objectSymlinkStore.snapshot()
        )

        let objectDirectoryRoot = uniqueRoot("object-node-directory")
        let objectDirectoryStore = try makeStore(root: objectDirectoryRoot)
        let directoryReference = try await objectDirectoryStore.commit(
            ArtifactCommitRequest(
                data: Data("object-directory".utf8),
                mimeType: "text/plain",
                provenance: try ArtifactProvenance(runID: runID),
                retentionPolicy: .run,
                sensitivity: .internalMetadata,
                initialOwner: .run(runID)
            )
        )
        let directoryObject = objectDirectoryRoot
            .appendingPathComponent(directoryReference.locator.value)
        try FileManager.default.removeItem(at: directoryObject)
        try FileManager.default.createDirectory(at: directoryObject, withIntermediateDirectories: false)
        await XCTAssertThrowsArtifactError(
            .metadataCorrupt,
            try await objectDirectoryStore.snapshot()
        )

        let prefixSymlinkRoot = uniqueRoot("prefix-symlink")
        let prefixSymlinkStore = try makeStore(root: prefixSymlinkRoot)
        try FileManager.default.createSymbolicLink(
            at: prefixSymlinkRoot.appendingPathComponent("objects/aa"),
            withDestinationURL: prefixSymlinkRoot.appendingPathComponent("staging")
        )
        await XCTAssertThrowsArtifactError(
            .symbolicLinkEncountered,
            try await prefixSymlinkStore.snapshot()
        )

        let prefixFileRoot = uniqueRoot("prefix-file")
        let prefixFileStore = try makeStore(root: prefixFileRoot)
        try Data("not-directory".utf8).write(
            to: prefixFileRoot.appendingPathComponent("objects/aa")
        )
        await XCTAssertThrowsArtifactError(
            .invalidConfiguration,
            try await prefixFileStore.snapshot()
        )
    }

    func testCoverageClosureRejectsSpecialLockUnsafeStagingAndMalformedObjectTree() async throws {
        let lockRoot = uniqueRoot("special-lock")
        try FileManager.default.createDirectory(at: lockRoot, withIntermediateDirectories: true)
        let lockPath = lockRoot.appendingPathComponent(".artifact-store.lock").path
        XCTAssertEqual(Darwin.mkfifo(lockPath, S_IRUSR | S_IWUSR), 0)
        XCTAssertThrowsError(try makeStore(root: lockRoot)) {
            XCTAssertEqual($0 as? ArtifactStoreError, .invalidConfiguration)
        }

        let stagingRoot = uniqueRoot("unsafe-staging")
        let stagingStore = try makeStore(root: stagingRoot)
        let unsafeDirectory = stagingRoot.appendingPathComponent(
            "staging/unsafe.stage",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: unsafeDirectory, withIntermediateDirectories: true)
        do {
            _ = try await stagingStore.cleanupOrphans()
            XCTFail("Expected unsafe staging directory rejection")
        } catch let error as ArtifactStoreError {
            guard case .ioFailure(let operation, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(operation, "remove-temporary-file")
        }

        let malformedRoot = uniqueRoot("malformed-object-tree")
        let malformedStore = try makeStore(root: malformedRoot)
        try FileManager.default.createDirectory(
            at: malformedRoot.appendingPathComponent("objects/not-hex", isDirectory: true),
            withIntermediateDirectories: true
        )
        await XCTAssertThrowsArtifactError(
            .metadataCorrupt,
            try await malformedStore.snapshot()
        )
    }

    func testCoverageClosurePublicNegativeSurfaceAndAllRetentionKinds() async throws {
        let root = uniqueRoot("public-negative-surface")
        let runID = id(AgentRunIDDomain.self, 520)
        let artifactID = id(ArtifactIDDomain.self, 521)
        let unknownID = id(ArtifactIDDomain.self, 522)
        let store = try makeStore(
            root: root,
            sequence: DeterministicNames(ids: [artifactID])
        )
        let reference = try await store.commit(
            ArtifactCommitRequest(
                data: Data("known".utf8),
                mimeType: "text/plain",
                provenance: try ArtifactProvenance(runID: runID),
                retentionPolicy: .run,
                sensitivity: .internalMetadata,
                initialOwner: .run(runID)
            )
        )
        let unknownReference = try ArtifactReference(
            id: unknownID,
            contentDigest: reference.contentDigest,
            byteCount: reference.byteCount,
            mimeType: reference.mimeType,
            provenance: reference.provenance,
            createdAt: reference.createdAt,
            retentionPolicy: reference.retentionPolicy,
            locator: reference.locator,
            sensitivity: reference.sensitivity,
            integrityStatus: .verified
        )
        await XCTAssertThrowsArtifactError(
            .artifactNotFound(unknownID),
            try await store.data(for: unknownID)
        )
        await XCTAssertThrowsArtifactError(
            .artifactNotFound(unknownID),
            try await store.data(for: unknownReference)
        )
        await XCTAssertThrowsArtifactError(
            .artifactNotFound(unknownID),
            try await store.verify(unknownID)
        )
        await XCTAssertThrowsArtifactError(
            .artifactNotFound(unknownID),
            try await store.addReference(
                to: unknownID,
                owner: try ArtifactOwner(kind: .durableRecord, identifier: "unknown-owner")
            )
        )
        await XCTAssertThrowsArtifactError(
            .artifactNotFound(unknownID),
            try await store.removeReference(
                from: unknownID,
                owner: try ArtifactOwner(kind: .durableRecord, identifier: "unknown-owner")
            )
        )
        await XCTAssertThrowsArtifactError(
            .artifactNotFound(unknownID),
            try await store.deleteArtifact(unknownID, reason: .garbageCollection)
        )
        await XCTAssertThrowsArtifactError(
            .artifactNotFound(unknownID),
            try await store.owners(for: unknownID)
        )
        await XCTAssertThrowsArtifactError(
            .artifactStillReferenced(reference.id),
            try await store.deleteArtifact(reference.id, reason: .garbageCollection)
        )

        await XCTAssertThrowsArtifactError(
            .retentionOwnerMismatch,
            try await store.commit(
                ArtifactCommitRequest(
                    data: Data(),
                    mimeType: "application/octet-stream",
                    provenance: try ArtifactProvenance(runID: runID),
                    retentionPolicy: .userManaged,
                    sensitivity: .publicMetadata,
                    initialOwner: .run(runID)
                )
            )
        )
        await XCTAssertThrowsArtifactError(
            .retentionOwnerMismatch,
            try await store.commit(
                ArtifactCommitRequest(
                    data: Data(),
                    mimeType: "application/octet-stream",
                    provenance: try ArtifactProvenance(runID: runID),
                    retentionPolicy: .transient,
                    sensitivity: .publicMetadata,
                    initialOwner: .run(runID)
                )
            )
        )
        let transientOwner = try ArtifactOwner(kind: .transient, identifier: "transient-520")
        let transient = try await store.commit(
            ArtifactCommitRequest(
                data: Data(),
                mimeType: "application/octet-stream",
                provenance: try ArtifactProvenance(providerID: "local.transient"),
                retentionPolicy: .transient,
                sensitivity: .publicMetadata,
                initialOwner: transientOwner
            )
        )
        let transientData = try await store.data(for: transient.id)
        XCTAssertEqual(transientData.count, 0)
    }

    func testCoverageClosureSecretVariantsAndBothIntegrityMismatchClasses() async throws {
        let root = uniqueRoot("secret-and-integrity-classes")
        let runID = id(AgentRunIDDomain.self, 530)
        let artifactID = id(ArtifactIDDomain.self, 531)
        let store = try makeStore(
            root: root,
            sequence: DeterministicNames(ids: [artifactID]),
            maximumBytes: 1_024
        )
        let provenance = try ArtifactProvenance(runID: runID)
        for secret in [
            "-----BEGIN PRIVATE KEY-----\nabc",
            "-----BEGIN RSA PRIVATE KEY-----\nabc",
            "-----BEGIN OPENSSH PRIVATE KEY-----\nabc",
            "eyjabc1-_.abcde1-_.abcdef1-_",
        ] {
            await XCTAssertThrowsArtifactError(
                .secretContentProhibited,
                try await store.commit(
                    ArtifactCommitRequest(
                        data: Data(secret.utf8),
                        mimeType: "text/plain",
                        provenance: provenance,
                        retentionPolicy: .run,
                        sensitivity: .sensitive,
                        initialOwner: .run(runID)
                    )
                )
            )
        }

        let original = Data("12345678".utf8)
        let reference = try await store.commit(
            ArtifactCommitRequest(
                data: original,
                mimeType: "application/octet-stream",
                provenance: provenance,
                retentionPolicy: .run,
                sensitivity: .internalMetadata,
                initialOwner: .run(runID)
            )
        )
        let objectURL = root.appendingPathComponent(reference.locator.value)
        try Data("short".utf8).write(to: objectURL)
        let wrongSize = try await store.verify(reference.id)
        XCTAssertEqual(wrongSize.integrityStatus, .corrupt)
        try Data("87654321".utf8).write(to: objectURL)
        await XCTAssertThrowsArtifactError(
            .integrityMismatch(reference.id),
            try await store.data(for: reference.id)
        )
    }

    func testCoverageClosureRecoversOwnerlessMetadataAndRejectsMalformedIndexes() async throws {
        let recoveryRoot = uniqueRoot("ownerless-recovery")
        let runID = id(AgentRunIDDomain.self, 540)
        let artifactID = id(ArtifactIDDomain.self, 541)
        var recoveryStore: ContentAddressedArtifactStore? = try makeStore(
            root: recoveryRoot,
            sequence: DeterministicNames(ids: [artifactID])
        )
        _ = try await recoveryStore!.commit(
            ArtifactCommitRequest(
                data: Data("ownerless-after-crash".utf8),
                mimeType: "text/plain",
                provenance: try ArtifactProvenance(runID: runID),
                retentionPolicy: .run,
                sensitivity: .internalMetadata,
                initialOwner: .run(runID)
            )
        )
        recoveryStore = nil
        try mutateIndex(at: recoveryRoot) { object in
            var records = object["records"] as! [[String: Any]]
            records[0]["owners"] = []
            object["records"] = records
        }
        let recovered = try makeStore(root: recoveryRoot)
        XCTAssertEqual(recovered.startupCleanupReport.removedArtifactIDs, [artifactID])
        let recoveredReference = await recovered.reference(for: artifactID)
        XCTAssertNil(recoveredReference)

        let invalidJSONRoot = uniqueRoot("invalid-json-index")
        var invalidJSONStore: ContentAddressedArtifactStore? = try makeStore(root: invalidJSONRoot)
        XCTAssertNotNil(invalidJSONStore)
        invalidJSONStore = nil
        try Data("{".utf8).write(
            to: invalidJSONRoot.appendingPathComponent("metadata/artifact-index-v1.json")
        )
        XCTAssertThrowsError(try makeStore(root: invalidJSONRoot)) {
            XCTAssertEqual($0 as? ArtifactStoreError, .metadataCorrupt)
        }

        let duplicateRoot = uniqueRoot("duplicate-index")
        var duplicateStore: ContentAddressedArtifactStore? = try makeStore(
            root: duplicateRoot,
            sequence: DeterministicNames(ids: [id(ArtifactIDDomain.self, 542)])
        )
        _ = try await duplicateStore!.commit(
            ArtifactCommitRequest(
                data: Data("duplicate".utf8),
                mimeType: "text/plain",
                provenance: try ArtifactProvenance(runID: runID),
                retentionPolicy: .run,
                sensitivity: .internalMetadata,
                initialOwner: .run(runID)
            )
        )
        duplicateStore = nil
        try mutateIndex(at: duplicateRoot) { object in
            var records = object["records"] as! [[String: Any]]
            records.append(records[0])
            object["records"] = records
        }
        XCTAssertThrowsError(try makeStore(root: duplicateRoot)) {
            XCTAssertEqual($0 as? ArtifactStoreError, .metadataCorrupt)
        }
    }

    func testCoverageClosureFileProtectionIOAndAtomicFailureSurfaces() async throws {
        let protectedRoot = uniqueRoot("backup-protection")
        let protectedStore = try ContentAddressedArtifactStore(
            configuration: ArtifactStoreConfiguration(rootURL: protectedRoot)
        )
        let runID = id(AgentRunIDDomain.self, 550)
        let protectedReference = try await protectedStore.commit(
            ArtifactCommitRequest(
                data: Data("protected".utf8),
                mimeType: "text/plain",
                provenance: try ArtifactProvenance(runID: runID),
                retentionPolicy: .run,
                sensitivity: .personalData,
                initialOwner: .run(runID)
            )
        )
        let rootValues = try protectedRoot.resourceValues(forKeys: [.isExcludedFromBackupKey])
        let objectValues = try protectedRoot
            .appendingPathComponent(protectedReference.locator.value)
            .resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(rootValues.isExcludedFromBackup, true)
        XCTAssertEqual(objectValues.isExcludedFromBackup, true)

        let blockedParent = uniqueRoot("blocked-parent")
        try Data("not-a-directory".utf8).write(to: blockedParent)
        XCTAssertThrowsError(try makeStore(root: blockedParent.appendingPathComponent("child"))) {
            guard case .ioFailure(let operation, _) = $0 as? ArtifactStoreError else {
                return XCTFail("Unexpected error: \($0)")
            }
            XCTAssertEqual(operation, "lstat-root")
        }

        let unwritableParent = uniqueRoot("unwritable-parent")
        try FileManager.default.createDirectory(at: unwritableParent, withIntermediateDirectories: true)
        XCTAssertEqual(Darwin.chmod(unwritableParent.path, S_IRUSR | S_IXUSR), 0)
        defer { _ = Darwin.chmod(unwritableParent.path, S_IRWXU) }
        XCTAssertThrowsError(try makeStore(root: unwritableParent.appendingPathComponent("child"))) {
            guard case .ioFailure(let operation, _) = $0 as? ArtifactStoreError else {
                return XCTFail("Unexpected error: \($0)")
            }
            XCTAssertEqual(operation, "create-root")
        }

        let lockSymlinkRoot = uniqueRoot("lock-symlink")
        try FileManager.default.createDirectory(at: lockSymlinkRoot, withIntermediateDirectories: true)
        let external = lockSymlinkRoot.appendingPathComponent("external")
        try Data().write(to: external)
        try FileManager.default.createSymbolicLink(
            at: lockSymlinkRoot.appendingPathComponent(".artifact-store.lock"),
            withDestinationURL: external
        )
        XCTAssertThrowsError(try makeStore(root: lockSymlinkRoot)) {
            XCTAssertEqual($0 as? ArtifactStoreError, .symbolicLinkEncountered)
        }

        let staleTempRoot = uniqueRoot("stale-index-temp")
        let sequence = DeterministicNames(
            ids: [id(ArtifactIDDomain.self, 551)],
            names: ["initial-index", "stage", "index-replace"]
        )
        let staleTempStore = try makeStore(root: staleTempRoot, sequence: sequence)
        let staleName = StableDigest.sha256(Data("index-replace".utf8)).rawValue
        try Data("stale".utf8).write(
            to: staleTempRoot.appendingPathComponent("metadata/index.\(staleName).tmp")
        )
        _ = try await staleTempStore.commit(
            ArtifactCommitRequest(
                data: Data("stale-temp-replaced".utf8),
                mimeType: "text/plain",
                provenance: try ArtifactProvenance(runID: runID),
                retentionPolicy: .run,
                sensitivity: .internalMetadata,
                initialOwner: .run(runID)
            )
        )

        let renameRoot = uniqueRoot("rename-failure")
        let renameStore = try makeStore(
            root: renameRoot,
            sequence: DeterministicNames(ids: [id(ArtifactIDDomain.self, 552)])
        )
        let indexURL = renameRoot.appendingPathComponent("metadata/artifact-index-v1.json")
        try FileManager.default.removeItem(at: indexURL)
        try FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: false)
        do {
            _ = try await renameStore.commit(
                ArtifactCommitRequest(
                    data: Data("rename-must-fail".utf8),
                    mimeType: "text/plain",
                    provenance: try ArtifactProvenance(runID: runID),
                    retentionPolicy: .run,
                    sensitivity: .internalMetadata,
                    initialOwner: .run(runID)
                )
            )
            XCTFail("Expected atomic index rename failure")
        } catch let error as ArtifactStoreError {
            guard case .ioFailure(let operation, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(operation, "replace-index")
        }
    }

    func testScopedToolWriterFixesProvenanceOwnershipAndRetention() async throws {
        let root = uniqueRoot("tool-writer")
        let runID = id(AgentRunIDDomain.self, 90)
        let artifactID = id(ArtifactIDDomain.self, 91)
        let store = try makeStore(
            root: root,
            sequence: DeterministicNames(ids: [artifactID])
        )
        let provenance = try ArtifactProvenance(
            runID: runID,
            stepID: id(AgentStepIDDomain.self, 92),
            invocationID: id(ToolInvocationIDDomain.self, 93),
            providerID: "local.tool"
        )
        let writer = try ScopedToolArtifactWriter(
            store: store,
            provenance: provenance,
            owner: .run(runID)
        )
        let reference = try await writer.commit(
            data: Data("tool body".utf8),
            mimeType: "text/plain",
            semanticType: "tool-output",
            retention: .run,
            sensitivity: .internalMetadata
        )
        XCTAssertEqual(reference.provenance, provenance)
        let toolOwners = try await store.owners(for: reference.id)
        XCTAssertEqual(toolOwners, [.run(runID)])

        await XCTAssertThrowsArtifactError(
            .retentionOwnerMismatch,
            try await writer.commit(
                data: Data(),
                mimeType: "application/octet-stream",
                semanticType: nil,
                retention: .conversation,
                sensitivity: .publicMetadata
            )
        )
        XCTAssertThrowsError(
            try ScopedToolArtifactWriter(
                store: store,
                provenance: provenance,
                owner: .run(runID),
                allowedRetentionPolicies: [.userManaged]
            )
        ) { XCTAssertEqual($0 as? ArtifactStoreError, .retentionOwnerMismatch) }
    }

    func testFaultRegistryAndEveryDurabilityBoundaryHaveRecoveryEvidence() async throws {
        XCTAssertEqual(ArtifactStoreFaultPoint.registryVersion, 1)
        XCTAssertEqual(
            Set(ArtifactStoreFaultPoint.allCases),
            [
                .beforeStagingWrite, .afterStagingSync, .afterObjectPublish,
                .beforeIndexReplace, .afterIndexReplace, .beforeObjectRead,
                .afterObjectRead, .beforeObjectDelete, .afterObjectDelete,
            ]
        )

        for (offset, point) in [
            ArtifactStoreFaultPoint.beforeStagingWrite,
            .afterStagingSync,
            .afterObjectPublish,
            .beforeIndexReplace,
            .afterIndexReplace,
        ].enumerated() {
            let root = uniqueRoot("commit-fault-\(point.rawValue)")
            let runID = id(AgentRunIDDomain.self, 200 + offset)
            let artifactID = id(ArtifactIDDomain.self, 220 + offset)
            let fault = OneShotArtifactFault(point)
            var store: ContentAddressedArtifactStore? = try makeStore(
                root: root,
                sequence: DeterministicNames(ids: [artifactID]),
                fault: fault
            )
            do {
                _ = try await store!.commit(
                    ArtifactCommitRequest(
                        artifactID: artifactID,
                        data: Data("fault-body".utf8),
                        mimeType: "text/plain",
                        provenance: try ArtifactProvenance(runID: runID),
                        retentionPolicy: .run,
                        sensitivity: .internalMetadata,
                        initialOwner: .run(runID)
                    )
                )
                XCTFail("Expected injected fault at \(point)")
            } catch {
                XCTAssertEqual(error as? ArtifactStoreError, .injected(point))
            }
            if point == .afterIndexReplace {
                let durableReference = await store!.reference(for: artifactID)
                XCTAssertNotNil(durableReference)
            }
            store = nil
            let reopened = try makeStore(root: root)
            if point == .afterIndexReplace {
                let reopenedReference = await reopened.reference(for: artifactID)
                let reopenedData = try await reopened.data(for: artifactID)
                XCTAssertNotNil(reopenedReference)
                XCTAssertEqual(reopenedData, Data("fault-body".utf8))
            } else {
                let absentReference = await reopened.reference(for: artifactID)
                let cleanedSnapshot = try await reopened.snapshot()
                XCTAssertNil(absentReference)
                XCTAssertEqual(cleanedSnapshot.physicalObjectCount, 0)
            }
        }

        for point in [ArtifactStoreFaultPoint.beforeObjectRead, .afterObjectRead] {
            let fixture = try await faultFixture(point: point, offset: point == .beforeObjectRead ? 0 : 1)
            do {
                _ = try await fixture.store.data(for: fixture.reference.id)
                XCTFail("Expected read fault")
            } catch {
                XCTAssertEqual(error as? ArtifactStoreError, .injected(point))
            }
            let postFaultReference = await fixture.store.reference(for: fixture.reference.id)
            XCTAssertEqual(postFaultReference?.integrityStatus, .verified)
        }

        for (offset, point) in [
            ArtifactStoreFaultPoint.beforeObjectDelete,
            .afterObjectDelete,
        ].enumerated() {
            let root = uniqueRoot("delete-fault-\(point.rawValue)")
            let runID = id(AgentRunIDDomain.self, 300 + offset)
            let artifactID = id(ArtifactIDDomain.self, 310 + offset)
            let fault = OneShotArtifactFault(point)
            var store: ContentAddressedArtifactStore? = try makeStore(
                root: root,
                sequence: DeterministicNames(ids: [artifactID]),
                fault: fault
            )
            let reference = try await store!.commit(
                ArtifactCommitRequest(
                    artifactID: artifactID,
                    data: Data("delete-fault".utf8),
                    mimeType: "text/plain",
                    provenance: try ArtifactProvenance(runID: runID),
                    retentionPolicy: .run,
                    sensitivity: .internalMetadata,
                    initialOwner: .run(runID)
                )
            )
            fault.arm()
            do {
                _ = try await store!.removeReference(from: reference.id, owner: .run(runID))
                XCTFail("Expected delete fault")
            } catch {
                XCTAssertEqual(error as? ArtifactStoreError, .injected(point))
            }
            let deletedReference = await store!.reference(for: reference.id)
            XCTAssertNil(deletedReference)
            store = nil
            let reopened = try makeStore(root: root)
            let reopenedReference = await reopened.reference(for: reference.id)
            let reopenedSnapshot = try await reopened.snapshot()
            XCTAssertNil(reopenedReference)
            XCTAssertEqual(reopenedSnapshot.physicalObjectCount, 0)
        }
    }

    func testPortableModelValidationAndConfigurationEdges() throws {
        XCTAssertThrowsError(
            try ArtifactStoreConfiguration(rootURL: URL(string: "https://example.invalid")!)
        ) { XCTAssertEqual($0 as? ArtifactStoreError, .invalidConfiguration) }
        XCTAssertThrowsError(
            try ArtifactStoreConfiguration(rootURL: URL(fileURLWithPath: "/"))
        ) { XCTAssertEqual($0 as? ArtifactStoreError, .invalidConfiguration) }
        XCTAssertThrowsError(
            try ArtifactStoreConfiguration(rootURL: uniqueRoot("zero"), maximumArtifactBytes: 0)
        ) { XCTAssertEqual($0 as? ArtifactStoreError, .invalidConfiguration) }
        XCTAssertThrowsError(try ArtifactOwner(kind: .durableRecord, identifier: "")) {
            XCTAssertEqual($0 as? ArtifactStoreError, .invalidOwner)
        }
        XCTAssertThrowsError(try ArtifactOwner(kind: .durableRecord, identifier: " bad")) {
            XCTAssertEqual($0 as? ArtifactStoreError, .invalidOwner)
        }
        XCTAssertThrowsError(try ArtifactOwner(kind: .durableRecord, identifier: "bad\u{0007}")) {
            XCTAssertEqual($0 as? ArtifactStoreError, .invalidOwner)
        }
        let lhs = try ArtifactOwner(kind: .conversation, identifier: "b")
        let rhs = try ArtifactOwner(kind: .run, identifier: "a")
        XCTAssertLessThan(lhs, rhs)
        XCTAssertEqual(ArtifactCleanupReport(removedArtifactIDs: [id(ArtifactIDDomain.self, 2), id(ArtifactIDDomain.self, 1)]).removedArtifactIDs.map(\.description), [id(ArtifactIDDomain.self, 1).description, id(ArtifactIDDomain.self, 2).description])
    }

    // MARK: - Helpers

    private func faultFixture(
        point: ArtifactStoreFaultPoint,
        offset: Int
    ) async throws -> (store: ContentAddressedArtifactStore, reference: ArtifactReference) {
        let root = uniqueRoot("read-fault-\(point.rawValue)")
        let runID = id(AgentRunIDDomain.self, 400 + offset)
        let artifactID = id(ArtifactIDDomain.self, 410 + offset)
        let fault = OneShotArtifactFault(point, initiallyArmed: false)
        let store = try makeStore(
            root: root,
            sequence: DeterministicNames(ids: [artifactID]),
            fault: fault
        )
        let reference = try await store.commit(
            ArtifactCommitRequest(
                artifactID: artifactID,
                data: Data("read-fault".utf8),
                mimeType: "text/plain",
                provenance: try ArtifactProvenance(runID: runID),
                retentionPolicy: .run,
                sensitivity: .internalMetadata,
                initialOwner: .run(runID)
            )
        )
        fault.arm()
        return (store, reference)
    }

    private func makeStore(
        root: URL,
        sequence: DeterministicNames = DeterministicNames(),
        timestamp: Int64 = 1_000,
        maximumBytes: UInt64 = ArtifactStoreConfiguration.defaultMaximumArtifactBytes,
        fault: OneShotArtifactFault? = nil
    ) throws -> ContentAddressedArtifactStore {
        let injector: ArtifactStoreFaultInjector?
        if let fault {
            injector = { point in try fault.inject(point) }
        } else {
            injector = nil
        }
        return try ContentAddressedArtifactStore(
            configuration: ArtifactStoreConfiguration(
                rootURL: root,
                maximumArtifactBytes: maximumBytes,
                excludeFromBackup: false,
                verifyPlatformProtection: false
            ),
            clock: { AgentTimestamp(rawValue: timestamp) },
            idGenerator: { sequence.nextID() },
            temporaryNameGenerator: { sequence.nextName() },
            faultInjector: injector
        )
    }

    private func uniqueRoot(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mobileLLM-artifacts-\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    /// Produces at least two objects in one prefix and one in another, so deterministic ordering
    /// is exercised at both directory levels rather than merely asserted for singleton input.
    private func distinctOrderedOrphans() -> [(data: Data, digest: StableDigest)] {
        var buckets: [String: [(Data, StableDigest)]] = [:]
        for number in 0 ..< 10_000 {
            let data = Data("orphan-order-\(number)".utf8)
            let digest = StableDigest.sha256(data)
            let prefix = String(digest.rawValue.prefix(2))
            buckets[prefix, default: []].append((data, digest))
            if let pair = buckets.values.first(where: { $0.count >= 2 }),
               let other = buckets.first(where: { $0.key != String(pair[0].1.rawValue.prefix(2)) })?.value.first
            {
                return [
                    (pair[1].0, pair[1].1),
                    (other.0, other.1),
                    (pair[0].0, pair[0].1),
                ]
            }
        }
        fatalError("SHA-256 prefix fixture generation unexpectedly failed")
    }

    private func mutateIndex(
        at root: URL,
        mutation: (inout [String: Any]) -> Void
    ) throws {
        let url = root.appendingPathComponent("metadata/artifact-index-v1.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        mutation(&object)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(
            to: url,
            options: .atomic
        )
    }

    private func id<Domain: AgentIdentifierDomain>(
        _ domain: Domain.Type,
        _ number: Int
    ) -> AgentIdentifier<Domain> {
        _ = domain
        return AgentIdentifier<Domain>(
            rawValue: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
        )
    }

    private func XCTAssertThrowsArtifactError<T>(
        _ expected: ArtifactStoreError,
        _ expression: @autoclosure () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ArtifactStoreError, expected, file: file, line: line)
        }
    }
}

private final class DeterministicNames: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [ArtifactID]
    private var names: [String]
    private var counter = 0

    init(ids: [ArtifactID] = [], names: [String] = []) {
        self.ids = ids
        self.names = names
    }

    func nextID() -> ArtifactID {
        lock.withLock {
            if !ids.isEmpty { return ids.removeFirst() }
            counter += 1
            return ArtifactID(
                rawValue: UUID(
                    uuidString: String(format: "aaaaaaaa-aaaa-aaaa-aaaa-%012d", counter)
                )!
            )
        }
    }

    func nextName() -> String {
        lock.withLock {
            if !names.isEmpty { return names.removeFirst() }
            counter += 1
            return "temporary-\(counter)"
        }
    }
}

private final class OneShotArtifactFault: @unchecked Sendable {
    private let lock = NSLock()
    private let point: ArtifactStoreFaultPoint
    private var armed: Bool

    init(_ point: ArtifactStoreFaultPoint, initiallyArmed: Bool = true) {
        self.point = point
        armed = initiallyArmed
    }

    func arm() {
        lock.withLock { armed = true }
    }

    func inject(_ candidate: ArtifactStoreFaultPoint) throws {
        try lock.withLock {
            guard armed, candidate == point else { return }
            armed = false
            throw ArtifactStoreError.injected(point)
        }
    }
}

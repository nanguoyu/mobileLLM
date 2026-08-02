// SPDX-License-Identifier: MIT

import AgentContracts
@testable import AgentRuntime
import Foundation
import XCTest

final class ContentAddressedArtifactStoreTests: XCTestCase, @unchecked Sendable {
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

    func testOrphanAndTemporaryCleanupIsDeterministicOnReopen() async throws {
        let root = uniqueRoot("orphan-cleanup")
        var store: ContentAddressedArtifactStore? = try makeStore(root: root)
        XCTAssertNotNil(store)
        store = nil

        let orphanDigest = StableDigest.sha256(Data("orphan".utf8))
        let objectDirectory = root.appendingPathComponent(
            "objects/\(orphanDigest.rawValue.prefix(2))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: objectDirectory, withIntermediateDirectories: true)
        try Data("orphan".utf8).write(
            to: objectDirectory.appendingPathComponent("\(orphanDigest.rawValue).blob")
        )
        try Data("stage".utf8).write(
            to: root.appendingPathComponent("staging/manual.stage")
        )
        try Data("temp".utf8).write(
            to: root.appendingPathComponent("metadata/index.manual.tmp")
        )

        let reopened = try makeStore(root: root)
        XCTAssertEqual(reopened.startupCleanupReport.removedObjectDigests, [orphanDigest])
        XCTAssertEqual(reopened.startupCleanupReport.removedStagingFileCount, 1)
        XCTAssertEqual(reopened.startupCleanupReport.removedMetadataTemporaryFileCount, 1)
        let reopenedSnapshot = try await reopened.snapshot()
        XCTAssertEqual(reopenedSnapshot.physicalObjectCount, 0)
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

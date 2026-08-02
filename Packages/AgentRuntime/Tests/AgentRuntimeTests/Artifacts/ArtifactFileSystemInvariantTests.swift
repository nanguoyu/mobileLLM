// SPDX-License-Identifier: MIT

import AgentContracts
@testable import AgentRuntime
import Darwin
import Foundation
import XCTest

final class ArtifactFileSystemInvariantTests: XCTestCase {
    func testZeroByteAndBoundedReadsPreserveExactPOSIXInvariants() throws {
        let fileSystem = try makeArtifactFileSystem("zero-and-bounded")

        let emptyURL = try fileSystem.stagingFileURL(name: "empty")
        try fileSystem.writeExclusive(Data(), to: emptyURL)
        let empty = try fileSystem.readVerifiedFile(
            at: emptyURL,
            expectedDigest: StableDigest.sha256(Data()),
            expectedByteCount: 0,
            maximumBytes: 0
        )
        XCTAssertEqual(empty, Data())

        let body = Data("bounded-body".utf8)
        let digest = StableDigest.sha256(body)
        let objectURL = try fileSystem.objectURL(for: digest, createParent: true)
        try fileSystem.writeExclusive(body, to: objectURL)
        assertArtifactFileSystemError(.artifactTooLarge(limit: 2, actual: UInt64(body.count))) {
            _ = try fileSystem.readVerifiedFile(
                at: objectURL,
                expectedDigest: digest,
                expectedByteCount: UInt64(body.count),
                maximumBytes: 2
            )
        }
    }

    func testMissingStageAndUnmanagedWriteFailBeforePublishingBytes() throws {
        let fileSystem = try makeArtifactFileSystem("missing-and-unmanaged")
        let body = Data("missing-stage".utf8)
        let digest = StableDigest.sha256(body)
        let missingStage = fileSystem.stagingURL.appendingPathComponent("missing.stage")

        XCTAssertThrowsError(
            try fileSystem.publish(
                stagedURL: missingStage,
                digest: digest,
                byteCount: UInt64(body.count)
            )
        ) { error in
            guard case .ioFailure(let operation, _) = error as? ArtifactStoreError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(operation, "lstat-file")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: try fileSystem.objectURL(for: digest, createParent: false).path
            )
        )

        let outside = fileSystem.rootURL
            .deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString)")
        assertArtifactFileSystemError(.unconfinedPath) {
            try fileSystem.writeExclusive(body, to: outside)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    func testMissingObjectWithinCanonicalPrefixRemovalIsIdempotent() throws {
        let fileSystem = try makeArtifactFileSystem("missing-removal")
        let missing = StableDigest.sha256(Data("never-created".utf8))
        _ = try fileSystem.objectURL(for: missing, createParent: true)

        XCTAssertNoThrow(try fileSystem.removeObject(missing))
        XCTAssertNoThrow(try fileSystem.removeObject(missing))
    }

    func testCleanupRejectsUnknownMetadataWithoutDeletingIt() throws {
        let fileSystem = try makeArtifactFileSystem("unknown-metadata")
        let unknown = fileSystem.metadataURL.appendingPathComponent("unexpected-record")
        try Data("preserve-for-diagnosis".utf8).write(to: unknown)

        assertArtifactFileSystemError(.metadataCorrupt) {
            _ = try fileSystem.cleanupTemporaryFiles()
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
    }

    func testObjectEnumerationRejectsNoncanonicalExtensionAndDigestPlacement() throws {
        do {
            let fileSystem = try makeArtifactFileSystem("bad-extension")
            let prefix = fileSystem.objectsURL.appendingPathComponent("aa", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            try Data("body".utf8).write(to: prefix.appendingPathComponent("object.txt"))

            assertArtifactFileSystemError(.metadataCorrupt) {
                _ = try fileSystem.allObjectDigests()
            }
        }

        do {
            let fileSystem = try makeArtifactFileSystem("misplaced-digest")
            let prefix = fileSystem.objectsURL.appendingPathComponent("aa", isDirectory: true)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            let misplacedName = String(repeating: "b", count: 64) + ".blob"
            try Data("body".utf8).write(to: prefix.appendingPathComponent(misplacedName))

            assertArtifactFileSystemError(.metadataCorrupt) {
                _ = try fileSystem.allObjectDigests()
            }
        }
    }

    func testIndexReadRejectsSymlinkAndSparseOversizeButAcceptsEmptyIndex() throws {
        do {
            let fileSystem = try makeArtifactFileSystem("empty-index")
            try fileSystem.writeExclusive(Data(), to: fileSystem.indexURL)
            XCTAssertEqual(try fileSystem.readIndex(), Data())
        }

        do {
            let fileSystem = try makeArtifactFileSystem("symlink-index")
            let target = fileSystem.rootURL.appendingPathComponent("index-target")
            try Data("external-index".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(
                at: fileSystem.indexURL,
                withDestinationURL: target
            )
            assertArtifactFileSystemError(.symbolicLinkEncountered) {
                _ = try fileSystem.readIndex()
            }
        }

        do {
            let fileSystem = try makeArtifactFileSystem("oversized-index")
            XCTAssertTrue(FileManager.default.createFile(atPath: fileSystem.indexURL.path, contents: nil))
            let oversized = off_t(16 * 1_024 * 1_024 + 1)
            XCTAssertEqual(Darwin.truncate(fileSystem.indexURL.path, oversized), 0)
            assertArtifactFileSystemError(.metadataCorrupt) {
                _ = try fileSystem.readIndex()
            }
        }
    }

    func testArtifactOwnerOrderingAndDecodingRevalidateStableKeys() throws {
        let first = try ArtifactOwner(kind: .durableRecord, identifier: "a")
        let second = try ArtifactOwner(kind: .durableRecord, identifier: "b")
        XCTAssertLessThan(first, second)
        XCTAssertFalse(second < first)

        let invalid = Data(#"{"kind":"run","identifier":""}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ArtifactOwner.self, from: invalid)) {
            guard case DecodingError.dataCorrupted = $0 else {
                return XCTFail("Expected data-corrupted owner, got \($0)")
            }
        }
    }
}

private func makeArtifactFileSystem(_ name: String) throws -> ArtifactFileSystem {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "mobileLLM-artifact-fs-\(name)-\(UUID().uuidString)",
        isDirectory: true
    )
    return try ArtifactFileSystem(
        configuration: ArtifactStoreConfiguration(
            rootURL: root,
            excludeFromBackup: false,
            verifyPlatformProtection: false
        )
    )
}

private func assertArtifactFileSystemError(
    _ expected: ArtifactStoreError,
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: () throws -> Void
) {
    do {
        try operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as ArtifactStoreError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Expected \(expected), got \(error)", file: file, line: line)
    }
}

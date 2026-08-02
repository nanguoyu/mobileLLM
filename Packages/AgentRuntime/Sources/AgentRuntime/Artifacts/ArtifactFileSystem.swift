// SPDX-License-Identifier: MIT

import AgentContracts
import Darwin
import Foundation

/// POSIX-backed file operations used by the store. Every caller-supplied locator is rejected
/// before reaching this layer; paths here are derived only from canonical SHA-256 digests.
final class ArtifactFileSystem: @unchecked Sendable {
    let rootURL: URL
    let objectsURL: URL
    let stagingURL: URL
    let metadataURL: URL
    let indexURL: URL

    private let configuration: ArtifactStoreConfiguration
    private let lock: ArtifactStoreLock

    init(configuration: ArtifactStoreConfiguration) throws {
        self.configuration = configuration
        let requestedRoot = configuration.rootURL.standardizedFileURL
        try Self.rejectSymlinkIfPresent(requestedRoot)
        do {
            try FileManager.default.createDirectory(
                at: requestedRoot,
                withIntermediateDirectories: true
            )
        } catch {
            throw Self.ioError("create-root")
        }
        try Self.rejectSymlinkIfPresent(requestedRoot)

        rootURL = requestedRoot.resolvingSymlinksInPath().standardizedFileURL
        objectsURL = rootURL.appendingPathComponent("objects", isDirectory: true)
        stagingURL = rootURL.appendingPathComponent("staging", isDirectory: true)
        metadataURL = rootURL.appendingPathComponent("metadata", isDirectory: true)
        indexURL = metadataURL.appendingPathComponent("artifact-index-v1.json", isDirectory: false)

        for directory in [rootURL, objectsURL, stagingURL, metadataURL] {
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false
                )
            } catch CocoaError.fileWriteFileExists {
                // The directory is verified below. FileManager reports an existing directory on
                // some platform versions when `withIntermediateDirectories` is false.
            } catch {
                if !FileManager.default.fileExists(atPath: directory.path) {
                    throw Self.ioError("create-directory")
                }
            }
            try Self.requireDirectoryWithoutSymlink(directory)
            try Self.applyStorageAttributes(to: directory, configuration: configuration)
        }

        lock = try ArtifactStoreLock(
            url: rootURL.appendingPathComponent(".artifact-store.lock", isDirectory: false)
        )
        try Self.applyStorageAttributes(to: lock.url, configuration: configuration)
    }

    func locator(for digest: StableDigest) throws -> ArtifactLocator {
        try ArtifactLocator(kind: .managedRelativePath, value: relativeObjectPath(for: digest))
    }

    func relativeObjectPath(for digest: StableDigest) -> String {
        "objects/\(digest.rawValue.prefix(2))/\(digest.rawValue).blob"
    }

    func objectURL(for digest: StableDigest, createParent: Bool) throws -> URL {
        let prefix = String(digest.rawValue.prefix(2))
        let directory = objectsURL.appendingPathComponent(prefix, isDirectory: true)
        if createParent, !Self.entryExistsWithoutFollowingSymlink(directory) {
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false
                )
            } catch CocoaError.fileWriteFileExists {
                // A racing creator is harmless; the type and symlink checks below are authoritative.
            } catch {
                throw Self.ioError("create-object-directory")
            }
            try Self.applyStorageAttributes(to: directory, configuration: configuration)
        }
        try Self.requireDirectoryWithoutSymlink(objectsURL)
        try Self.requireDirectoryWithoutSymlink(directory)
        let result = directory.appendingPathComponent("\(digest.rawValue).blob", isDirectory: false)
        guard Self.isDescendant(result, of: rootURL) else {
            throw ArtifactStoreError.unconfinedPath
        }
        return result
    }

    func stagingFileURL(name: String) throws -> URL {
        let safeName = StableDigest.sha256(Data(name.utf8)).rawValue
        try Self.requireDirectoryWithoutSymlink(stagingURL)
        let result = stagingURL.appendingPathComponent("\(safeName).stage", isDirectory: false)
        guard Self.isDescendant(result, of: rootURL) else {
            throw ArtifactStoreError.unconfinedPath
        }
        return result
    }

    func metadataTemporaryURL(name: String) throws -> URL {
        let safeName = StableDigest.sha256(Data(name.utf8)).rawValue
        try Self.requireDirectoryWithoutSymlink(metadataURL)
        let result = metadataURL.appendingPathComponent("index.\(safeName).tmp", isDirectory: false)
        guard Self.isDescendant(result, of: rootURL) else {
            throw ArtifactStoreError.unconfinedPath
        }
        return result
    }

    func writeExclusive(_ data: Data, to url: URL) throws {
        try requireManagedParent(of: url)
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            if errno == ELOOP { throw ArtifactStoreError.symbolicLinkEncountered }
            throw Self.ioError("create-file")
        }
        var succeeded = false
        defer {
            Darwin.close(descriptor)
            if !succeeded { _ = Darwin.unlink(url.path) }
        }
        try data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Self.ioError("write-file") }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw Self.ioError("sync-file") }
        try Self.applyStorageAttributes(to: url, configuration: configuration)
        guard Darwin.fsync(descriptor) == 0 else { throw Self.ioError("sync-file-attributes") }
        succeeded = true
    }

    /// Publishes staged bytes without replacing an existing content-addressed object.
    /// Returns `true` when a new object was linked and `false` when it was already present.
    func publish(stagedURL: URL, digest: StableDigest, byteCount: UInt64) throws -> Bool {
        let destination = try objectURL(for: digest, createParent: true)
        try requireRegularFileWithoutSymlink(stagedURL)
        let linked = Darwin.link(stagedURL.path, destination.path)
        if linked != 0 {
            guard errno == EEXIST else {
                if errno == ELOOP { throw ArtifactStoreError.symbolicLinkEncountered }
                throw Self.ioError("publish-object")
            }
            _ = try readVerifiedFile(
                at: destination,
                expectedDigest: digest,
                expectedByteCount: byteCount,
                maximumBytes: byteCount
            )
            try Self.applyStorageAttributes(to: destination, configuration: configuration)
            try unlink(stagedURL, operation: "discard-deduplicated-stage")
            return false
        }
        try unlink(stagedURL, operation: "remove-published-stage")
        try syncDirectory(destination.deletingLastPathComponent())
        return true
    }

    func readVerifiedFile(
        at url: URL,
        expectedDigest: StableDigest,
        expectedByteCount: UInt64,
        maximumBytes: UInt64
    ) throws -> Data {
        try requireManagedParent(of: url)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw ArtifactStoreError.symbolicLinkEncountered }
            if errno == ENOENT { throw ArtifactStoreError.ioFailure(operation: "missing-file", code: ENOENT) }
            throw Self.ioError("open-file")
        }
        defer { Darwin.close(descriptor) }

        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else { throw Self.ioError("stat-file") }
        guard (information.st_mode & S_IFMT) == S_IFREG else {
            throw ArtifactStoreError.symbolicLinkEncountered
        }
        guard information.st_size >= 0 else { throw ArtifactStoreError.metadataCorrupt }
        let actualCount = UInt64(information.st_size)
        guard actualCount == expectedByteCount else { throw ArtifactStoreError.expectedByteCountMismatch }
        guard actualCount <= maximumBytes, actualCount <= UInt64(Int.max) else {
            throw ArtifactStoreError.artifactTooLarge(limit: maximumBytes, actual: actualCount)
        }

        var data = Data(count: Int(actualCount))
        try data.withUnsafeMutableBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let count = Darwin.read(descriptor, pointer, remaining)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Self.ioError("read-file") }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
        }
        guard StableDigest.sha256(data) == expectedDigest else {
            throw ArtifactStoreError.expectedDigestMismatch
        }
        return data
    }

    func replaceIndex(with data: Data, temporaryName: String) throws {
        let temporaryURL = try metadataTemporaryURL(name: temporaryName)
        if FileManager.default.fileExists(atPath: temporaryURL.path) {
            try unlink(temporaryURL, operation: "remove-stale-index-temp")
        }
        try writeExclusive(data, to: temporaryURL)
        guard Darwin.rename(temporaryURL.path, indexURL.path) == 0 else {
            let failure = Self.ioError("replace-index")
            _ = Darwin.unlink(temporaryURL.path)
            throw failure
        }
        try syncDirectory(metadataURL)
        try Self.applyStorageAttributes(to: indexURL, configuration: configuration)
    }

    func readIndex() throws -> Data? {
        guard Self.entryExistsWithoutFollowingSymlink(indexURL) else { return nil }
        return try readBoundedRegularFile(at: indexURL, maximumBytes: 16 * 1_024 * 1_024)
    }

    func removeObject(_ digest: StableDigest) throws {
        let url = try objectURL(for: digest, createParent: false)
        guard Self.entryExistsWithoutFollowingSymlink(url) else { return }
        try unlink(url, operation: "remove-object")
        try syncDirectory(url.deletingLastPathComponent())
    }

    func cleanupTemporaryFiles() throws -> (staging: Int, metadata: Int) {
        let staging = try removeFiles(in: stagingURL) { _ in true }
        let metadata = try removeFiles(in: metadataURL) {
            $0.hasPrefix("index.") && $0.hasSuffix(".tmp")
        }
        let remainingMetadata = try FileManager.default.contentsOfDirectory(
            at: metadataURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        guard remainingMetadata.allSatisfy({ $0.lastPathComponent == indexURL.lastPathComponent })
        else { throw ArtifactStoreError.metadataCorrupt }
        return (staging, metadata)
    }

    func allObjectDigests() throws -> Set<StableDigest> {
        try Self.requireDirectoryWithoutSymlink(objectsURL)
        let prefixes = try FileManager.default.contentsOfDirectory(
            at: objectsURL,
            includingPropertiesForKeys: nil,
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var result: Set<StableDigest> = []
        for prefixURL in prefixes {
            let prefix = prefixURL.lastPathComponent
            guard prefix.count == 2, prefix.allSatisfy(Self.isLowercaseHex) else {
                throw ArtifactStoreError.metadataCorrupt
            }
            try Self.requireDirectoryWithoutSymlink(prefixURL)
            let files = try FileManager.default.contentsOfDirectory(
                at: prefixURL,
                includingPropertiesForKeys: nil,
                options: []
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in files {
                try requireRegularFileWithoutSymlink(file)
                let name = file.lastPathComponent
                guard name.hasSuffix(".blob") else { throw ArtifactStoreError.metadataCorrupt }
                let raw = String(name.dropLast(5))
                guard raw.count == 64, raw.hasPrefix(prefix),
                      let digest = try? StableDigest(rawValue: raw)
                else { throw ArtifactStoreError.metadataCorrupt }
                result.insert(digest)
            }
        }
        return result
    }

    func syncRoot() throws {
        try syncDirectory(rootURL)
    }

    private func readBoundedRegularFile(at url: URL, maximumBytes: UInt64) throws -> Data {
        try requireManagedParent(of: url)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw ArtifactStoreError.symbolicLinkEncountered }
            throw Self.ioError("open-metadata")
        }
        defer { Darwin.close(descriptor) }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_size >= 0
        else { throw ArtifactStoreError.metadataCorrupt }
        let count = UInt64(information.st_size)
        guard count <= maximumBytes, count <= UInt64(Int.max) else {
            throw ArtifactStoreError.metadataCorrupt
        }
        var data = Data(count: Int(count))
        try data.withUnsafeMutableBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let readCount = Darwin.read(descriptor, pointer, remaining)
                if readCount < 0, errno == EINTR { continue }
                guard readCount > 0 else { throw Self.ioError("read-metadata") }
                remaining -= readCount
                pointer = pointer.advanced(by: readCount)
            }
        }
        return data
    }

    private func removeFiles(in directory: URL, matching predicate: (String) -> Bool) throws -> Int {
        try Self.requireDirectoryWithoutSymlink(directory)
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var count = 0
        for child in children where predicate(child.lastPathComponent) {
            try unlink(child, operation: "remove-temporary-file")
            count += 1
        }
        if count > 0 { try syncDirectory(directory) }
        return count
    }

    private func unlink(_ url: URL, operation: String) throws {
        guard Self.isDescendant(url, of: rootURL), url != rootURL else {
            throw ArtifactStoreError.unconfinedPath
        }
        if Darwin.unlink(url.path) != 0, errno != ENOENT {
            throw Self.ioError(operation)
        }
    }

    private func requireManagedParent(of url: URL) throws {
        guard Self.isDescendant(url, of: rootURL), url != rootURL else {
            throw ArtifactStoreError.unconfinedPath
        }
        var current = url.deletingLastPathComponent()
        while current.path.count >= rootURL.path.count {
            try Self.requireDirectoryWithoutSymlink(current)
            if current == rootURL { return }
            current.deleteLastPathComponent()
        }
        throw ArtifactStoreError.unconfinedPath
    }

    private func requireRegularFileWithoutSymlink(_ url: URL) throws {
        var information = stat()
        guard Darwin.lstat(url.path, &information) == 0 else { throw Self.ioError("lstat-file") }
        guard (information.st_mode & S_IFMT) != S_IFLNK else {
            throw ArtifactStoreError.symbolicLinkEncountered
        }
        guard (information.st_mode & S_IFMT) == S_IFREG else {
            throw ArtifactStoreError.metadataCorrupt
        }
    }

    private func syncDirectory(_ url: URL) throws {
        try Self.requireDirectoryWithoutSymlink(url)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Self.ioError("open-directory") }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw Self.ioError("sync-directory") }
    }

    private static func requireDirectoryWithoutSymlink(_ url: URL) throws {
        var information = stat()
        guard Darwin.lstat(url.path, &information) == 0 else { throw ioError("lstat-directory") }
        guard (information.st_mode & S_IFMT) != S_IFLNK else {
            throw ArtifactStoreError.symbolicLinkEncountered
        }
        guard (information.st_mode & S_IFMT) == S_IFDIR else {
            throw ArtifactStoreError.invalidConfiguration
        }
    }

    private static func rejectSymlinkIfPresent(_ url: URL) throws {
        var information = stat()
        if Darwin.lstat(url.path, &information) == 0 {
            guard (information.st_mode & S_IFMT) != S_IFLNK else {
                throw ArtifactStoreError.symbolicLinkEncountered
            }
        } else if errno != ENOENT {
            throw ioError("lstat-root")
        }
    }

    private static func entryExistsWithoutFollowingSymlink(_ url: URL) -> Bool {
        var information = stat()
        if Darwin.lstat(url.path, &information) == 0 { return true }
        return errno != ENOENT
    }

    private static func applyStorageAttributes(
        to url: URL,
        configuration: ArtifactStoreConfiguration
    ) throws {
        do {
            #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: url.path
            )
            if configuration.verifyPlatformProtection {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.protectionKey] as? FileProtectionType == .completeUnlessOpen else {
                    throw ArtifactStoreError.dataProtectionUnavailable
                }
            }
            #endif
            if configuration.excludeFromBackup {
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var mutableURL = url
                try mutableURL.setResourceValues(values)
                if configuration.verifyPlatformProtection {
                    let effective = try mutableURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
                    guard effective.isExcludedFromBackup == true else {
                        throw ArtifactStoreError.dataProtectionUnavailable
                    }
                }
            }
        } catch let error as ArtifactStoreError {
            throw error
        } catch {
            throw ArtifactStoreError.dataProtectionUnavailable
        }
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard candidateComponents.count > rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static func isLowercaseHex(_ character: Character) -> Bool {
        character.isNumber || ("a" ... "f").contains(character)
    }

    private static func ioError(_ operation: String) -> ArtifactStoreError {
        ArtifactStoreError.ioFailure(operation: operation, code: errno)
    }
}

private final class ArtifactStoreLock: @unchecked Sendable {
    let url: URL
    private let descriptor: Int32
    private let registryKey: String

    init(url: URL) throws {
        self.url = url
        registryKey = url.standardizedFileURL.path
        guard ArtifactStoreProcessRegistry.shared.acquire(registryKey) else {
            throw ArtifactStoreError.storeAlreadyOpen
        }
        let openedDescriptor = Darwin.open(
            url.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard openedDescriptor >= 0 else {
            ArtifactStoreProcessRegistry.shared.release(registryKey)
            if errno == ELOOP { throw ArtifactStoreError.symbolicLinkEncountered }
            throw ArtifactStoreError.ioFailure(operation: "open-lock", code: errno)
        }
        var information = stat()
        guard Darwin.fstat(openedDescriptor, &information) == 0 else {
            let code = errno
            Darwin.close(openedDescriptor)
            ArtifactStoreProcessRegistry.shared.release(registryKey)
            throw ArtifactStoreError.ioFailure(operation: "stat-lock", code: code)
        }
        guard (information.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(openedDescriptor)
            ArtifactStoreProcessRegistry.shared.release(registryKey)
            throw ArtifactStoreError.invalidConfiguration
        }
        var exclusiveLock = Darwin.flock()
        exclusiveLock.l_type = Int16(F_WRLCK)
        exclusiveLock.l_whence = Int16(SEEK_SET)
        exclusiveLock.l_start = 0
        exclusiveLock.l_len = 0
        guard Darwin.fcntl(openedDescriptor, F_SETLK, &exclusiveLock) == 0 else {
            let code = errno
            Darwin.close(openedDescriptor)
            ArtifactStoreProcessRegistry.shared.release(registryKey)
            switch code {
            case EAGAIN, EACCES:
                throw ArtifactStoreError.storeAlreadyOpen
            default:
                throw ArtifactStoreError.ioFailure(operation: "lock-store", code: code)
            }
        }
        descriptor = openedDescriptor
    }

    deinit {
        var unlock = Darwin.flock()
        unlock.l_type = Int16(F_UNLCK)
        unlock.l_whence = Int16(SEEK_SET)
        unlock.l_start = 0
        unlock.l_len = 0
        _ = Darwin.fcntl(descriptor, F_SETLK, &unlock)
        Darwin.close(descriptor)
        ArtifactStoreProcessRegistry.shared.release(registryKey)
    }
}

/// POSIX record locks are process-associated, so they cannot distinguish two store instances in
/// one process. This small registry closes that gap while `fcntl` protects against other processes.
private final class ArtifactStoreProcessRegistry: @unchecked Sendable {
    static let shared = ArtifactStoreProcessRegistry()

    private let lock = NSLock()
    private var roots: Set<String> = []

    func acquire(_ key: String) -> Bool {
        lock.withLock {
            guard !roots.contains(key) else { return false }
            roots.insert(key)
            return true
        }
    }

    func release(_ key: String) {
        _ = lock.withLock { roots.remove(key) }
    }
}

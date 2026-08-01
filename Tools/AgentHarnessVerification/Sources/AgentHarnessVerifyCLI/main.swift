// SPDX-License-Identifier: MIT

import Foundation
import AgentHarnessVerificationCore

private struct Arguments {
    var mode: VerificationMode
    var repositoryRoot: URL
    var requirementsURL: URL?
    var testsURL: URL?
    var quarantineURL: URL?
    var now = Date()

    init(_ values: [String]) throws {
        guard let first = values.first, let mode = VerificationMode(rawValue: first) else {
            throw UsageError("first argument must be 'static' or 'release'")
        }
        self.mode = mode
        repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath,
                             isDirectory: true)
        var index = 1
        while index < values.count {
            let option = values[index]
            guard index + 1 < values.count else { throw UsageError("missing value for \(option)") }
            let value = values[index + 1]
            switch option {
            case "--repo-root": repositoryRoot = URL(fileURLWithPath: value, isDirectory: true)
            case "--requirements": requirementsURL = URL(fileURLWithPath: value)
            case "--tests": testsURL = URL(fileURLWithPath: value)
            case "--quarantine": quarantineURL = URL(fileURLWithPath: value)
            case "--today":
                let formatter = DateFormatter()
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "yyyy-MM-dd"
                formatter.isLenient = false
                guard let parsed = formatter.date(from: value) else {
                    throw UsageError("--today must use YYYY-MM-DD")
                }
                now = parsed
            default: throw UsageError("unknown option: \(option)")
            }
            index += 2
        }
        repositoryRoot = repositoryRoot.standardizedFileURL
        requirementsURL = Self.resolve(requirementsURL, against: repositoryRoot)
        testsURL = Self.resolve(testsURL, against: repositoryRoot)
        quarantineURL = Self.resolve(quarantineURL, against: repositoryRoot)
    }

    private static func resolve(_ url: URL?, against root: URL) -> URL? {
        guard let url else { return nil }
        return url.path.hasPrefix("/") ? url.standardizedFileURL
            : root.appending(path: url.path).standardizedFileURL
    }
}

private struct UsageError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func usage() {
    FileHandle.standardError.write(Data("""
    usage: agent-harness-verify <static|release> [options]
      --repo-root PATH
      --requirements PATH
      --tests PATH
      --quarantine PATH
      --today YYYY-MM-DD

    Default manifests are under Verification/AgentHarness in the repository root.
    \n
    """.utf8))
}

do {
    let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
    let configuration = VerificationConfiguration(
        mode: arguments.mode,
        repositoryRoot: arguments.repositoryRoot,
        requirementsURL: arguments.requirementsURL,
        testsURL: arguments.testsURL,
        quarantineURL: arguments.quarantineURL,
        now: arguments.now
    )
    let report = AgentHarnessManifestVerifier.verify(configuration)
    if report.succeeded {
        print("Agent Harness verification passed (\(arguments.mode.rawValue)).")
        exit(EXIT_SUCCESS)
    }
    for diagnostic in report.diagnostics {
        FileHandle.standardError.write(Data(
            "\(diagnostic.location): [\(diagnostic.code)] \(diagnostic.message)\n".utf8
        ))
    }
    exit(EXIT_FAILURE)
} catch let error as UsageError {
    FileHandle.standardError.write(Data("error: \(error.description)\n".utf8))
    usage()
    exit(2)
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(2)
}

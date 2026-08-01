// SPDX-License-Identifier: MIT

import Foundation
import AgentHarnessVerificationCore

private struct ManifestArguments {
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

private struct CoverageArguments {
    let configuration: CoverageVerificationConfiguration
    let outputURL: URL

    init(_ values: [String]) throws {
        guard values.first == "coverage" else { throw UsageError("coverage command is missing") }
        var rootPath = FileManager.default.currentDirectoryPath
        var scope: String?
        var sourceRoot: String?
        var llvmCoveragePath: String?
        var xunitPath: String?
        var policyPath: String?
        var baselinePath: String?
        var reportSchemaPath: String?
        var changedDiffPath: String?
        var outputPath: String?
        var criticalSources: [String] = []
        var index = 1
        while index < values.count {
            let option = values[index]
            guard index + 1 < values.count else { throw UsageError("missing value for \(option)") }
            let value = values[index + 1]
            switch option {
            case "--repo-root": rootPath = value
            case "--scope": scope = try Self.once(scope, value: value, option: option)
            case "--source-root":
                sourceRoot = try Self.once(sourceRoot, value: value, option: option)
            case "--llvm-cov":
                llvmCoveragePath = try Self.once(llvmCoveragePath, value: value, option: option)
            case "--xunit": xunitPath = try Self.once(xunitPath, value: value, option: option)
            case "--policy": policyPath = try Self.once(policyPath, value: value, option: option)
            case "--baseline": baselinePath = try Self.once(baselinePath, value: value, option: option)
            case "--report-schema":
                reportSchemaPath = try Self.once(reportSchemaPath, value: value, option: option)
            case "--changed-diff":
                changedDiffPath = try Self.once(changedDiffPath, value: value, option: option)
            case "--critical-source": criticalSources.append(value)
            case "--output": outputPath = try Self.once(outputPath, value: value, option: option)
            default: throw UsageError("unknown coverage option: \(option)")
            }
            index += 2
        }
        guard let scope, scope.range(of: #"^[A-Za-z][A-Za-z0-9_-]*$"#,
                                     options: .regularExpression) != nil else {
            throw UsageError("coverage requires a valid --scope")
        }
        guard let llvmCoveragePath else { throw UsageError("coverage requires --llvm-cov") }
        guard let xunitPath else { throw UsageError("coverage requires --xunit") }
        guard let changedDiffPath else { throw UsageError("coverage requires --changed-diff") }
        guard let outputPath else { throw UsageError("coverage requires --output") }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        func inputURL(_ path: String) -> URL {
            path.hasPrefix("/") ? URL(fileURLWithPath: path).standardizedFileURL
                : root.appending(path: path).standardizedFileURL
        }
        let resolvedOutput = outputPath.hasPrefix("/")
            ? URL(fileURLWithPath: outputPath).standardizedFileURL
            : root.appending(path: outputPath).standardizedFileURL
        configuration = CoverageVerificationConfiguration(
            scope: scope,
            repositoryRoot: root,
            sourceRoot: sourceRoot ?? "Packages/\(scope)/Sources/\(scope)",
            llvmCoverageURL: inputURL(llvmCoveragePath),
            xunitURL: inputURL(xunitPath),
            policyURL: policyPath.map(inputURL),
            baselineURL: baselinePath.map(inputURL),
            reportSchemaURL: reportSchemaPath.map(inputURL),
            changedDiffURL: inputURL(changedDiffPath),
            criticalSources: criticalSources
        )
        outputURL = resolvedOutput
    }

    private static func once(_ current: String?, value: String, option: String) throws -> String {
        guard current == nil else { throw UsageError("duplicate option: \(option)") }
        return value
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

    usage: agent-harness-verify coverage [options]
      --repo-root PATH
      --scope TARGET
      --source-root REPOSITORY_RELATIVE_PATH
      --llvm-cov PATH
      --xunit PATH
      --policy PATH
      --baseline PATH
      --report-schema PATH
      --changed-diff PATH
      --critical-source REPOSITORY_RELATIVE_PATH   (repeatable)
      --output PATH
    \n
    """.utf8))
}

do {
    let values = Array(CommandLine.arguments.dropFirst())
    if values.first == "coverage" {
        let arguments = try CoverageArguments(values)
        let report = AgentHarnessCoverageVerifier.verify(arguments.configuration)
        let data = try AgentHarnessCoverageVerifier.encodedReport(report)
        try FileManager.default.createDirectory(
            at: arguments.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: arguments.outputURL, options: .atomic)
        if report.succeeded {
            print("Agent Harness coverage verification passed (\(report.scope)).")
            exit(EXIT_SUCCESS)
        }
        for diagnostic in report.diagnostics {
            FileHandle.standardError.write(Data(
                "\(diagnostic.location): [\(diagnostic.code)] \(diagnostic.message)\n".utf8
            ))
        }
        exit(EXIT_FAILURE)
    }
    let arguments = try ManifestArguments(values)
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

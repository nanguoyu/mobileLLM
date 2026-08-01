// SPDX-License-Identifier: MIT

import CoreFoundation
import Foundation

/// Inputs for one independently collected SwiftPM/LLVM coverage result.
///
/// The verifier deliberately accepts the raw `llvm-cov export -format=text` document rather than a
/// pre-summarised percentage. That keeps executable-line, critical-source, and baseline decisions in one
/// versioned implementation and prevents a missing target from being represented as an empty success.
public struct CoverageVerificationConfiguration: Sendable {
    public let scope: String
    public let repositoryRoot: URL
    public let sourceRoot: String
    public let llvmCoverageURL: URL
    public let xunitURL: URL
    public let policyURL: URL
    public let baselineURL: URL
    public let reportSchemaURL: URL
    public let changedDiffURL: URL
    public let criticalSources: [String]
    public let generatedAt: Date

    public init(
        scope: String,
        repositoryRoot: URL,
        sourceRoot: String,
        llvmCoverageURL: URL,
        xunitURL: URL,
        policyURL: URL? = nil,
        baselineURL: URL? = nil,
        reportSchemaURL: URL? = nil,
        changedDiffURL: URL,
        criticalSources: [String],
        generatedAt: Date = Date()
    ) {
        let root = repositoryRoot.standardizedFileURL
        self.scope = scope
        self.repositoryRoot = root
        self.sourceRoot = sourceRoot
        self.llvmCoverageURL = llvmCoverageURL.standardizedFileURL
        self.xunitURL = xunitURL.standardizedFileURL
        self.policyURL = (policyURL
            ?? root.appending(path: "Verification/AgentHarness/Coverage/policy.v1.json"))
            .standardizedFileURL
        self.baselineURL = (baselineURL
            ?? root.appending(path: "Verification/AgentHarness/Coverage/baseline.v1.json"))
            .standardizedFileURL
        self.reportSchemaURL = (reportSchemaURL
            ?? root.appending(path: "Verification/AgentHarness/Schemas/coverage-report.schema.json"))
            .standardizedFileURL
        self.changedDiffURL = changedDiffURL.standardizedFileURL
        self.criticalSources = criticalSources
        self.generatedAt = generatedAt
    }
}

public struct CoverageVerificationReport: Codable, Sendable {
    public let schemaVersion: Int
    public let documentType: String
    public let scope: String
    public let succeeded: Bool
    public let generatedAtUTC: String
    public let inputs: CoverageReportInputs
    public let metrics: CoverageReportMetrics
    public let files: [CoverageFileReport]
    public let diagnostics: [CoverageReportDiagnostic]
}

public struct CoverageReportInputs: Codable, Sendable {
    public let llvmCoverageType: String?
    public let llvmCoverageVersion: String?
    public let xunitSHA256: String?
    public let sourceRoot: String
    public let policyPath: String
    public let baselinePath: String
    public let reportSchemaPath: String
    public let changedDiffSHA256: String?
    public let criticalSources: [String]
}

public struct CoverageReportMetrics: Codable, Sendable {
    public let tests: CoverageTestMetric
    public let target: CoverageMetricGroup
    public let critical: CoverageCriticalMetricGroup
    public let changedExecutableLines: CoverageChangedLineMetric
    public let baseline: CoverageBaselineComparison
}

public struct CoverageTestMetric: Codable, Sendable {
    public let status: String
    public let tests: Int
    public let failures: Int
    public let errors: Int
    public let skipped: Int
}

public struct CoverageMetricGroup: Codable, Sendable {
    public let lines: CoverageCount
    public let functions: CoverageCount
    public let requiredLinePercent: Double?
    public let requiredFunctionPercent: Double?
}

public struct CoverageCriticalMetricGroup: Codable, Sendable {
    public let status: String
    public let lines: CoverageCount
    public let functions: CoverageCount
    public let requiredLinePercent: Double?
    public let requiredFunctionPercent: Double?
    public let matchedSources: [String]
    public let uncoveredFunctions: [CoverageFunctionReport]
}

public struct CoverageChangedLineMetric: Codable, Sendable {
    public let status: String
    public let lines: CoverageCount
    public let functions: CoverageCount
    public let requiredLinePercent: Double?
    public let requiredFunctionPercent: Double?
    public let locations: [CoverageLineReport]
    public let matchedFunctions: [CoverageFunctionReport]
}

public struct CoverageBaselineComparison: Codable, Sendable {
    public let status: String
    public let baselineLinePercent: Double?
    public let baselineFunctionPercent: Double?
    public let currentLinePercent: Double?
    public let currentFunctionPercent: Double?
}

public struct CoverageCount: Codable, Sendable {
    public let count: Int
    public let covered: Int
    public let percent: Double?

    fileprivate init(count: Int = 0, covered: Int = 0) {
        self.count = count
        self.covered = covered
        percent = count == 0 ? nil : Double(covered) * 100 / Double(count)
    }
}

public struct CoverageFileReport: Codable, Sendable {
    public let path: String
    public let lines: CoverageCount
    public let functions: CoverageCount
}

public struct CoverageFunctionReport: Codable, Sendable {
    public let name: String
    public let paths: [String]
    public let executionCount: Int
    public let sourceRanges: [CoverageSourceRangeReport]
}

public struct CoverageSourceRangeReport: Codable, Sendable {
    public let path: String
    public let startLine: Int
    public let endLine: Int
}

public struct CoverageLineReport: Codable, Sendable {
    public let path: String
    public let line: Int
    public let executionCount: Int
}

public struct CoverageReportDiagnostic: Codable, Equatable, Sendable, Comparable {
    public let code: String
    public let location: String
    public let message: String

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.location, lhs.code, lhs.message) < (rhs.location, rhs.code, rhs.message)
    }
}

public enum AgentHarnessCoverageVerifier {
    public static func verify(
        _ configuration: CoverageVerificationConfiguration
    ) -> CoverageVerificationReport {
        var diagnostics: [CoverageReportDiagnostic] = []
        let root = configuration.repositoryRoot.standardizedFileURL
        let sourceRoot = confinedRepositoryPath(
            configuration.sourceRoot, root: root, location: "sourceRoot", diagnostics: &diagnostics
        )
        let sourceInventory = discoverProductionSwiftSources(
            sourceRoot, repositoryRoot: root, diagnostics: &diagnostics
        )
        let policy = loadPolicy(configuration.policyURL, scope: configuration.scope,
                                diagnostics: &diagnostics)
        let baseline = loadBaseline(configuration.baselineURL, scope: configuration.scope,
                                    diagnostics: &diagnostics)
        let diff = loadDiff(configuration.changedDiffURL, diagnostics: &diagnostics)
        let testEvidence = XUnitEvidenceParser.parse(configuration.xunitURL,
                                                     diagnostics: &diagnostics)
        let export = loadCoverage(configuration.llvmCoverageURL, repositoryRoot: root,
                                  sourceRoot: sourceRoot, diagnostics: &diagnostics)

        let files = export.files.sorted { $0.path < $1.path }
        let measuredPaths = Set(files.map(\.path))
        for path in sourceInventory.subtracting(measuredPaths).sorted() {
            add(&diagnostics, "AHV-COVERAGE-SOURCE-UNMEASURED", path,
                "hand-written Swift source is absent from the LLVM coverage export")
        }
        if files.isEmpty {
            add(&diagnostics, "AHV-COVERAGE-EMPTY", configuration.sourceRoot,
                "coverage export contains no files under the required production source root")
        }
        let targetLines = sum(files.map(\.lines))
        let targetFunctions = sum(files.map(\.functions))
        if targetLines.count == 0 {
            add(&diagnostics, "AHV-COVERAGE-EMPTY", configuration.scope,
                "target has no executable-line evidence")
        }
        if targetFunctions.count == 0 {
            add(&diagnostics, "AHV-COVERAGE-EMPTY", configuration.scope,
                "target has no executable-function evidence")
        }

        enforce(targetLines, floor: policy.targetLineFloor, code: "AHV-COVERAGE-TARGET-LINE-FLOOR",
                location: configuration.scope, noun: "target line", diagnostics: &diagnostics)
        enforce(targetFunctions, floor: policy.targetFunctionFloor,
                code: "AHV-COVERAGE-TARGET-FUNCTION-FLOOR", location: configuration.scope,
                noun: "target function", diagnostics: &diagnostics)

        let criticalSelectors = normalizedCriticalSelectors(
            configuration.criticalSources, root: root, sourceRoot: sourceRoot,
            diagnostics: &diagnostics
        )
        var matchedCriticalPaths: Set<String> = []
        for selector in criticalSelectors {
            let matchingFiles = files.filter { pathMatches($0.path, selector: selector) }
            if matchingFiles.isEmpty {
                add(&diagnostics, "AHV-COVERAGE-CRITICAL-MISSING", selector,
                    "critical-source selector matched no covered production file")
            }
            matchedCriticalPaths.formUnion(matchingFiles.map(\.path))
        }
        let criticalFiles = files.filter { matchedCriticalPaths.contains($0.path) }
        let criticalLines = sum(criticalFiles.map(\.lines))
        let criticalFunctions = sum(criticalFiles.map(\.functions))
        let criticalStatus: String
        if criticalSelectors.isEmpty {
            criticalStatus = "not-requested"
        } else if criticalFiles.isEmpty {
            criticalStatus = "missing-evidence"
        } else {
            criticalStatus = "measured"
            enforce(criticalLines, floor: policy.criticalLineFloor,
                    code: "AHV-COVERAGE-CRITICAL-LINE-FLOOR", location: configuration.scope,
                    noun: "critical-source line", diagnostics: &diagnostics)
            enforce(criticalFunctions, floor: policy.criticalFunctionFloor,
                    code: "AHV-COVERAGE-CRITICAL-FUNCTION-FLOOR", location: configuration.scope,
                    noun: "critical-source function", diagnostics: &diagnostics)
        }
        let uncoveredCriticalFunctions = export.functions.filter { function in
            function.count == 0 && function.paths.contains { matchedCriticalPaths.contains($0) }
        }.map(coverageFunctionReport)
            .sorted { ($0.paths.joined(), $0.name) < ($1.paths.joined(), $1.name) }
        if !uncoveredCriticalFunctions.isEmpty {
            add(&diagnostics, "AHV-COVERAGE-CRITICAL-UNCOVERED-FUNCTION",
                configuration.scope,
                "critical sources contain \(uncoveredCriticalFunctions.count) uncovered function(s)")
        }

        let changedLocations = changedExecutableLines(files: files, changed: diff.changedLines)
        let changedLines = CoverageCount(
            count: changedLocations.count,
            covered: changedLocations.lazy.filter { $0.executionCount > 0 }.count
        )
        let changedFunctionEvidence = changedFunctions(
            functions: export.functions, changed: diff.changedLines
        )
        let changedFunctions = CoverageCount(
            count: changedFunctionEvidence.count,
            covered: changedFunctionEvidence.lazy.filter { $0.count > 0 }.count
        )
        let changedStatus = changedLocations.isEmpty && changedFunctionEvidence.isEmpty
            ? "no-measurable-changes" : "measured"
        if !changedLocations.isEmpty {
            enforce(changedLines, floor: policy.changedLineFloor,
                    code: "AHV-COVERAGE-CHANGED-LINE-FLOOR", location: configuration.scope,
                    noun: "changed executable line", diagnostics: &diagnostics)
        }
        if !changedFunctionEvidence.isEmpty {
            enforce(changedFunctions, floor: policy.changedFunctionFloor,
                    code: "AHV-COVERAGE-CHANGED-FUNCTION-FLOOR", location: configuration.scope,
                    noun: "changed function", diagnostics: &diagnostics)
        } else if !changedLocations.isEmpty {
            add(&diagnostics, "AHV-COVERAGE-CHANGED-FUNCTION-EVIDENCE", configuration.scope,
                "changed executable lines exist but no LLVM function region maps to them")
        }

        let baselineComparison = compareBaseline(
            baseline, currentLines: targetLines, currentFunctions: targetFunctions,
            scope: configuration.scope, diagnostics: &diagnostics
        )
        let reportFiles = files.map {
            CoverageFileReport(path: $0.path, lines: $0.lines, functions: $0.functions)
        }
        func makeReport(_ reportDiagnostics: [CoverageReportDiagnostic]) -> CoverageVerificationReport {
            CoverageVerificationReport(
                schemaVersion: 1,
                documentType: "agent-harness-coverage-report",
                scope: configuration.scope,
                succeeded: reportDiagnostics.isEmpty,
                generatedAtUTC: iso8601(configuration.generatedAt),
                inputs: CoverageReportInputs(
                    llvmCoverageType: export.type,
                    llvmCoverageVersion: export.version,
                    xunitSHA256: testEvidence.sha256,
                    sourceRoot: configuration.sourceRoot,
                    policyPath: displayPath(configuration.policyURL, root: root),
                    baselinePath: displayPath(configuration.baselineURL, root: root),
                    reportSchemaPath: displayPath(configuration.reportSchemaURL, root: root),
                    changedDiffSHA256: diff.sha256,
                    criticalSources: criticalSelectors
                ),
                metrics: CoverageReportMetrics(
                    tests: CoverageTestMetric(
                        status: testEvidence.status,
                        tests: testEvidence.tests,
                        failures: testEvidence.failures,
                        errors: testEvidence.errors,
                        skipped: testEvidence.skipped
                    ),
                    target: CoverageMetricGroup(
                        lines: targetLines, functions: targetFunctions,
                        requiredLinePercent: policy.targetLineFloor,
                        requiredFunctionPercent: policy.targetFunctionFloor
                    ),
                    critical: CoverageCriticalMetricGroup(
                        status: criticalStatus, lines: criticalLines, functions: criticalFunctions,
                        requiredLinePercent: criticalSelectors.isEmpty ? nil : policy.criticalLineFloor,
                        requiredFunctionPercent: criticalSelectors.isEmpty
                            ? nil : policy.criticalFunctionFloor,
                        matchedSources: matchedCriticalPaths.sorted(),
                        uncoveredFunctions: uncoveredCriticalFunctions
                    ),
                    changedExecutableLines: CoverageChangedLineMetric(
                        status: changedStatus, lines: changedLines, functions: changedFunctions,
                        requiredLinePercent: policy.changedLineFloor,
                        requiredFunctionPercent: policy.changedFunctionFloor,
                        locations: changedLocations,
                        matchedFunctions: changedFunctionEvidence.map(coverageFunctionReport)
                    ),
                    baseline: baselineComparison
                ),
                files: reportFiles,
                diagnostics: reportDiagnostics
            )
        }

        var report = makeReport(diagnostics.sorted())
        let schemaDiagnostics: [CoverageReportDiagnostic]
        do {
            schemaDiagnostics = validateReportData(
                try encodedReport(report), schemaURL: configuration.reportSchemaURL
            )
        } catch {
            schemaDiagnostics = [.init(
                code: "AHV-COVERAGE-REPORT-ENCODE",
                location: configuration.scope,
                message: "coverage report could not be encoded for schema validation: \(error.localizedDescription)"
            )]
        }
        if !schemaDiagnostics.isEmpty {
            diagnostics.append(contentsOf: schemaDiagnostics)
            report = makeReport(diagnostics.sorted())
        }
        return report
    }

    public static func encodedReport(_ report: CoverageVerificationReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }

    /// Validates encoded report evidence against the checked-in, offline JSON Schema.
    public static func validateReportData(
        _ data: Data, schemaURL: URL
    ) -> [CoverageReportDiagnostic] {
        validateCoverageReportData(data, schemaURL: schemaURL)
    }
}

private struct NormalizedCoverageExport {
    var type: String?
    var version: String?
    var files: [NormalizedCoverageFile] = []
    var functions: [NormalizedCoverageFunction] = []
}

private struct NormalizedCoverageFile {
    let path: String
    let lines: CoverageCount
    let functions: CoverageCount
    let executableLines: [Int: Int]
}

private struct NormalizedCoverageFunction {
    let name: String
    let count: Int
    let paths: [String]
    let sourceRanges: [NormalizedSourceRange]
}

private struct NormalizedSourceRange: Hashable {
    let path: String
    let startLine: Int
    let endLine: Int
}

private struct CoveragePolicyFloors {
    var targetLineFloor: Double?
    var targetFunctionFloor: Double?
    var criticalLineFloor: Double?
    var criticalFunctionFloor: Double?
    var changedLineFloor: Double?
    var changedFunctionFloor: Double?
}

private struct CoverageBaseline {
    var status = "missing"
    var linePercent: Double?
    var functionPercent: Double?
}

private struct ChangedDiff {
    var changedLines: [String: Set<Int>] = [:]
    var sha256: String?
}

private struct Segment {
    let line: Int
    let column: Int
    let count: Int
    let hasCount: Bool
    let isGap: Bool
}

private func discoverProductionSwiftSources(
    _ sourceRoot: URL?,
    repositoryRoot: URL,
    diagnostics: inout [CoverageReportDiagnostic]
) -> Set<String> {
    guard let sourceRoot else { return [] }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: sourceRoot.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        add(&diagnostics, "AHV-COVERAGE-SOURCE-ROOT-MISSING",
            displayPath(sourceRoot, root: repositoryRoot),
            "production source root is missing or is not a directory")
        return []
    }
    do {
        let rootValues = try sourceRoot.resourceValues(forKeys: [.isSymbolicLinkKey])
        if rootValues.isSymbolicLink == true {
            add(&diagnostics, "AHV-COVERAGE-SOURCE-SYMLINK",
                displayPath(sourceRoot, root: repositoryRoot),
                "production source root must not be a symbolic link")
            return []
        }
    } catch {
        add(&diagnostics, "AHV-COVERAGE-SOURCE-INVENTORY",
            displayPath(sourceRoot, root: repositoryRoot),
            "production source root metadata is unreadable: \(error.localizedDescription)")
        return []
    }

    let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
    var traversalDiagnostics: [CoverageReportDiagnostic] = []
    guard let enumerator = FileManager.default.enumerator(
        at: sourceRoot,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles],
        errorHandler: { url, error in
            add(&traversalDiagnostics, "AHV-COVERAGE-SOURCE-INVENTORY",
                displayPath(url, root: repositoryRoot),
                "production source traversal failed: \(error.localizedDescription)")
            return true
        }
    ) else {
        add(&diagnostics, "AHV-COVERAGE-SOURCE-INVENTORY",
            displayPath(sourceRoot, root: repositoryRoot),
            "production source root could not be enumerated")
        return []
    }

    var result: Set<String> = []
    for case let url as URL in enumerator {
        do {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                if url.pathExtension == "swift" {
                    add(&diagnostics, "AHV-COVERAGE-SOURCE-SYMLINK",
                        displayPath(url, root: repositoryRoot),
                        "Swift production sources must be regular files, not symbolic links")
                }
                continue
            }
            guard values.isRegularFile == true, url.pathExtension == "swift" else { continue }
            result.insert(displayPath(url, root: repositoryRoot))
        } catch {
            add(&diagnostics, "AHV-COVERAGE-SOURCE-INVENTORY",
                displayPath(url, root: repositoryRoot),
                "production source metadata is unreadable: \(error.localizedDescription)")
        }
    }
    diagnostics.append(contentsOf: traversalDiagnostics)
    if result.isEmpty {
        add(&diagnostics, "AHV-COVERAGE-SOURCE-INVENTORY",
            displayPath(sourceRoot, root: repositoryRoot),
            "production source root contains no regular Swift source files")
    }
    return result
}

private func loadCoverage(
    _ url: URL,
    repositoryRoot: URL,
    sourceRoot: URL?,
    diagnostics: inout [CoverageReportDiagnostic]
) -> NormalizedCoverageExport {
    guard let data = try? Data(contentsOf: url), !data.isEmpty else {
        add(&diagnostics, "AHV-COVERAGE-INPUT-MISSING", url.path,
            "llvm-cov export is missing or empty")
        return .init()
    }
    let raw: Any
    do {
        raw = try JSONSerialization.jsonObject(with: data)
    } catch {
        add(&diagnostics, "AHV-COVERAGE-DECODE", url.path,
            "llvm-cov export is not valid JSON: \(error.localizedDescription)")
        return .init()
    }
    guard let object = raw as? [String: Any] else {
        add(&diagnostics, "AHV-COVERAGE-FORMAT", url.path,
            "llvm-cov export root must be an object")
        return .init()
    }
    let type = object["type"] as? String
    let version = object["version"] as? String
    if type != "llvm.coverage.json.export" {
        add(&diagnostics, "AHV-COVERAGE-FORMAT", url.path,
            "coverage type must be llvm.coverage.json.export")
    }
    if version?.isEmpty != false {
        add(&diagnostics, "AHV-COVERAGE-FORMAT", url.path,
            "coverage version must be a nonempty string")
    }
    guard let dataSets = object["data"] as? [[String: Any]], !dataSets.isEmpty else {
        add(&diagnostics, "AHV-COVERAGE-EMPTY", url.path,
            "llvm-cov export data array is missing or empty")
        return .init(type: type, version: version)
    }
    guard let sourceRoot else { return .init(type: type, version: version) }

    var result = NormalizedCoverageExport(type: type, version: version)
    var seenFiles: Set<String> = []
    for (dataIndex, dataSet) in dataSets.enumerated() {
        guard let rawFiles = dataSet["files"] as? [[String: Any]] else {
            add(&diagnostics, "AHV-COVERAGE-FORMAT", "data[\(dataIndex)].files",
                "files must be an array")
            continue
        }
        for (fileIndex, rawFile) in rawFiles.enumerated() {
            let location = "data[\(dataIndex)].files[\(fileIndex)]"
            guard let filename = rawFile["filename"] as? String,
                  let path = repositoryRelativePath(filename, root: repositoryRoot),
                  isPath(path, under: displayPath(sourceRoot, root: repositoryRoot)) else {
                continue
            }
            if !seenFiles.insert(path).inserted {
                add(&diagnostics, "AHV-COVERAGE-DUPLICATE-FILE", path,
                    "production file appears more than once in llvm-cov export")
                continue
            }
            let absolute = repositoryRoot.appending(path: path).standardizedFileURL
            let values = try? absolute.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            if values?.isRegularFile != true || values?.isSymbolicLink == true {
                add(&diagnostics, "AHV-COVERAGE-SOURCE-MISSING", path,
                    "covered production source does not exist as a regular file")
            }
            guard let summary = rawFile["summary"] as? [String: Any],
                  let lines = parseCount(summary["lines"], location: "\(location).summary.lines",
                                         diagnostics: &diagnostics),
                  let functions = parseCount(
                    summary["functions"], location: "\(location).summary.functions",
                    diagnostics: &diagnostics
                  ) else { continue }
            let executable = parseSegments(rawFile["segments"], location: "\(location).segments",
                                           diagnostics: &diagnostics)
            if lines.count > 0, executable.isEmpty {
                add(&diagnostics, "AHV-COVERAGE-SEGMENTS-MISSING", path,
                    "file reports executable lines but has no executable segment evidence")
            }
            result.files.append(.init(path: path, lines: lines, functions: functions,
                                      executableLines: executable))
        }

        guard let rawFunctions = dataSet["functions"] as? [[String: Any]] else {
            add(&diagnostics, "AHV-COVERAGE-FORMAT", "data[\(dataIndex)].functions",
                "functions must be an array")
            continue
        }
        for (functionIndex, rawFunction) in rawFunctions.enumerated() {
            let location = "data[\(dataIndex)].functions[\(functionIndex)]"
            guard let name = rawFunction["name"] as? String, !name.isEmpty,
                  let count = nonnegativeInt(rawFunction["count"]),
                  let filenames = rawFunction["filenames"] as? [String] else {
                add(&diagnostics, "AHV-COVERAGE-FUNCTION", location,
                    "function requires a name, nonnegative count, and filename array")
                continue
            }
            let paths = Set(filenames.compactMap {
                repositoryRelativePath($0, root: repositoryRoot)
            }.filter { isPath($0, under: displayPath(sourceRoot, root: repositoryRoot)) }).sorted()
            if !paths.isEmpty {
                let sourceRanges = parseFunctionRegions(
                    rawFunction["regions"], filenames: filenames,
                    repositoryRoot: repositoryRoot, sourceRoot: sourceRoot,
                    location: "\(location).regions", diagnostics: &diagnostics
                )
                if sourceRanges.isEmpty {
                    add(&diagnostics, "AHV-COVERAGE-FUNCTION-REGION", location,
                        "in-scope function has no valid LLVM code-region source mapping")
                    continue
                }
                result.functions.append(.init(
                    name: name, count: count, paths: paths, sourceRanges: sourceRanges
                ))
            }
        }
    }
    result.files.sort { $0.path < $1.path }
    result.functions.sort { ($0.paths.joined(), $0.name) < ($1.paths.joined(), $1.name) }
    return result
}

private func parseFunctionRegions(
    _ value: Any?,
    filenames: [String],
    repositoryRoot: URL,
    sourceRoot: URL,
    location: String,
    diagnostics: inout [CoverageReportDiagnostic]
) -> [NormalizedSourceRange] {
    guard let rawRegions = value as? [[Any]] else {
        add(&diagnostics, "AHV-COVERAGE-FUNCTION-REGION", location,
            "function regions must be an array")
        return []
    }
    var ranges: Set<NormalizedSourceRange> = []
    for (index, raw) in rawRegions.enumerated() {
        guard raw.count >= 8,
              let startLine = positiveInt(raw[0]),
              positiveInt(raw[1]) != nil,
              let endLine = positiveInt(raw[2]),
              positiveInt(raw[3]) != nil,
              nonnegativeInt(raw[4]) != nil,
              let fileIndex = nonnegativeInt(raw[5]),
              nonnegativeInt(raw[6]) != nil,
              let kind = nonnegativeInt(raw[7]),
              endLine >= startLine,
              endLine - startLine <= 1_000_000,
              filenames.indices.contains(fileIndex) else {
            add(&diagnostics, "AHV-COVERAGE-FUNCTION-REGION", "\(location)[\(index)]",
                "region must contain a valid bounded source range and filename index")
            continue
        }
        // LLVM region kind zero is a source-backed code region. Expansion, skipped, gap, and branch
        // regions must not create changed-function denominators.
        guard kind == 0,
              let path = repositoryRelativePath(filenames[fileIndex], root: repositoryRoot),
              isPath(path, under: displayPath(sourceRoot, root: repositoryRoot)) else { continue }
        ranges.insert(.init(path: path, startLine: startLine, endLine: endLine))
    }
    return ranges.sorted {
        ($0.path, $0.startLine, $0.endLine) < ($1.path, $1.startLine, $1.endLine)
    }
}

private func parseCount(
    _ value: Any?, location: String,
    diagnostics: inout [CoverageReportDiagnostic]
) -> CoverageCount? {
    guard let object = value as? [String: Any],
          let count = nonnegativeInt(object["count"]),
          let covered = nonnegativeInt(object["covered"]), covered <= count else {
        add(&diagnostics, "AHV-COVERAGE-SUMMARY", location,
            "summary requires nonnegative integer count/covered with covered <= count")
        return nil
    }
    return CoverageCount(count: count, covered: covered)
}

private func parseSegments(
    _ value: Any?, location: String,
    diagnostics: inout [CoverageReportDiagnostic]
) -> [Int: Int] {
    guard let rawSegments = value as? [[Any]] else {
        add(&diagnostics, "AHV-COVERAGE-SEGMENT", location, "segments must be an array")
        return [:]
    }
    var segments: [Segment] = []
    for (index, raw) in rawSegments.enumerated() {
        guard raw.count >= 6, let line = positiveInt(raw[0]), let column = positiveInt(raw[1]),
              let count = nonnegativeInt(raw[2]), let hasCount = raw[3] as? Bool,
              let isGap = raw[5] as? Bool else {
            add(&diagnostics, "AHV-COVERAGE-SEGMENT", "\(location)[\(index)]",
                "segment must contain line, column, count, hasCount, entry, and gap fields")
            continue
        }
        segments.append(.init(line: line, column: column, count: count,
                              hasCount: hasCount, isGap: isGap))
    }
    segments.sort { ($0.line, $0.column) < ($1.line, $1.column) }
    var result: [Int: Int] = [:]
    for index in segments.indices {
        let segment = segments[index]
        guard segment.hasCount, !segment.isGap else { continue }
        var endLine = segment.line
        if index + 1 < segments.count {
            let next = segments[index + 1]
            if next.line > segment.line {
                endLine = next.column == 1 ? next.line - 1 : next.line
            }
        }
        guard endLine >= segment.line, endLine - segment.line <= 1_000_000 else {
            add(&diagnostics, "AHV-COVERAGE-SEGMENT", "\(location)[\(index)]",
                "segment line span is invalid or unreasonably large")
            continue
        }
        for line in segment.line...endLine {
            result[line] = max(result[line] ?? 0, segment.count)
        }
    }
    return result
}

private func loadPolicy(
    _ url: URL, scope: String,
    diagnostics: inout [CoverageReportDiagnostic]
) -> CoveragePolicyFloors {
    guard let object = loadJSONObject(url, kind: "coverage policy", diagnostics: &diagnostics),
          let floors = object["floors"] as? [[String: Any]] else {
        return .init()
    }
    func floor(_ name: String) -> [String: Any]? {
        let matches = floors.filter { $0["scope"] as? String == name }
        if matches.count != 1 {
            add(&diagnostics, "AHV-COVERAGE-POLICY", name,
                "coverage policy must contain exactly one floor for this scope")
        }
        return matches.first
    }
    let target = floor(scope)
    let critical = floor("security-critical-runtime-components")
    let changed = floor("changed-agent-harness-lines-and-adapters")
    return CoveragePolicyFloors(
        targetLineFloor: percent(target?["linePercent"], location: "\(scope).linePercent",
                                 diagnostics: &diagnostics),
        targetFunctionFloor: percent(
            target?["functionPercent"], location: "\(scope).functionPercent",
            diagnostics: &diagnostics
        ),
        criticalLineFloor: percent(
            critical?["linePercent"], location: "security-critical-runtime-components.linePercent",
            diagnostics: &diagnostics
        ),
        criticalFunctionFloor: percent(
            critical?["functionPercent"],
            location: "security-critical-runtime-components.functionPercent",
            diagnostics: &diagnostics
        ),
        changedLineFloor: percent(
            changed?["linePercent"], location: "changed-agent-harness-lines-and-adapters.linePercent",
            diagnostics: &diagnostics
        ),
        changedFunctionFloor: percent(
            changed?["functionPercent"],
            location: "changed-agent-harness-lines-and-adapters.functionPercent",
            diagnostics: &diagnostics
        )
    )
}

private func loadBaseline(
    _ url: URL, scope: String,
    diagnostics: inout [CoverageReportDiagnostic]
) -> CoverageBaseline {
    guard let object = loadJSONObject(url, kind: "coverage baseline", diagnostics: &diagnostics),
          let entries = object["entries"] as? [[String: Any]] else { return .init() }
    let matches = entries.filter { $0["scope"] as? String == scope }
    guard matches.count == 1, let entry = matches.first else {
        add(&diagnostics, "AHV-COVERAGE-BASELINE", scope,
            "coverage baseline must contain exactly one entry for the target")
        return .init()
    }
    let line = nullablePercent(entry["linePercent"], location: "\(scope).linePercent",
                               diagnostics: &diagnostics)
    let function = nullablePercent(entry["functionPercent"], location: "\(scope).functionPercent",
                                   diagnostics: &diagnostics)
    if (line == nil) != (function == nil) {
        add(&diagnostics, "AHV-COVERAGE-BASELINE", scope,
            "baseline line and function percentages must both be measured or both be null")
    }
    return .init(status: entry["status"] as? String ?? "unknown",
                 linePercent: line, functionPercent: function)
}

private func loadDiff(
    _ url: URL,
    diagnostics: inout [CoverageReportDiagnostic]
) -> ChangedDiff {
    guard let data = try? Data(contentsOf: url) else {
        add(&diagnostics, "AHV-COVERAGE-DIFF-MISSING", url.path,
            "changed-lines unified diff is unreadable")
        return .init()
    }
    guard let text = String(data: data, encoding: .utf8) else {
        add(&diagnostics, "AHV-COVERAGE-DIFF", url.path,
            "changed-lines unified diff must be UTF-8")
        return .init(sha256: AgentHarnessManifestVerifier.sha256Hex(of: data))
    }
    var result = ChangedDiff(sha256: AgentHarnessManifestVerifier.sha256Hex(of: data))
    var currentPath: String?
    let expression = try? NSRegularExpression(
        pattern: #"^@@ -[0-9]+(?:,[0-9]+)? \+([0-9]+)(?:,([0-9]+))? @@"#
    )
    for (index, line) in text.components(separatedBy: .newlines).enumerated() {
        if line.hasPrefix("+++ ") {
            var path = String(line.dropFirst(4))
            if let tab = path.firstIndex(of: "\t") { path = String(path[..<tab]) }
            if path == "/dev/null" { currentPath = nil }
            else if path.hasPrefix("b/") { currentPath = String(path.dropFirst(2)) }
            else { currentPath = path }
            continue
        }
        guard line.hasPrefix("@@") else { continue }
        guard let expression, let currentPath else {
            add(&diagnostics, "AHV-COVERAGE-DIFF", "\(url.path):\(index + 1)",
                "diff hunk has no valid current-file header")
            continue
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = expression.firstMatch(in: line, range: range),
              let startRange = Range(match.range(at: 1), in: line),
              let start = Int(line[startRange]) else {
            add(&diagnostics, "AHV-COVERAGE-DIFF", "\(url.path):\(index + 1)",
                "malformed unified-diff hunk header")
            continue
        }
        var count = 1
        if match.range(at: 2).location != NSNotFound,
           let countRange = Range(match.range(at: 2), in: line),
           let parsed = Int(line[countRange]) { count = parsed }
        guard start >= 0, count >= 0, count <= 1_000_000 else {
            add(&diagnostics, "AHV-COVERAGE-DIFF", "\(url.path):\(index + 1)",
                "diff hunk range is invalid or unreasonably large")
            continue
        }
        guard count > 0 else { continue }
        result.changedLines[currentPath, default: []].formUnion(start..<(start + count))
    }
    return result
}

private func normalizedCriticalSelectors(
    _ selectors: [String], root: URL, sourceRoot: URL?,
    diagnostics: inout [CoverageReportDiagnostic]
) -> [String] {
    guard let sourceRoot else { return [] }
    var result: Set<String> = []
    let sourcePath = displayPath(sourceRoot, root: root)
    for selector in selectors {
        guard let url = confinedRepositoryPath(
            selector, root: root, location: "criticalSources", diagnostics: &diagnostics
        ) else { continue }
        let path = displayPath(url, root: root)
        guard isPath(path, under: sourcePath) else {
            add(&diagnostics, "AHV-COVERAGE-CRITICAL-PATH", selector,
                "critical source must be inside the configured production source root")
            continue
        }
        if !result.insert(path).inserted {
            add(&diagnostics, "AHV-COVERAGE-CRITICAL-DUPLICATE", selector,
                "critical-source selectors must be unique")
        }
    }
    return result.sorted()
}

private func changedExecutableLines(
    files: [NormalizedCoverageFile], changed: [String: Set<Int>]
) -> [CoverageLineReport] {
    files.flatMap { file in
        let changedForFile = changed[file.path] ?? []
        return file.executableLines.compactMap { line, count in
            changedForFile.contains(line)
                ? CoverageLineReport(path: file.path, line: line, executionCount: count)
                : nil
        }
    }.sorted { ($0.path, $0.line) < ($1.path, $1.line) }
}

private func changedFunctions(
    functions: [NormalizedCoverageFunction], changed: [String: Set<Int>]
) -> [NormalizedCoverageFunction] {
    functions.filter { function in
        function.sourceRanges.contains { range in
            guard let changedLines = changed[range.path] else { return false }
            return changedLines.contains { (range.startLine...range.endLine).contains($0) }
        }
    }.sorted {
        ($0.paths.joined(separator: "\u{0}"), $0.name)
            < ($1.paths.joined(separator: "\u{0}"), $1.name)
    }
}

private func coverageFunctionReport(
    _ function: NormalizedCoverageFunction
) -> CoverageFunctionReport {
    CoverageFunctionReport(
        name: function.name,
        paths: function.paths,
        executionCount: function.count,
        sourceRanges: function.sourceRanges.map {
            CoverageSourceRangeReport(
                path: $0.path, startLine: $0.startLine, endLine: $0.endLine
            )
        }
    )
}

private func compareBaseline(
    _ baseline: CoverageBaseline,
    currentLines: CoverageCount,
    currentFunctions: CoverageCount,
    scope: String,
    diagnostics: inout [CoverageReportDiagnostic]
) -> CoverageBaselineComparison {
    guard let baselineLine = baseline.linePercent,
          let baselineFunction = baseline.functionPercent else {
        return .init(status: "not-established", baselineLinePercent: nil,
                     baselineFunctionPercent: nil, currentLinePercent: currentLines.percent,
                     currentFunctionPercent: currentFunctions.percent)
    }
    guard let currentLine = currentLines.percent, let currentFunction = currentFunctions.percent else {
        return .init(status: "missing-current-evidence", baselineLinePercent: baselineLine,
                     baselineFunctionPercent: baselineFunction, currentLinePercent: currentLines.percent,
                     currentFunctionPercent: currentFunctions.percent)
    }
    if currentLine + 0.000_000_1 < baselineLine {
        add(&diagnostics, "AHV-COVERAGE-BASELINE-REGRESSION", scope,
            "line coverage \(format(currentLine))% is below baseline \(format(baselineLine))%")
    }
    if currentFunction + 0.000_000_1 < baselineFunction {
        add(&diagnostics, "AHV-COVERAGE-BASELINE-REGRESSION", scope,
            "function coverage \(format(currentFunction))% is below baseline \(format(baselineFunction))%")
    }
    return .init(status: "compared", baselineLinePercent: baselineLine,
                 baselineFunctionPercent: baselineFunction, currentLinePercent: currentLine,
                 currentFunctionPercent: currentFunction)
}

private func enforce(
    _ metric: CoverageCount, floor: Double?, code: String, location: String, noun: String,
    diagnostics: inout [CoverageReportDiagnostic]
) {
    guard let floor else { return }
    guard let current = metric.percent else {
        add(&diagnostics, code, location, "\(noun) coverage is missing; requires \(format(floor))%")
        return
    }
    if current + 0.000_000_1 < floor {
        add(&diagnostics, code, location,
            "\(noun) coverage \(format(current))% is below required \(format(floor))%")
    }
}

private func sum(_ metrics: [CoverageCount]) -> CoverageCount {
    CoverageCount(count: metrics.reduce(0) { $0 + $1.count },
                  covered: metrics.reduce(0) { $0 + $1.covered })
}

private func loadJSONObject(
    _ url: URL, kind: String,
    diagnostics: inout [CoverageReportDiagnostic]
) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url), !data.isEmpty else {
        add(&diagnostics, "AHV-COVERAGE-INPUT-MISSING", url.path, "\(kind) is missing or empty")
        return nil
    }
    do {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            add(&diagnostics, "AHV-COVERAGE-DECODE", url.path, "\(kind) root must be an object")
            return nil
        }
        return object
    } catch {
        add(&diagnostics, "AHV-COVERAGE-DECODE", url.path,
            "\(kind) is invalid JSON: \(error.localizedDescription)")
        return nil
    }
}

private func validateCoverageReportData(
    _ data: Data, schemaURL: URL
) -> [CoverageReportDiagnostic] {
    var diagnostics: [CoverageReportDiagnostic] = []
    guard !data.isEmpty else {
        add(&diagnostics, "AHV-COVERAGE-REPORT-DECODE", "coverage-report",
            "encoded coverage report is empty")
        return diagnostics
    }
    let instance: Any
    do {
        instance = try JSONSerialization.jsonObject(with: data)
    } catch {
        add(&diagnostics, "AHV-COVERAGE-REPORT-DECODE", "coverage-report",
            "encoded coverage report is invalid JSON: \(error.localizedDescription)")
        return diagnostics
    }
    guard let schemaData = try? Data(contentsOf: schemaURL), !schemaData.isEmpty else {
        add(&diagnostics, "AHV-COVERAGE-REPORT-SCHEMA-MISSING", schemaURL.path,
            "coverage report schema is missing or empty")
        return diagnostics
    }
    let schema: Any
    do {
        schema = try JSONSerialization.jsonObject(with: schemaData)
    } catch {
        add(&diagnostics, "AHV-COVERAGE-REPORT-SCHEMA-DECODE", schemaURL.path,
            "coverage report schema is invalid JSON: \(error.localizedDescription)")
        return diagnostics
    }
    let definitionIssues = RepositoryJSONSchemaValidator.validateSchema(
        schema, label: schemaURL.path
    )
    for issue in definitionIssues {
        add(&diagnostics, "AHV-COVERAGE-REPORT-SCHEMA-DEFINITION",
            issue.location, issue.message)
    }
    guard definitionIssues.isEmpty else { return diagnostics.sorted() }
    for issue in RepositoryJSONSchemaValidator.validate(
        instance: instance, against: schema, label: "coverage-report"
    ) {
        add(&diagnostics, "AHV-COVERAGE-REPORT-SCHEMA-INSTANCE",
            issue.location, issue.message)
    }
    return diagnostics.sorted()
}

private func confinedRepositoryPath(
    _ path: String, root: URL, location: String,
    diagnostics: inout [CoverageReportDiagnostic]
) -> URL? {
    guard !path.isEmpty, !path.hasPrefix("/"),
          !path.split(separator: "/").contains("..") else {
        add(&diagnostics, "AHV-COVERAGE-PATH", location,
            "path must be nonempty, repository-relative, and confined")
        return nil
    }
    let url = root.appending(path: path).standardizedFileURL
    guard isConfined(url, root: root) else {
        add(&diagnostics, "AHV-COVERAGE-PATH", location, "path escapes repository root")
        return nil
    }
    return url
}

private func repositoryRelativePath(_ path: String, root: URL) -> String? {
    let url: URL
    if path.hasPrefix("/") {
        url = URL(fileURLWithPath: path).standardizedFileURL
    } else {
        url = root.appending(path: path).standardizedFileURL
    }
    guard isConfined(url, root: root) else { return nil }
    return displayPath(url, root: root)
}

private func displayPath(_ url: URL, root: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    if path == rootPath { return "." }
    if path.hasPrefix(rootPath + "/") { return String(path.dropFirst(rootPath.count + 1)) }
    return path
}

private func isConfined(_ url: URL, root: URL) -> Bool {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    return path == rootPath || path.hasPrefix(rootPath + "/")
}

private func isPath(_ path: String, under root: String) -> Bool {
    path == root || path.hasPrefix(root + "/")
}

private func pathMatches(_ path: String, selector: String) -> Bool {
    path == selector || path.hasPrefix(selector + "/")
}

private func percent(
    _ value: Any?, location: String,
    diagnostics: inout [CoverageReportDiagnostic]
) -> Double? {
    guard let number = value as? NSNumber, !isBoolean(number) else {
        add(&diagnostics, "AHV-COVERAGE-POLICY", location,
            "coverage floor must be numeric")
        return nil
    }
    let value = number.doubleValue
    guard value.isFinite, (0...100).contains(value) else {
        add(&diagnostics, "AHV-COVERAGE-POLICY", location,
            "coverage floor must be between 0 and 100")
        return nil
    }
    return value
}

private func nullablePercent(
    _ value: Any?, location: String,
    diagnostics: inout [CoverageReportDiagnostic]
) -> Double? {
    if value == nil || value is NSNull { return nil }
    guard let number = value as? NSNumber, !isBoolean(number) else {
        add(&diagnostics, "AHV-COVERAGE-BASELINE", location,
            "baseline percentage must be numeric or null")
        return nil
    }
    let value = number.doubleValue
    guard value.isFinite, (0...100).contains(value) else {
        add(&diagnostics, "AHV-COVERAGE-BASELINE", location,
            "baseline percentage must be between 0 and 100")
        return nil
    }
    return value
}

private func nonnegativeInt(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
    if !CFNumberIsFloatType(number) {
        let integer = number.int64Value
        guard integer >= 0 else { return nil }
        return Int(integer)
    }
    let double = number.doubleValue
    guard double.isFinite, double >= 0, double.rounded() == double,
          let integer = Int(exactly: double) else { return nil }
    return integer
}

private func isBoolean(_ number: NSNumber) -> Bool {
    CFGetTypeID(number) == CFBooleanGetTypeID()
}

private func positiveInt(_ value: Any?) -> Int? {
    guard let value = nonnegativeInt(value), value > 0 else { return nil }
    return value
}

private func format(_ value: Double) -> String {
    String(format: "%.4f", value)
}

private func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

private func add(
    _ diagnostics: inout [CoverageReportDiagnostic], _ code: String,
    _ location: String, _ message: String
) {
    diagnostics.append(.init(code: code, location: location, message: message))
}

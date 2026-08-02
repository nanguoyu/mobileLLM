// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import AgentHarnessVerificationCore

final class CoverageVerifierTests: XCTestCase {
    // TEST-ID: AHT-INFRA-007
    func testCoverageEvidenceNormalizesAndPassesEveryConfiguredGate() throws {
        let fixture = try CoverageFixture()
        let report = AgentHarnessCoverageVerifier.verify(fixture.configuration())

        XCTAssertTrue(report.succeeded, report.diagnostics.map {
            "\($0.location): [\($0.code)] \($0.message)"
        }.joined(separator: "\n"))
        XCTAssertEqual(report.metrics.tests.tests, 2)
        XCTAssertEqual(report.metrics.tests.skipped, 0)
        XCTAssertEqual(report.metrics.target.lines.count, 20)
        XCTAssertEqual(report.metrics.target.lines.covered, 19)
        XCTAssertEqual(report.metrics.target.lines.percent, 95)
        XCTAssertEqual(report.metrics.target.functions.percent, 100)
        XCTAssertEqual(report.metrics.critical.status, "measured")
        XCTAssertEqual(report.metrics.critical.lines.percent, 100)
        XCTAssertEqual(report.metrics.critical.functions.percent, 100)
        XCTAssertEqual(report.metrics.changedExecutableLines.lines.percent, 100)
        XCTAssertEqual(report.metrics.changedExecutableLines.functions.percent, 100)
        XCTAssertEqual(report.metrics.changedExecutableLines.matchedFunctions.count, 2)
        XCTAssertEqual(report.metrics.baseline.status, "compared")
        XCTAssertEqual(report.files.map(\.path), report.files.map(\.path).sorted())

        let encoded = try AgentHarnessCoverageVerifier.encodedReport(report)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["documentType"] as? String, "agent-harness-coverage-report")
        XCTAssertEqual(object["succeeded"] as? Bool, true)
        XCTAssertNotNil((object["metrics"] as? [String: Any])?["tests"])
    }

    func testAllQuantitativeFailuresAndUncoveredFunctionsAreReported() throws {
        let fixture = try CoverageFixture()
        try fixture.writeCoverage(
            authorityUncoveredLines: [2, 3], otherUncoveredLines: [4, 5],
            authorityCoveredFunctions: 1, otherCoveredFunctions: 1
        )
        try fixture.writeDiff(authorityLines: [2], otherLines: [])
        try fixture.writeBaseline(line: 95, function: 90)

        let report = AgentHarnessCoverageVerifier.verify(fixture.configuration())
        let codes = Set(report.diagnostics.map(\.code))
        XCTAssertFalse(report.succeeded)
        XCTAssertTrue(codes.contains("AHV-COVERAGE-TARGET-LINE-FLOOR"))
        XCTAssertTrue(codes.contains("AHV-COVERAGE-TARGET-FUNCTION-FLOOR"))
        XCTAssertTrue(codes.contains("AHV-COVERAGE-CRITICAL-LINE-FLOOR"))
        XCTAssertTrue(codes.contains("AHV-COVERAGE-CRITICAL-FUNCTION-FLOOR"))
        XCTAssertTrue(codes.contains("AHV-COVERAGE-CRITICAL-UNCOVERED-FUNCTION"))
        XCTAssertTrue(codes.contains("AHV-COVERAGE-CHANGED-LINE-FLOOR"))
        XCTAssertTrue(codes.contains("AHV-COVERAGE-CHANGED-FUNCTION-FLOOR"))
        XCTAssertTrue(codes.contains("AHV-COVERAGE-BASELINE-REGRESSION"))
        XCTAssertEqual(report.metrics.changedExecutableLines.locations.map(\.line), [2])
        XCTAssertEqual(report.metrics.critical.uncoveredFunctions.count, 1)
        XCTAssertEqual(report.diagnostics.first {
            $0.code == "AHV-COVERAGE-CRITICAL-UNCOVERED-FUNCTION"
        }?.message, "critical sources contain 1 uncovered function(s)")
    }

    // TEST-ID: AHT-INFRA-007
    func testMissingAndEmptyEvidenceFailClosed() throws {
        let missing = try CoverageFixture()
        try FileManager.default.removeItem(at: missing.coverageURL)
        try FileManager.default.removeItem(at: missing.xunitURL)
        try FileManager.default.removeItem(at: missing.diffURL)
        let missingCodes = Set(
            AgentHarnessCoverageVerifier.verify(missing.configuration()).diagnostics.map(\.code)
        )
        XCTAssertTrue(missingCodes.contains("AHV-COVERAGE-INPUT-MISSING"))
        XCTAssertTrue(missingCodes.contains("AHV-COVERAGE-DIFF-MISSING"))
        XCTAssertTrue(missingCodes.contains("AHV-TEST-EVIDENCE-MISSING"))
        XCTAssertTrue(missingCodes.contains("AHV-COVERAGE-EMPTY"))

        let empty = try CoverageFixture()
        try empty.writeJSON([
            "type": "llvm.coverage.json.export", "version": "2.0.1", "data": [],
        ], to: empty.coverageURL)
        try Data("<testsuites/>".utf8).write(to: empty.xunitURL)
        let emptyCodes = Set(
            AgentHarnessCoverageVerifier.verify(empty.configuration()).diagnostics.map(\.code)
        )
        XCTAssertTrue(emptyCodes.contains("AHV-COVERAGE-EMPTY"))
        XCTAssertTrue(emptyCodes.contains("AHV-TEST-EVIDENCE-EMPTY"))
    }

    func testStructuredXUnitFailuresErrorsAndSkipsAreRejected() throws {
        let fixture = try CoverageFixture()
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <testsuites>
          <testsuite name="AgentContractsTests">
            <testcase classname="IDs" name="testFailure"><failure message="no"/></testcase>
            <testcase classname="IDs" name="testError"><error message="boom"/></testcase>
            <testcase classname="IDs" name="testSkip"><skipped/></testcase>
          </testsuite>
        </testsuites>
        """.utf8).write(to: fixture.xunitURL)

        let report = AgentHarnessCoverageVerifier.verify(fixture.configuration())
        let codes = Set(report.diagnostics.map(\.code))
        XCTAssertTrue(codes.contains("AHV-TEST-EVIDENCE-FAILURE"))
        XCTAssertTrue(codes.contains("AHV-TEST-EVIDENCE-SKIP"))
        XCTAssertEqual(report.metrics.tests.tests, 3)
        XCTAssertEqual(report.metrics.tests.failures, 1)
        XCTAssertEqual(report.metrics.tests.errors, 1)
        XCTAssertEqual(report.metrics.tests.skipped, 1)
    }

    func testMalformedCoverageSegmentsDiffAndXUnitAreRejected() throws {
        let fixture = try CoverageFixture()
        var coverage = try fixture.readJSON(fixture.coverageURL)
        var dataSets = coverage["data"] as! [[String: Any]]
        var files = dataSets[0]["files"] as! [[String: Any]]
        files[0]["segments"] = [[1, "bad"]]
        dataSets[0]["files"] = files
        coverage["data"] = dataSets
        try fixture.writeJSON(coverage, to: fixture.coverageURL)
        try Data("+++ b/Packages/AgentContracts/Sources/AgentContracts/Authority.swift\n@@ bad\n".utf8)
            .write(to: fixture.diffURL)
        try Data("<testsuites><testcase>".utf8).write(to: fixture.xunitURL)

        let codes = Set(
            AgentHarnessCoverageVerifier.verify(fixture.configuration()).diagnostics.map(\.code)
        )
        XCTAssertTrue(codes.contains("AHV-COVERAGE-SEGMENT"))
        XCTAssertTrue(codes.contains("AHV-COVERAGE-DIFF"))
        XCTAssertTrue(codes.contains("AHV-TEST-EVIDENCE-DECODE"))

        let invalidJSON = try CoverageFixture()
        try Data("{".utf8).write(to: invalidJSON.coverageURL)
        let diagnostic = AgentHarnessCoverageVerifier.verify(invalidJSON.configuration()).diagnostics
            .first { $0.code == "AHV-COVERAGE-DECODE" }
        XCTAssertNotNil(diagnostic)
        XCTAssertTrue(diagnostic?.message.contains("llvm-cov export is not valid JSON:") == true)
        XCTAssertFalse(diagnostic?.message.contains("(error.localizedDescription)") == true)
    }

    func testChangedDiffAcceptsDeletedSourcesAndRejectsImpossibleDeletedFileAdditions() throws {
        let fixture = try CoverageFixture()
        let deletedPath = fixture.sourceRoot + "/Deleted.swift"
        try Data("""
        diff --git a/\(deletedPath) b/\(deletedPath)
        deleted file mode 100644
        --- a/\(deletedPath)
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -func removedOne() {}
        -func removedTwo() {}

        """.utf8).write(to: fixture.diffURL)

        var report = AgentHarnessCoverageVerifier.verify(fixture.configuration())
        XCTAssertTrue(report.succeeded, report.diagnostics.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(report.metrics.changedExecutableLines.lines.count, 0)
        XCTAssertEqual(report.metrics.changedExecutableLines.functions.count, 0)

        try Data("""
        diff --git a/\(deletedPath) b/\(deletedPath)
        deleted file mode 100644
        --- a/\(deletedPath)
        +++ /dev/null
        @@ -1,2 +1,1 @@
        +impossible-current-line

        """.utf8).write(to: fixture.diffURL)

        report = AgentHarnessCoverageVerifier.verify(fixture.configuration())
        XCTAssertFalse(report.succeeded)
        XCTAssertTrue(report.diagnostics.contains {
            $0.code == "AHV-COVERAGE-DIFF"
                && $0.message == "deleted-file diff hunk must add zero current-file lines"
        })
    }

    func testPendingFirstBaselineDoesNotInventAComparison() throws {
        let fixture = try CoverageFixture()
        try fixture.writeBaseline(line: nil, function: nil)
        let report = AgentHarnessCoverageVerifier.verify(fixture.configuration())
        XCTAssertTrue(report.succeeded, report.diagnostics.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(report.metrics.baseline.status, "not-established")
        XCTAssertNil(report.metrics.baseline.baselineLinePercent)
        XCTAssertNil(report.metrics.baseline.baselineFunctionPercent)
    }

    func testMissingPolicyScopeBaselineAndCriticalSelectorFailClosed() throws {
        let fixture = try CoverageFixture()
        try fixture.writePolicy(includeTarget: false)
        try fixture.writeJSON([
            "documentType": "baseline", "entries": [],
        ], to: fixture.baselineURL)
        let configuration = CoverageVerificationConfiguration(
            scope: "AgentContracts", repositoryRoot: fixture.root,
            sourceRoot: fixture.sourceRoot,
            llvmCoverageURL: fixture.coverageURL,
            xunitURL: fixture.xunitURL,
            policyURL: fixture.policyURL,
            baselineURL: fixture.baselineURL,
            reportSchemaURL: fixture.reportSchemaURL,
            changedDiffURL: fixture.diffURL,
            criticalSources: [fixture.sourceRoot + "/Missing.swift"]
        )
        let codes = Set(AgentHarnessCoverageVerifier.verify(configuration).diagnostics.map(\.code))
        XCTAssertTrue(codes.contains("AHV-COVERAGE-POLICY"))
        XCTAssertTrue(codes.contains("AHV-COVERAGE-BASELINE"))
        XCTAssertTrue(codes.contains("AHV-COVERAGE-CRITICAL-MISSING"))
    }

    // TEST-ID: AHT-INFRA-007
    func testEverySwiftSourceMustAppearInCoverageExport() throws {
        let fixture = try CoverageFixture()
        let missing = fixture.root.appending(path: fixture.sourceRoot + "/Unmeasured.swift")
        try Data("func neverMeasured() {}\n".utf8).write(to: missing)

        let report = AgentHarnessCoverageVerifier.verify(fixture.configuration())
        XCTAssertFalse(report.succeeded)
        XCTAssertEqual(report.diagnostics.first {
            $0.code == "AHV-COVERAGE-SOURCE-UNMEASURED"
        }?.location, fixture.sourceRoot + "/Unmeasured.swift")
    }

    func testChangedFunctionGateUsesLLVMSourceRegionsAndFailsClosedWithoutMapping() throws {
        let fixture = try CoverageFixture()
        try fixture.writeCoverage(authorityCoveredFunctions: 1)
        try fixture.writeDiff(authorityLines: [2], otherLines: [])
        var report = AgentHarnessCoverageVerifier.verify(fixture.configuration())
        XCTAssertTrue(report.diagnostics.contains {
            $0.code == "AHV-COVERAGE-CHANGED-FUNCTION-FLOOR"
        })
        XCTAssertEqual(report.metrics.changedExecutableLines.functions.count, 1)
        XCTAssertEqual(report.metrics.changedExecutableLines.functions.covered, 0)

        var coverage = try fixture.readJSON(fixture.coverageURL)
        var dataSets = coverage["data"] as! [[String: Any]]
        var functions = dataSets[0]["functions"] as! [[String: Any]]
        functions[0]["regions"] = []
        dataSets[0]["functions"] = functions
        coverage["data"] = dataSets
        try fixture.writeJSON(coverage, to: fixture.coverageURL)
        report = AgentHarnessCoverageVerifier.verify(fixture.configuration())
        let codes = Set(report.diagnostics.map(\.code))
        XCTAssertTrue(codes.contains("AHV-COVERAGE-FUNCTION-REGION"))
        XCTAssertTrue(codes.contains("AHV-COVERAGE-CHANGED-FUNCTION-EVIDENCE"))
        XCTAssertFalse(codes.contains("AHV-COVERAGE-REPORT-SCHEMA-INSTANCE"))
        XCTAssertTrue(AgentHarnessCoverageVerifier.validateReportData(
            try AgentHarnessCoverageVerifier.encodedReport(report),
            schemaURL: fixture.reportSchemaURL
        ).isEmpty, "fail-closed reports must remain valid machine-readable evidence")
    }

    func testCoverageReportSchemaRejectsTamperedOrMissingEvidence() throws {
        let fixture = try CoverageFixture()
        let report = AgentHarnessCoverageVerifier.verify(fixture.configuration())
        XCTAssertTrue(report.succeeded, report.diagnostics.map(\.message).joined(separator: "\n"))
        let validData = try AgentHarnessCoverageVerifier.encodedReport(report)
        XCTAssertTrue(AgentHarnessCoverageVerifier.validateReportData(
            validData, schemaURL: fixture.reportSchemaURL
        ).isEmpty)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: validData) as? [String: Any]
        )
        object.removeValue(forKey: "metrics")
        let invalidData = try JSONSerialization.data(withJSONObject: object)
        XCTAssertTrue(AgentHarnessCoverageVerifier.validateReportData(
            invalidData, schemaURL: fixture.reportSchemaURL
        ).contains { $0.code == "AHV-COVERAGE-REPORT-SCHEMA-INSTANCE" })

        let missingSchema = fixture.root.appending(path: "missing-report-schema.json")
        XCTAssertTrue(AgentHarnessCoverageVerifier.validateReportData(
            validData, schemaURL: missingSchema
        ).contains { $0.code == "AHV-COVERAGE-REPORT-SCHEMA-MISSING" })
    }

    func testBooleanCoverageNumbersAreRejected() throws {
        let fixture = try CoverageFixture()
        var policy = try fixture.readJSON(fixture.policyURL)
        var floors = policy["floors"] as! [[String: Any]]
        floors[0]["linePercent"] = true
        policy["floors"] = floors
        try fixture.writeJSON(policy, to: fixture.policyURL)
        XCTAssertTrue(AgentHarnessCoverageVerifier.verify(fixture.configuration()).diagnostics
            .contains { $0.code == "AHV-COVERAGE-POLICY" })
    }

    func testOutOfRangeLLVMIntegersFailClosedWithoutTrapping() throws {
        let fixture = try CoverageFixture()
        var coverage = try fixture.readJSON(fixture.coverageURL)
        var dataSets = coverage["data"] as! [[String: Any]]
        var files = dataSets[0]["files"] as! [[String: Any]]
        var segments = files[0]["segments"] as! [[Any]]
        segments[0][2] = NSNumber(value: UInt64.max)
        files[0]["segments"] = segments
        dataSets[0]["files"] = files
        coverage["data"] = dataSets
        try fixture.writeJSON(coverage, to: fixture.coverageURL)

        let report = AgentHarnessCoverageVerifier.verify(fixture.configuration())
        XCTAssertFalse(report.succeeded)
        XCTAssertTrue(report.diagnostics.contains { $0.code == "AHV-COVERAGE-SEGMENT" })
    }

    func testLLVMIntMaxExecutionCountersRemainValidIntegers() throws {
        let fixture = try CoverageFixture()
        var coverage = try fixture.readJSON(fixture.coverageURL)
        var dataSets = coverage["data"] as! [[String: Any]]
        var files = dataSets[0]["files"] as! [[String: Any]]
        var segments = files[0]["segments"] as! [[Any]]
        segments[0][2] = NSNumber(value: Int64.max)
        files[0]["segments"] = segments
        dataSets[0]["files"] = files
        var functions = dataSets[0]["functions"] as! [[String: Any]]
        var regions = functions[0]["regions"] as! [[Any]]
        regions[0][4] = NSNumber(value: Int64.max)
        functions[0]["regions"] = regions
        dataSets[0]["functions"] = functions
        coverage["data"] = dataSets
        try fixture.writeJSON(coverage, to: fixture.coverageURL)

        let report = AgentHarnessCoverageVerifier.verify(fixture.configuration())
        XCTAssertTrue(report.succeeded, report.diagnostics.map(\.message).joined(separator: "\n"))
    }
}

private final class CoverageFixture {
    let root: URL
    let sourceRoot = "Packages/AgentContracts/Sources/AgentContracts"
    let coverageURL: URL
    let xunitURL: URL
    let policyURL: URL
    let baselineURL: URL
    let diffURL: URL
    let reportSchemaURL: URL

    private var authorityPath: String { sourceRoot + "/Authority.swift" }
    private var otherPath: String { sourceRoot + "/Other.swift" }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "agent-harness-coverage-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        let sources = root.appending(path: sourceRoot, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        coverageURL = root.appending(path: "llvm-cov.json")
        xunitURL = root.appending(path: "tests.xml")
        policyURL = root.appending(path: "policy.json")
        baselineURL = root.appending(path: "baseline.json")
        diffURL = root.appending(path: "changed.diff")
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repositoryRoot.deleteLastPathComponent() }
        reportSchemaURL = repositoryRoot.appending(
            path: "Verification/AgentHarness/Schemas/coverage-report.schema.json"
        )
        try Data((1...10).map { "func authority\($0)() {}" }.joined(separator: "\n").utf8)
            .write(to: root.appending(path: authorityPath))
        try Data((1...10).map { "func other\($0)() {}" }.joined(separator: "\n").utf8)
            .write(to: root.appending(path: otherPath))
        try writeCoverage()
        try writeXUnit()
        try writePolicy()
        try writeBaseline(line: 94, function: 99)
        try writeDiff(authorityLines: [2], otherLines: [10])
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func configuration() -> CoverageVerificationConfiguration {
        CoverageVerificationConfiguration(
            scope: "AgentContracts", repositoryRoot: root, sourceRoot: sourceRoot,
            llvmCoverageURL: coverageURL, xunitURL: xunitURL,
            policyURL: policyURL, baselineURL: baselineURL,
            reportSchemaURL: reportSchemaURL,
            changedDiffURL: diffURL,
            criticalSources: [authorityPath],
            generatedAt: ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z")!
        )
    }

    func writeCoverage(
        authorityUncoveredLines: Set<Int> = [],
        otherUncoveredLines: Set<Int> = [9],
        authorityCoveredFunctions: Int = 2,
        otherCoveredFunctions: Int = 2
    ) throws {
        let authorityURL = root.appending(path: authorityPath).path
        let otherURL = root.appending(path: otherPath).path
        let file: (String, Set<Int>, Int) -> [String: Any] = { path, uncovered, functions in
            [
                "filename": path,
                "summary": [
                    "lines": ["count": 10, "covered": 10 - uncovered.count, "percent": 0],
                    "functions": ["count": 2, "covered": functions, "percent": 0],
                ],
                "segments": (1...10).flatMap { line -> [[Any]] in
                    let count = uncovered.contains(line) ? 0 : 1
                    return [
                        [line, 1, count, true, true, false],
                        [line, 20, 0, false, false, false],
                    ]
                },
            ]
        }
        let function: (String, String, Int, Int, Int) -> [String: Any] = {
            name, path, count, startLine, endLine in
            [
                "name": name,
                "count": count,
                "filenames": [path],
                "regions": [[startLine, 1, endLine, 20, count, 0, 0, 0]],
            ]
        }
        try writeJSON([
            "type": "llvm.coverage.json.export",
            "version": "2.0.1",
            "data": [[
                "files": [
                    file(authorityURL, authorityUncoveredLines, authorityCoveredFunctions),
                    file(otherURL, otherUncoveredLines, otherCoveredFunctions),
                ],
                "functions": [
                    function("authority.first", authorityURL,
                             authorityCoveredFunctions == 2 ? 1 : 0, 1, 5),
                    function("authority.second", authorityURL, 1, 6, 10),
                    function("other.first", otherURL,
                             otherCoveredFunctions == 2 ? 1 : 0, 1, 5),
                    function("other.second", otherURL, 1, 6, 10),
                ],
                "totals": [:],
            ]],
        ], to: coverageURL)
    }

    func writeXUnit() throws {
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <testsuites>
          <testsuite name="AgentContractsTests">
            <testcase classname="IDs" name="testRoundTrip"/>
            <testcase classname="Versions" name="testEnvelope"/>
          </testsuite>
        </testsuites>
        """.utf8).write(to: xunitURL)
    }

    func writePolicy(includeTarget: Bool = true) throws {
        var floors: [[String: Any]] = [
            ["scope": "security-critical-runtime-components", "linePercent": 95,
             "functionPercent": 100, "baselineMayDecrease": false],
            ["scope": "changed-agent-harness-lines-and-adapters", "linePercent": 90,
             "functionPercent": 90, "baselineMayDecrease": false],
        ]
        if includeTarget {
            floors.append(["scope": "AgentContracts", "linePercent": 90,
                           "functionPercent": 90, "baselineMayDecrease": false])
        }
        try writeJSON(["documentType": "policy", "floors": floors], to: policyURL)
    }

    func writeBaseline(line: Double?, function: Double?) throws {
        try writeJSON([
            "documentType": "baseline",
            "entries": [[
                "scope": "AgentContracts",
                "status": line == nil ? "target-not-yet-present" : "measured",
                "linePercent": line.map { $0 as Any } ?? NSNull(),
                "functionPercent": function.map { $0 as Any } ?? NSNull(),
            ]],
        ], to: baselineURL)
    }

    func writeDiff(authorityLines: [Int], otherLines: [Int]) throws {
        var text = ""
        for (path, lines) in [(authorityPath, authorityLines), (otherPath, otherLines)]
            where !lines.isEmpty {
            text += "diff --git a/\(path) b/\(path)\n--- a/\(path)\n+++ b/\(path)\n"
            for line in lines.sorted() { text += "@@ -\(line),0 +\(line),1 @@\n+changed\n" }
        }
        try Data(text.utf8).write(to: diffURL)
    }

    func readJSON(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }
}

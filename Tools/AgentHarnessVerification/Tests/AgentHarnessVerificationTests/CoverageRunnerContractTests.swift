// SPDX-License-Identifier: MIT

import Foundation
import XCTest

final class CoverageRunnerContractTests: XCTestCase {
    // TEST-ID: AHT-INFRA-007
    func testRunnerExecutesTestsExactlyOnceAndUsesTheInstrumentationProfile() throws {
        let script = try coverageRunnerSource()
        let testInvocations = script.components(separatedBy: "swift test").count - 1

        XCTAssertEqual(testInvocations, 1, "coverage runner must execute the package tests exactly once")
        XCTAssertTrue(script.contains("--enable-xctest"))
        XCTAssertTrue(script.contains("--disable-swift-testing"))
        XCTAssertTrue(script.contains("--parallel"))
        XCTAssertTrue(script.contains("--num-workers 1"))
        XCTAssertTrue(script.contains("--xunit-output \"$xunit_path\""))
        XCTAssertTrue(script.contains("profile_path=\"$bin_path/codecov/default.profdata\""))
        XCTAssertFalse(script.contains("--show-codecov-path"),
                       "SwiftPM's show-codecov path is exported JSON, not profdata")
    }

    func testRunnerIncludesWorkingTreeChangesAndRejectsUntrackedSwiftSources() throws {
        let script = try coverageRunnerSource()

        XCTAssertTrue(script.contains("ls-files --others --exclude-standard -z"))
        XCTAssertTrue(script.contains("untracked Swift production source must be staged"))
        XCTAssertTrue(script.contains("merge-base \"$base_ref\" HEAD"))
        XCTAssertTrue(script.contains("\"$comparison_base\" -- \"$source_root\""))
        XCTAssertFalse(script.contains("\"$base_ref\"...HEAD"))
        XCTAssertFalse(script.contains("\"$base_ref\" -- \"$source_root\""))
    }

    func testAgentContractsCriticalSelectorsCoverUntrustedBoundaryDecisions() throws {
        let script = try coverageRunnerSource()

        for source in [
            "ArtifactsAndFailures.swift", "Authority.swift", "Budgets.swift",
            "ContractPrimitives.swift", "ExternalOperations.swift", "ToolContracts.swift",
            "WireValidation.swift",
        ] {
            XCTAssertTrue(script.contains("$source_root/\(source)"), source)
        }
    }

    private func coverageRunnerSource() throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try String(
            contentsOf: root.appending(path: "scripts/verification/run-agent-package-coverage.sh"),
            encoding: .utf8
        )
    }
}

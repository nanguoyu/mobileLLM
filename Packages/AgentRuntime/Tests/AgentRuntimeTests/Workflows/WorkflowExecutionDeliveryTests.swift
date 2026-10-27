// SPDX-License-Identifier: MIT
import AgentContracts
@testable import AgentRuntime
import Foundation
import XCTest

// TEST-ID: AHT-SANDBOX-001
final class WorkflowExecutionDeliveryTests: XCTestCase {
    func testToolAliasesResolveOnlyUniqueAlreadyPermittedNames() throws {
        let run = try AgentToolLogicalID(providerID: "sandbox", name: "sandbox_run")
        let browser = try AgentToolLogicalID(providerID: "sandbox", name: "sandbox_browser")
        let sameName = try AgentToolLogicalID(providerID: "custom", name: "sandbox_run")
        let aliases = WorkflowToolAliases.uniqueAliases(for: [run, browser, sameName])
        XCTAssertNil(aliases["sandbox_run"], "A bare ambiguous name must not select a provider")
        XCTAssertEqual(aliases["sandbox.sandbox_run"], run.description)
        XCTAssertEqual(aliases[run.description], run.description)
        XCTAssertEqual(aliases["sandbox_browser"], browser.description)
        XCTAssertNil(aliases["sandbox_write_files"], "Aliases cannot introduce unavailable tools")
    }

    func testDeliveryRejectsStaleUnreviewedForeignAndStoppedExecution() throws {
        let scope = SandboxWorkspaceHandleID(), source = StableDigest.sha256(Data("source-1".utf8))
        func receipt(_ operation: String, _ time: Int64, digest: StableDigest? = nil,
                     workspace: SandboxWorkspaceHandleID? = nil, success: Bool = true, running: Bool? = nil,
                     artifact: String? = nil) throws -> WorkflowReviewToolEvidence {
            var artifacts: [ArtifactReference] = []
            if let artifact {
                artifacts = [try ArtifactReference(id: ArtifactID(), contentDigest: source, byteCount: 10,
                    mimeType: artifact == "sandbox.project-source" ? "application/zip" : "image/jpeg",
                    semanticType: artifact, provenance: ArtifactProvenance(runID: AgentRunID()),
                    createdAt: AgentTimestamp(rawValue: time), retentionPolicy: .run,
                    locator: ArtifactLocator(kind: .managedRelativePath, value: "test/artifact"),
                    sensitivity: .sensitive, integrityStatus: .verified)]
            }
            return WorkflowReviewToolEvidence(toolID: operation, invocationID: ToolInvocationID(), recordDigest: source,
                execution: WorkflowSandboxEvidence(workspaceID: workspace ?? scope, sourceDigest: digest ?? source,
                    operation: operation, port: 8080, processID: "test-process", running: running, artifacts: artifacts),
                completedAt: AgentTimestamp(rawValue: time), succeeded: success)
        }
        let start = try receipt("sandbox_start", 1, running: true)
        let browser = try receipt("sandbox_browser", 2, artifact: "sandbox.browser-screenshot")
        let export = try receipt("sandbox_export", 3, artifact: "sandbox.project-source")
        let policy = WorkflowDeliveryPolicy(requestedOutcome: .runningApplication,
            availableCapabilities: [.workspaceFiles, .codeExecution, .applicationInspection])
        let good = [start, browser, export]
        XCTAssertNil(policy.completionBlocker(workspaceID: scope, evidence: good, acceptedReviewEvidence: [browser, export]))
        XCTAssertNotNil(policy.completionBlocker(workspaceID: scope, evidence: good, acceptedReviewEvidence: []))
        XCTAssertNotNil(policy.completionBlocker(workspaceID: scope, evidence: good, acceptedReviewEvidence: [export]))
        XCTAssertNotNil(policy.completionBlocker(workspaceID: SandboxWorkspaceHandleID(), evidence: good, acceptedReviewEvidence: good))
        let changed = try receipt("sandbox_run", 4, digest: .sha256(Data("changed-by-failed-test".utf8)), success: false)
        XCTAssertNotNil(policy.completionBlocker(workspaceID: scope, evidence: good + [changed], acceptedReviewEvidence: good))
        let stop = try receipt("sandbox_stop", 4, running: false)
        XCTAssertNotNil(policy.completionBlocker(workspaceID: scope, evidence: good + [stop], acceptedReviewEvidence: good))
        let unknown = WorkflowReviewToolEvidence(toolID: "sandbox_run", invocationID: ToolInvocationID(), recordDigest: source,
            execution: WorkflowSandboxEvidence(workspaceID: scope, sourceDigest: nil, operation: "sandbox_run"),
            completedAt: AgentTimestamp(rawValue: 4), succeeded: false)
        XCTAssertNotNil(policy.completionBlocker(workspaceID: scope, evidence: good + [unknown], acceptedReviewEvidence: good),
            "A known failed command without current source evidence cannot validate a stale delivery")
        XCTAssertNotNil(policy.completionBlocker(workspaceID: scope, evidence: Array(good.dropFirst()), acceptedReviewEvidence: good))
    }
}

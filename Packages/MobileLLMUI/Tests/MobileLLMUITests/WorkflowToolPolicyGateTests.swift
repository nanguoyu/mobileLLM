// SPDX-License-Identifier: MIT

import XCTest
import AgentContracts
import AgentRuntime
@testable import MobileLLMUI
@testable import LLMCore

/// The workflow tool gate (spec §33 gap 1): staged workflows inherit only the conversation's allowed
/// tools; missing research tools must surface for explicit enablement, never be force-enabled.
final class WorkflowToolPolicyGateTests: XCTestCase {

    func testMissingWhenMasterToolSwitchIsOff() {
        let policy = try! policy(masterEnabled: false, allowed: [.webSearch, .fetchWebpage])
        XCTAssertEqual(
            WorkflowToolPolicyGate.missingTools(
                policy: policy,
                catalogToolNames: ToolID.allCases.map(\.rawValue),
                toolsEnabled: true
            ),
            [.webSearch, .fetchWebpage]
        )
    }

    func testMissingWhenRequiredToolNotAllowedByConversation() {
        let policy = try! policy(masterEnabled: true, allowed: [.fetchWebpage])
        XCTAssertEqual(
            WorkflowToolPolicyGate.missingTools(
                policy: policy,
                catalogToolNames: ToolID.allCases.map(\.rawValue),
                toolsEnabled: true
            ),
            [.webSearch]
        )
    }

    func testMissingWhenCatalogDoesNotAssembleTool() {
        // A stale policy cannot widen the assembled catalog (settings): the tool must exist in both.
        let policy = try! policy(masterEnabled: true, allowed: [.webSearch, .fetchWebpage])
        XCTAssertEqual(
            WorkflowToolPolicyGate.missingTools(
                policy: policy,
                catalogToolNames: ["web_search"],
                toolsEnabled: true
            ),
            [.fetchWebpage]
        )
    }

    func testMissingWhenLegacyConversationHasNoPolicyAndToolsOff() {
        XCTAssertEqual(
            WorkflowToolPolicyGate.missingTools(
                policy: nil,
                catalogToolNames: ToolID.allCases.map(\.rawValue),
                toolsEnabled: false
            ),
            [.webSearch, .fetchWebpage]
        )
    }

    func testSatisfiedWhenConversationAllowsResearchToolset() {
        let policy = try! policy(masterEnabled: true, allowed: [.webSearch, .fetchWebpage])
        XCTAssertEqual(
            WorkflowToolPolicyGate.missingTools(
                policy: policy,
                catalogToolNames: ToolID.allCases.map(\.rawValue),
                toolsEnabled: true
            ),
            []
        )
    }

    func testSatisfiedForLegacyConversationWithMasterOn() {
        XCTAssertEqual(
            WorkflowToolPolicyGate.missingTools(
                policy: nil,
                catalogToolNames: ["web_search", "fetch_webpage", "wikipedia"],
                toolsEnabled: true
            ),
            []
        )
    }

    func testDisplayNamesAndErrorDescriptionAreUserFacing() {
        XCTAssertEqual(WorkflowToolPolicyGate.displayName(for: .webSearch), "Web search")
        XCTAssertEqual(WorkflowToolPolicyGate.displayName(for: .fetchWebpage), "Webpage reader")
        let error = WorkflowToolPolicyGateError.toolsRequired([.webSearch, .fetchWebpage])
        XCTAssertEqual(
            error.errorDescription,
            "Workflow needs tools that are off: Web search, Webpage reader."
        )
    }

    private func policy(
        masterEnabled: Bool,
        allowed: [ToolID]
    ) throws -> ConversationToolPolicy {
        try ConversationToolPolicy(
            masterEnabled: masterEnabled,
            allowedToolIDs: allowed.map(WorkflowToolPolicyGate.logicalID),
            pinnedToolIDs: [],
            selectionPolicyVersion: 1,
            materializedFromGlobalTemplate: false
        )
    }
}

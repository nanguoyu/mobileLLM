// SPDX-License-Identifier: MIT

import AgentContracts
@testable import AgentRuntime
import XCTest

// TEST-ID: AHT-DYNAMIC-001
final class WorkflowAgentProfileTests: XCTestCase {
    func testRoleProfileNarrowsToolsLoadsOnlyAllowedSkillAndRespectsReasoningCeiling() throws {
        let active = try SkillInstructionContextSource(skillID: "selected-by-human", version: "1", instructions: "Keep the requested language.")
        let source = try inputs(skills: [active])
        let skill = try WorkflowSkillDefinition(id: "proofread", name: "Proofreader", summary: "Check wording", instructions: "Preserve every fact and number.")
        let parent = try source.addingWorkflowTools(availableSkills: [skill])
        XCTAssertEqual(parent.skills, [active], "Discovery must not load every pack into the model context")
        let profile = try WorkflowAgentProfileV1(toolNames: ["agent.read_artifact"], skillIDs: [skill.id], reasoningEffort: .low)
        let role = try parent.applying(profile: profile, online: true)
        XCTAssertEqual(role.toolPolicy.allowedToolIDs.map(\.name), ["read_artifact"])
        XCTAssertEqual(try role.selectedTools(latestUserRequest: "Read the stored result").descriptors.map(\.id.logicalID.name), ["read_artifact"])
        XCTAssertEqual(role.skills.map(\.frozen.sourceID), [active.frozen.sourceID, skill.id])
        XCTAssertEqual(role.generationParameters.reasoningEffort, .low)
        XCTAssertEqual(role.generationParameters.maximumOutputTokens, parent.generationParameters.maximumOutputTokens)
        XCTAssertThrowsError(try parent.applying(profile: WorkflowAgentProfileV1(reasoningEffort: .high), online: true))
        XCTAssertThrowsError(try parent.applying(profile: profile, online: false))
        XCTAssertThrowsError(try parent.applying(profile: WorkflowAgentProfileV1(toolNames: ["builtin.web_search"]), online: true))
        XCTAssertThrowsError(try parent.applying(profile: WorkflowAgentProfileV1(skillIDs: ["not-allowed"]), online: true))
        let restored = try JSONDecoder().decode(FrozenAgentRunInputs.self, from: JSONEncoder().encode(role))
        XCTAssertEqual(restored, role)
    }

    func testNewCatalogAdmissionRemovesUnavailableSkillsWithoutMutatingFrozenSources() throws {
        let source = try inputs()
        let skill = try WorkflowSkillDefinition(id: "research", name: "Research", summary: "Cite sources", instructions: "Keep source URLs.")
        let old = try source.addingWorkflowTools(availableSkills: [skill])
        let fresh = try old.addingWorkflowTools(availableSkills: [])
        XCTAssertEqual(old.skillCatalog?.first?.instructions, "Keep source URLs.")
        XCTAssertNil(fresh.skillCatalog)
        XCTAssertFalse(fresh.toolPolicy.allowedToolIDs.contains { $0.name == "read_skill" || $0.name == "list_skills" })
        XCTAssertFalse(fresh.toolCatalog.descriptors.contains { $0.id.logicalID.name == "read_skill" })
        XCTAssertThrowsError(try fresh.applying(profile: WorkflowAgentProfileV1(skillIDs: [skill.id]), online: true))
    }

    private func inputs(skills: [SkillInstructionContextSource] = []) throws -> FrozenAgentRunInputs {
        let model = try ExecutorTestModelDefinition(offset: 852)
        let generation = try AgentModelGenerationParameters(maximumOutputTokens: 1024, maximumContextTokens: 8192,
            temperature: 0.2, topP: 0.9, topK: nil, repetitionPenalty: 1, thinkingMode: .enabled, seed: nil, reasoningEffort: .medium)
        return try FrozenAgentRunInputs(modelSelection: model.selection, generationParameters: generation,
            contextBudget: ContextTokenBudget(maximumContextTokens: 8192, reservedOutputTokens: 1024, maximumToolSchemaTokens: 2048),
            baseSystem: BaseSystemContextSource(revision: "1", content: "Follow the user goal."), skills: skills,
            currentUser: CurrentUserContextSource(userTurnID: UserTurnID(), revision: "1", content: "Review the source."),
            toolCatalog: ToolCatalogSnapshot(revision: 1, descriptors: []),
            toolPolicy: ConversationToolPolicy(masterEnabled: false, allowedToolIDs: [], selectionPolicyVersion: 1, materializedFromGlobalTemplate: false),
            availableToolCapabilities: AgentCapabilitySet([.localRead, .localWrite]), contextPolicyVersion: 2, approvalPolicyVersion: 1)
    }
}

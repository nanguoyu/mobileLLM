// SPDX-License-Identifier: MIT
// TEST-ID: AHT-DYNAMIC-001
import XCTest
import AgentContracts
@testable import AgentRuntime

final class WorkflowOutputLimitsTests: XCTestCase {
    func testHumanLimitsCountTheWholeDeliverableAndIgnoreQuotedExamples() throws {
        let limits = WorkflowOutputLimits.detecting(in: "Keep each worker under 120 words and the final plan under 160 words.")
        XCTAssertEqual(limits.workerWords, 119)
        XCTAssertEqual(limits.finalWords, 159)
        XCTAssertEqual(WorkflowOutputLimits.wordCount("## Plan\n| name | value |\n|---|---|\nAlpha beta"), 5)
        XCTAssertNotNil(WorkflowOutputLimits(finalWords: 3).finalRejection("Plan done\n\nAppendix outside limit: extra details"))
        XCTAssertNil(WorkflowOutputLimits.detecting(in: "Explain the example 'final answer under 3 words'.").finalWords)
        XCTAssertNil(WorkflowOutputLimits.detecting(in: "> final answer under 3 words").finalWords)
        XCTAssertNil(WorkflowOutputLimits.detecting(in: "```\nfinal answer under 3 words\n```").finalWords)
        XCTAssertEqual(limits.applying("Keep the final response at most 200 words.").finalWords, 200)
        XCTAssertNil(limits.applying("Remove the final word limit.").finalWords)
    }

    func testChineseCharacterLimitsAndJSONHaveDirectChecks() {
        let limits = WorkflowOutputLimits.detecting(in: "最终回复不超过5字。每个代理输出少于4字。")
        XCTAssertEqual(limits.finalCharacters, 5)
        XCTAssertEqual(limits.workerCharacters, 3)
        XCTAssertNotNil(limits.finalRejection("这段文字超过限制"))
        XCTAssertNil(limits.finalRejection("五字内"))
        let json = WorkflowOutputLimits.detecting(in: "Return ONLY JSON with the result.")
        XCTAssertTrue(json.requiresJSON)
        XCTAssertNil(json.finalRejection("{\"ok\":true}"))
        XCTAssertNotNil(json.finalRejection("```json\n{\"ok\":true}\n```"))
        XCTAssertFalse(json.applying("Use plain text instead of JSON.").requiresJSON)
    }
}

// SPDX-License-Identifier: MIT

import AgentContracts
@testable import AgentRuntime
import Foundation
import XCTest

final class ContextModelInvariantTests: XCTestCase {
    func testPersistedNumericBoundsAreRevalidatedDuringDecoding() throws {
        var estimator = try jsonObject(ContextTokenEstimatorIdentity.mobileLLMConservativeV1)
        estimator["version"] = 0
        assertDataCorrupted {
            _ = try decode(ContextTokenEstimatorIdentity.self, object: estimator)
        }

        var budget = try jsonObject(ContextTokenBudget(
            maximumContextTokens: 8,
            reservedOutputTokens: 2,
            maximumToolSchemaTokens: 2
        ))
        budget["reservedOutputTokens"] = 8
        assertDataCorrupted {
            _ = try decode(ContextTokenBudget.self, object: budget)
        }

        let overflowingRange = Data(
            #"{"offset":18446744073709551615,"length":1}"#.utf8
        )
        assertDataCorrupted {
            _ = try JSONDecoder().decode(ContextUTF8Range.self, from: overflowingRange)
        }
    }

    func testTypedTextSourcesRejectPersistedIdentitySubstitution() throws {
        let message = MessageID(rawValue: uuid(1))
        var conversation = try jsonObject(ConversationTurnContextSource(
            messageID: message,
            revision: "1",
            role: .assistant,
            content: "answer"
        ))
        mutateFrozenSourceID(&conversation, key: "frozen", sourceID: "not-a-message-id")
        assertDataCorrupted {
            _ = try decode(ConversationTurnContextSource.self, object: conversation)
        }

        var currentUser = try jsonObject(CurrentUserContextSource(
            userTurnID: UserTurnID(rawValue: uuid(2)),
            revision: "1",
            content: "question"
        ))
        mutateFrozenSourceID(&currentUser, key: "frozen", sourceID: "not-a-user-turn-id")
        assertDataCorrupted {
            _ = try decode(CurrentUserContextSource.self, object: currentUser)
        }

        var runState = try jsonObject(RunStateContextSource(
            revision: "1",
            canonicalState: CanonicalJSON(.object(["ready": .bool(true)]))
        ))
        runState["sourceID"] = "run.other"
        assertDataCorrupted {
            _ = try decode(RunStateContextSource.self, object: runState)
        }

        let artifact = try ModelFixture.imageArtifact()
        var excerpt = try jsonObject(ArtifactExcerptContextSource(
            artifact: artifact,
            excerptRevision: "1",
            excerpt: "quoted material"
        ))
        mutateFrozenSourceID(&excerpt, key: "frozen", sourceID: "artifact.substituted")
        assertDataCorrupted {
            _ = try decode(ArtifactExcerptContextSource.self, object: excerpt)
        }

        let tool = try ModelFixture.tool()
        var toolResult = try jsonObject(UntrustedToolResultContextSource(
            invocationID: ToolInvocationID(rawValue: uuid(3)),
            descriptorID: tool.id,
            resultRevision: "1",
            resultContent: "untrusted output"
        ))
        mutateFrozenSourceID(&toolResult, key: "frozen", sourceID: "tool-result.substituted")
        assertDataCorrupted {
            _ = try decode(UntrustedToolResultContextSource.self, object: toolResult)
        }
    }

    func testTypedPolicySourcesRecheckNonEmptyContentWhenDecoded() throws {
        var base = try jsonObject(BaseSystemContextSource(revision: "1", content: "policy"))
        replaceFrozenContent(&base, content: " \n")
        assertDataCorrupted {
            _ = try decode(BaseSystemContextSource.self, object: base)
        }

        var skill = try jsonObject(SkillInstructionContextSource(
            skillID: "skill.example",
            version: "1",
            instructions: "instructions"
        ))
        replaceFrozenContent(&skill, content: "\t")
        assertDataCorrupted {
            _ = try decode(SkillInstructionContextSource.self, object: skill)
        }

        var memory = try jsonObject(CanonicalEnglishMemoryContextSource(
            memoryID: "memory.example",
            revision: "1",
            canonicalEnglishContent: "memory"
        ))
        replaceFrozenContent(&memory, content: "\n")
        assertDataCorrupted {
            _ = try decode(CanonicalEnglishMemoryContextSource.self, object: memory)
        }
    }

    func testUntrustedRecordsCannotBeReframedAsTrustedOrExceedFrozenBounds() throws {
        let contentDigest = StableDigest.sha256(Data("data".utf8))
        let renderedDigest = StableDigest.sha256(Data("rendered".utf8))
        let range = try ContextUTF8Range(offset: 0, length: 4)

        XCTAssertThrowsError(try CompiledContextSourceRecord(
            kind: .currentUser,
            sourceID: "current.user",
            revision: "1",
            role: .tool,
            isUntrustedData: false,
            originalContentDigest: contentDigest,
            originalUTF8ByteCount: 4,
            originalEstimatedTokens: 1,
            disposition: .included,
            selectedUTF8Range: range,
            selectedContentDigest: contentDigest,
            renderedMessageDigest: renderedDigest,
            adoptedEstimatedTokens: 1,
            omissionReason: nil
        ))

        let artifact = try ModelFixture.imageArtifact()
        XCTAssertThrowsError(try CompiledContextSourceRecord(
            kind: .artifactExcerpt,
            sourceID: artifact.id.description,
            revision: "1",
            role: .user,
            isUntrustedData: false,
            originalContentDigest: contentDigest,
            originalUTF8ByteCount: 4,
            originalEstimatedTokens: 1,
            disposition: .included,
            selectedUTF8Range: range,
            selectedContentDigest: contentDigest,
            renderedMessageDigest: renderedDigest,
            adoptedEstimatedTokens: 1,
            omissionReason: nil,
            artifactID: artifact.id,
            artifactContentDigest: artifact.contentDigest
        ))

        let oversizedCount = UInt64(FrozenContextText.maximumUTF8Bytes + 1)
        XCTAssertThrowsError(try CompiledContextSourceRecord(
            kind: .currentUser,
            sourceID: "current.user",
            revision: "1",
            role: .user,
            isUntrustedData: false,
            originalContentDigest: contentDigest,
            originalUTF8ByteCount: oversizedCount,
            originalEstimatedTokens: 1,
            disposition: .included,
            selectedUTF8Range: ContextUTF8Range(offset: 0, length: oversizedCount),
            selectedContentDigest: contentDigest,
            renderedMessageDigest: renderedDigest,
            adoptedEstimatedTokens: 1,
            omissionReason: nil
        ))
    }
}

private func jsonObject<Value: Encodable>(_ value: Value) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func decode<Value: Decodable>(
    _ type: Value.Type,
    object: [String: Any]
) throws -> Value {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return try JSONDecoder().decode(type, from: data)
}

private func mutateFrozenSourceID(
    _ object: inout [String: Any],
    key: String,
    sourceID: String
) {
    var frozen = object[key] as! [String: Any]
    frozen["sourceID"] = sourceID
    object[key] = frozen
}

private func replaceFrozenContent(_ object: inout [String: Any], content: String) {
    object["content"] = content
    object["contentDigest"] = StableDigest.sha256(Data(content.utf8)).rawValue
}

private func assertDataCorrupted(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () throws -> Void
) {
    do {
        try operation()
        XCTFail("Expected data-corrupted decoding failure", file: file, line: line)
    } catch is DecodingError {
        // Expected: persisted input is rejected before it can become a trusted context value.
    } catch {
        XCTFail("Expected DecodingError, got \(error)", file: file, line: line)
    }
}

private func uuid(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
}

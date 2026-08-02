// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
@_spi(AgentRuntime) @testable import AgentRuntime
import Foundation
import XCTest

final class ToolV2Tests: XCTestCase {
    func testExecutionRequestValidatesIdentitySchemaSanitizationAndByteLimit() throws {
        let fixture = try ToolFixture()
        XCTAssertEqual(fixture.request.argumentValidation, .fullyValidated)
        XCTAssertEqual(fixture.request.maximumArgumentBytes, 256 * 1_024)
        XCTAssertThrowsError(
            try ToolExecutionRequest(
                proposedCall: ProposedToolCall(
                    invocationID: fixture.invocationID,
                    toolID: try AgentToolLogicalID(providerID: "other", name: "lookup"),
                    arguments: fixture.arguments
                ),
                descriptor: fixture.descriptor,
                sanitizedArguments: fixture.sanitized
            )
        )
        let invalidArguments = try CanonicalJSON(.object(["q": .integer(3)]))
        XCTAssertThrowsError(
            try ToolExecutionRequest(
                proposedCall: ProposedToolCall(
                    invocationID: fixture.invocationID,
                    toolID: fixture.descriptor.id.logicalID,
                    arguments: invalidArguments
                ),
                descriptor: fixture.descriptor,
                sanitizedArguments: fixture.sanitized
            )
        )
        XCTAssertThrowsError(
            try ToolExecutionRequest(
                proposedCall: fixture.call,
                descriptor: fixture.descriptor,
                sanitizedArguments: fixture.sanitized,
                maximumArgumentBytes: 1
            )
        )
        XCTAssertThrowsError(
            try ToolExecutionRequest(
                proposedCall: fixture.call,
                descriptor: fixture.descriptor,
                sanitizedArguments: fixture.sanitized,
                maximumArgumentBytes: UInt64(CanonicalJSON.maximumBytes + 1)
            )
        )
    }

    func testPartiallyEnforcedSchemaIsExplicitlyConservative() throws {
        let fixture = try ToolFixture(partialInputSchema: true)
        XCTAssertEqual(fixture.descriptor.inputSchema.enforcement, .partiallyEnforced)
        XCTAssertEqual(fixture.request.argumentValidation, .partiallyValidatedConservative)
    }

    func testPreparedInvocationBindsEveryDescriptorAndPlanField() throws {
        let fixture = try ToolFixture()
        XCTAssertEqual(fixture.prepared.externalOperation.invocationID, fixture.invocationID)
        XCTAssertEqual(fixture.prepared.externalOperation.plan.descriptorID, fixture.descriptor.id.description)

        let wrongTrust = try fixture.makePlan(trustRevision: "changed")
        XCTAssertThrowsError(
            try PreparedToolInvocation(
                request: fixture.request,
                context: fixture.preparationContext,
                plan: wrongTrust
            )
        )
        let tooLong = try fixture.makePlan(timeoutMilliseconds: 6_000)
        XCTAssertThrowsError(
            try PreparedToolInvocation(
                request: fixture.request,
                context: fixture.preparationContext,
                plan: tooLong
            )
        )
        let wrongDescriptor = try fixture.makePlan(descriptorID: "wrong")
        XCTAssertThrowsError(
            try PreparedToolInvocation(
                request: fixture.request,
                context: fixture.preparationContext,
                plan: wrongDescriptor
            )
        )
    }

    func testPreparedInvocationRoundTripsAndRejectsForgedFingerprint() throws {
        let fixture = try ToolFixture()
        let data = try JSONEncoder().encode(fixture.prepared)
        XCTAssertEqual(try JSONDecoder().decode(PreparedToolInvocation.self, from: data), fixture.prepared)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["fingerprint"] = String(repeating: "0", count: 64)
        let forged = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(PreparedToolInvocation.self, from: forged))

        var requestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.request)) as? [String: Any]
        )
        requestObject["maximumArgumentBytes"] = 1
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ToolExecutionRequest.self,
                from: JSONSerialization.data(withJSONObject: requestObject)
            )
        )
    }

    func testLocalAuthorizationProducesOpaqueToolExecutionContext() async throws {
        let fixture = try ToolFixture()
        let authorized = try await fixture.authorized()
        let wrapped = try AuthorizedToolInvocation(prepared: fixture.prepared, authorization: authorized)
        let context = try ToolExecutionContext(
            authorized: wrapped,
            deadline: AgentTimestamp(rawValue: 9_000),
            budgetReservationID: BudgetReservationID(),
            cancellation: NeverCancelled(),
            artifactWriter: RejectingArtifactWriter(),
            logger: RecordingLogger()
        )
        XCTAssertEqual(context.runID, fixture.runID)
        XCTAssertEqual(context.stepID, fixture.stepID)
        XCTAssertEqual(context.invocationID, fixture.invocationID)
        XCTAssertThrowsError(
            try ToolExecutionContext(
                authorized: wrapped,
                deadline: AgentTimestamp(rawValue: 0),
                budgetReservationID: BudgetReservationID(),
                cancellation: NeverCancelled(),
                artifactWriter: RejectingArtifactWriter(),
                logger: RecordingLogger()
            )
        )
    }

    func testExecutorConsumesProgressAndExactlyOneTerminalResult() async throws {
        let fixture = try ToolFixture(supportsProgress: true)
        let prepared = try await fixture.authorizedToolAndContext()
        let result = try ToolResultCollection([
            .text(try ToolTextResult("done")),
            .structured(try ToolStructuredResult(CanonicalJSON(.object(["value": .integer(1)])))),
        ])
        let events: [ToolExecutionEvent] = [
            .progress(try ToolExecutionProgress(completedUnits: 1, totalUnits: 2)),
            .completed(result),
        ]
        let sink = RecordingSink()
        let tool = ScriptedTool(
            descriptor: fixture.descriptor,
            prepared: fixture.prepared,
            events: events
        )
        let outcome = try await ToolExecutor().execute(
            tool: tool,
            authorized: prepared.authorized,
            context: prepared.context,
            eventSink: sink
        )
        XCTAssertEqual(outcome, .completed(result))
        let received = await sink.events()
        XCTAssertEqual(received, events)
    }

    func testExecutorRejectsEveryMalformedStreamShape() async throws {
        let fixture = try ToolFixture(supportsProgress: false)
        let values = try await fixture.authorizedToolAndContext()
        let completed = ToolExecutionEvent.completed(
            try ToolResultCollection([.text(try ToolTextResult("done"))])
        )
        let progress = ToolExecutionEvent.progress(
            try ToolExecutionProgress(completedUnits: 1)
        )
        let cases: [([ToolExecutionEvent], Bool, ToolV2ContractError)] = [
            ([progress, completed], false, .progressNotSupported),
            ([completed, progress], false, .eventAfterTerminal),
            ([], false, .missingTerminal),
            ([], true, .providerThrewBeforeTerminal),
            ([completed], true, .eventAfterTerminal),
        ]
        for (events, throwsAtEnd, expected) in cases {
            let tool = ScriptedTool(
                descriptor: fixture.descriptor,
                prepared: fixture.prepared,
                events: events,
                throwsAtEnd: throwsAtEnd
            )
            await XCTAssertThrowsToolError(expected) {
                _ = try await ToolExecutor().execute(
                    tool: tool,
                    authorized: values.authorized,
                    context: values.context
                )
            }
        }
    }

    func testExecutorEnforcesStructuredOutputSchema() async throws {
        let fixture = try ToolFixture()
        let values = try await fixture.authorizedToolAndContext()
        let invalid = try ToolResultCollection([
            .structured(try ToolStructuredResult(CanonicalJSON(.object(["value": .string("bad")])))),
        ])
        let tool = ScriptedTool(
            descriptor: fixture.descriptor,
            prepared: fixture.prepared,
            events: [.completed(invalid)]
        )
        await XCTAssertThrowsToolError(.invalidOutputSchema) {
            _ = try await ToolExecutor().execute(
                tool: tool,
                authorized: values.authorized,
                context: values.context
            )
        }
    }

    func testExecutorDoesNotPublishTerminalBeforeProviderClosesCleanly() async throws {
        let fixture = try ToolFixture()
        let values = try await fixture.authorizedToolAndContext()
        let completed = ToolExecutionEvent.completed(
            try ToolResultCollection([.text(try ToolTextResult("premature"))])
        )
        let sink = RecordingSink()
        let tool = ScriptedTool(
            descriptor: fixture.descriptor,
            prepared: fixture.prepared,
            events: [completed],
            throwsAtEnd: true
        )
        await XCTAssertThrowsToolError(.eventAfterTerminal) {
            _ = try await ToolExecutor().execute(
                tool: tool,
                authorized: values.authorized,
                context: values.context,
                eventSink: sink
            )
        }
        let published = await sink.events()
        XCTAssertEqual(published, [])
    }

    func testExecutorPreservesKnownAndUncertainTypedFailures() async throws {
        let fixture = try ToolFixture()
        let values = try await fixture.authorizedToolAndContext()
        let known = try failure(uncertain: false)
        let knownTool = ScriptedTool(
            descriptor: fixture.descriptor,
            prepared: fixture.prepared,
            events: [.failed(known)]
        )
        let knownOutcome = try await ToolExecutor().execute(
            tool: knownTool,
            authorized: values.authorized,
            context: values.context
        )
        XCTAssertEqual(knownOutcome, .failed(known))
        let uncertain = try failure(uncertain: true)
        let uncertainTool = ScriptedTool(
            descriptor: fixture.descriptor,
            prepared: fixture.prepared,
            events: [.failed(uncertain)]
        )
        let uncertainOutcome = try await ToolExecutor().execute(
            tool: uncertainTool,
            authorized: values.authorized,
            context: values.context
        )
        XCTAssertEqual(uncertainOutcome, .uncertain(uncertain))
    }

    func testExecutorRejectsADifferentDescriptor() async throws {
        let fixture = try ToolFixture()
        let values = try await fixture.authorizedToolAndContext()
        let other = try ToolFixture(name: "other")
        let tool = ScriptedTool(
            descriptor: other.descriptor,
            prepared: other.prepared,
            events: []
        )
        await XCTAssertThrowsToolError(.executingWrongDescriptor) {
            _ = try await ToolExecutor().execute(
                tool: tool,
                authorized: values.authorized,
                context: values.context
            )
        }
    }

    private func failure(uncertain: Bool) throws -> AgentFailure {
        try AgentFailure(
            code: uncertain ? "tool.uncertain" : "tool.failed",
            classification: uncertain ? .potentiallySideEffecting : .permanent,
            safeMessage: "Tool failed",
            retryAdvice: .never,
            externalEffect: uncertain ? .uncertain : .confirmedNone,
            requiredUserAction: uncertain ? .reconcile : .none,
            redaction: RedactionMetadata(classification: .internalMetadata, policyVersion: 1)
        )
    }
}

final class ToolBatchValidatorTests: XCTestCase {
    func testBatchValidationIsOrderedAndFingerprintsExactDescriptorArgumentsAndEffects() throws {
        let first = try ToolFixture(name: "first", query: "one")
        let second = try ToolFixture(name: "second", query: "two", runOffset: 100)
        let batch = try ToolBatchValidator().validate(
            proposedCalls: [first.call, second.call],
            advertisedDescriptors: [second.descriptor, first.descriptor],
            maximumCalls: 3
        )
        XCTAssertEqual(batch.map(\.proposedCall.invocationID), [first.invocationID, second.invocationID])
        XCTAssertEqual(batch.map(\.descriptor.id), [first.descriptor.id, second.descriptor.id])
        XCTAssertEqual(Set(batch.map(\.executionFingerprint)).count, 2)
    }

    func testBatchRejectsAllUnsafeAdmissionShapesBeforeExecution() throws {
        let first = try ToolFixture(name: "first", query: "same")
        let duplicate = try ToolFixture(
            name: "first",
            query: "same",
            runOffset: 100,
            descriptor: first.descriptor
        )
        let validator = ToolBatchValidator()
        XCTAssertThrowsError(
            try validator.validate(proposedCalls: [], advertisedDescriptors: [], maximumCalls: 1)
        )
        XCTAssertThrowsError(
            try validator.validate(
                proposedCalls: [first.call],
                advertisedDescriptors: [first.descriptor],
                maximumCalls: 0
            )
        )
        XCTAssertThrowsError(
            try validator.validate(
                proposedCalls: [first.call, first.call],
                advertisedDescriptors: [first.descriptor],
                maximumCalls: 2
            )
        )
        XCTAssertThrowsError(
            try validator.validate(
                proposedCalls: [first.call, duplicate.call],
                advertisedDescriptors: [first.descriptor],
                maximumCalls: 2
            )
        )
        XCTAssertThrowsError(
            try validator.validate(
                proposedCalls: [first.call],
                advertisedDescriptors: [],
                maximumCalls: 1
            )
        )
        XCTAssertThrowsError(
            try validator.validate(
                proposedCalls: [first.call],
                advertisedDescriptors: [first.descriptor, first.descriptor],
                maximumCalls: 1
            )
        )
        let valid = try validator.validate(
            proposedCalls: [first.call],
            advertisedDescriptors: [first.descriptor],
            maximumCalls: 1
        )
        XCTAssertThrowsError(
            try validator.validate(
                proposedCalls: [first.call],
                advertisedDescriptors: [first.descriptor],
                maximumCalls: 1,
                previouslyExecutedFingerprints: [valid[0].executionFingerprint]
            )
        )
    }

    func testBatchRejectsSchemaInvalidArguments() throws {
        let fixture = try ToolFixture()
        let invalid = ProposedToolCall(
            invocationID: ToolInvocationID(),
            toolID: fixture.descriptor.id.logicalID,
            arguments: try CanonicalJSON(.object(["q": .integer(1)]))
        )
        XCTAssertThrowsError(
            try ToolBatchValidator().validate(
                proposedCalls: [invalid],
                advertisedDescriptors: [fixture.descriptor],
                maximumCalls: 1
            )
        )
        XCTAssertThrowsError(
            try ToolBatchValidator().validate(
                proposedCalls: [fixture.call],
                advertisedDescriptors: [fixture.descriptor],
                maximumCalls: 1,
                maximumArgumentBytes: 1
            )
        )
        XCTAssertThrowsError(
            try ToolBatchValidator().validate(
                proposedCalls: [fixture.call],
                advertisedDescriptors: [fixture.descriptor],
                maximumCalls: 1,
                maximumArgumentBytes: UInt64(CanonicalJSON.maximumBytes + 1)
            )
        )
    }
}

private struct ToolFixture {
    let runID: AgentRunID
    let conversationID: ConversationID
    let stepID: AgentStepID
    let invocationID: ToolInvocationID
    let descriptor: AgentToolDescriptor
    let arguments: CanonicalJSON
    let sanitized: SanitizedCanonicalJSON
    let call: ProposedToolCall
    let request: ToolExecutionRequest
    let ceiling: RunCapabilityCeiling
    let grant: StepCapabilityGrant
    let trustedAuthority: TrustedRunAuthority
    let preparationContext: ToolPreparationContext
    let plan: ExternalOperationPlan
    let prepared: PreparedToolInvocation

    init(
        name: String = "lookup",
        query: String = "example",
        runOffset: Int = 0,
        descriptor suppliedDescriptor: AgentToolDescriptor? = nil,
        partialInputSchema: Bool = false,
        supportsProgress: Bool = false
    ) throws {
        func uuid(_ value: Int) -> UUID {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value + runOffset))!
        }
        runID = AgentRunID(rawValue: uuid(1))
        conversationID = ConversationID(rawValue: uuid(2))
        stepID = AgentStepID(rawValue: uuid(3))
        invocationID = ToolInvocationID(rawValue: uuid(4))
        var inputKeywords: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(["q": .object(["type": .string("string")])]),
            "required": .array([.string("q")]),
            "additionalProperties": .bool(false),
        ]
        if partialInputSchema { inputKeywords["x-remote-annotation"] = .string("preserved") }
        let input = try JSONSchemaDocument(root: .object(inputKeywords))
        let output = try JSONSchemaDocument(
            root: .object([
                "type": .string("object"),
                "properties": .object(["value": .object(["type": .string("integer")])]),
                "required": .array([.string("value")]),
                "additionalProperties": .bool(false),
            ])
        )
        let logicalID = try AgentToolLogicalID(providerID: "builtin", name: name)
        let madeDescriptor = try AgentToolDescriptor(
            id: AgentToolDescriptorID(
                logicalID: logicalID,
                version: SemanticVersion("1.0.0")!,
                schemaDigest: input.digest,
                trustRevision: "local-1"
            ),
            title: name,
            summary: "Look up a local value",
            inputSchema: input,
            outputSchema: output,
            effects: [AgentEffect.localPure],
            requiredCapabilities: AgentCapabilitySet([]),
            timeoutPolicy: ToolTimeoutPolicy(maximumMilliseconds: 5_000),
            retryPolicy: .never,
            idempotency: .pureRead,
            supportsProgress: supportsProgress,
            supportsCancellation: true
        )
        descriptor = suppliedDescriptor ?? madeDescriptor
        arguments = try CanonicalJSON(.object(["q": .string(query)]))
        sanitized = try toolTestSanitizationAttestor.attest(
            value: arguments,
            redaction: RedactionMetadata(classification: .sensitive, policyVersion: 1)
        )
        call = ProposedToolCall(
            invocationID: invocationID,
            toolID: descriptor.id.logicalID,
            arguments: arguments
        )
        request = try ToolExecutionRequest(
            proposedCall: call,
            descriptor: descriptor,
            sanitizedArguments: sanitized
        )
        ceiling = RunCapabilityCeiling(authority: .empty)
        grant = try StepCapabilityGrant(runCeiling: ceiling, authority: .empty)
        trustedAuthority = try TrustedRunAuthority(
            runID: runID,
            ceiling: ceiling,
            policyRevision: 1
        )
        preparationContext = ToolPreparationContext(
            requestID: AgentRequestID(rawValue: uuid(5)),
            runID: runID,
            conversationID: conversationID,
            stepID: stepID,
            capabilityGrant: grant
        )
        plan = try ExternalOperationPlan(
            kind: .localPure,
            subjectID: descriptor.id.logicalID.description,
            canonicalArguments: sanitized,
            payloadDigest: sanitized.fingerprint,
            effects: descriptor.effects,
            requiredCapabilities: descriptor.requiredCapabilities,
            maximumRequestBytes: UInt64(arguments.data.count),
            maximumResponseBytes: 2 * 1_024 * 1_024,
            timeoutMilliseconds: descriptor.timeoutPolicy.maximumMilliseconds,
            retryPolicy: descriptor.retryPolicy,
            idempotency: descriptor.idempotency,
            userPreview: "",
            descriptorID: descriptor.id.description,
            schemaDigest: descriptor.id.schemaDigest,
            trustRevision: descriptor.id.trustRevision
        )
        prepared = try PreparedToolInvocation(
            request: request,
            context: preparationContext,
            plan: plan
        )
    }

    func makePlan(
        timeoutMilliseconds: UInt64? = nil,
        descriptorID: String? = nil,
        trustRevision: String? = nil
    ) throws -> ExternalOperationPlan {
        try ExternalOperationPlan(
            kind: .localPure,
            subjectID: descriptor.id.logicalID.description,
            canonicalArguments: sanitized,
            payloadDigest: sanitized.fingerprint,
            effects: descriptor.effects,
            requiredCapabilities: descriptor.requiredCapabilities,
            maximumRequestBytes: UInt64(arguments.data.count),
            maximumResponseBytes: 2 * 1_024 * 1_024,
            timeoutMilliseconds: timeoutMilliseconds ?? descriptor.timeoutPolicy.maximumMilliseconds,
            retryPolicy: descriptor.retryPolicy,
            idempotency: descriptor.idempotency,
            userPreview: "",
            descriptorID: descriptorID ?? descriptor.id.description,
            schemaDigest: descriptor.id.schemaDigest,
            trustRevision: trustRevision ?? descriptor.id.trustRevision
        )
    }

    func authorized() async throws -> AuthorizedExternalOperationRequest {
        try await DefaultApprovalPolicyEngine(
            policyVersion: 1,
            sanitizationValidator: toolTestSanitizationAttestor
        ).bindLocalPolicy(
            prepared: prepared.externalOperation,
            approvalID: ApprovalID(),
            trustedRunAuthority: trustedAuthority,
            at: AgentTimestamp(rawValue: 1_000)
        )
    }

    func authorizedToolAndContext() async throws -> (
        authorized: AuthorizedToolInvocation,
        context: ToolExecutionContext
    ) {
        let authorization = try await authorized()
        let value = try AuthorizedToolInvocation(
            prepared: prepared,
            authorization: authorization
        )
        return (
            value,
            try ToolExecutionContext(
                authorized: value,
                deadline: AgentTimestamp(rawValue: 9_000),
                budgetReservationID: BudgetReservationID(),
                cancellation: NeverCancelled(),
                artifactWriter: RejectingArtifactWriter(),
                logger: RecordingLogger()
            )
        )
    }
}

private let toolTestSanitizationAttestor = try! LocalSanitizationAttestor(
    key: Data(repeating: 0x5c, count: 32),
    policyRevision: 1
)

private struct ScriptedTool: ToolV2 {
    let descriptor: AgentToolDescriptor
    let prepared: PreparedToolInvocation
    let events: [ToolExecutionEvent]
    var throwsAtEnd = false

    func prepare(
        request: ToolExecutionRequest,
        context: ToolPreparationContext
    ) async throws -> PreparedToolInvocation {
        guard request == prepared.request,
              context.runID == prepared.externalOperation.runID,
              context.stepID == prepared.externalOperation.stepID
        else { throw ToolV2ContractError.preparedPlanMismatch }
        return prepared
    }

    func execute(
        prepared: AuthorizedToolInvocation,
        context: ToolExecutionContext
    ) -> AsyncThrowingStream<ToolExecutionEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            if throwsAtEnd {
                continuation.finish(throwing: ScriptedFailure())
            } else {
                continuation.finish()
            }
        }
    }
}

private struct ScriptedFailure: Error {}

private struct NeverCancelled: ToolCancellationChecking {
    func isCancelled() async -> Bool { false }
}

private struct RejectingArtifactWriter: ToolArtifactWriting {
    func commit(
        data: Data,
        mimeType: String,
        semanticType: String?,
        retention: ArtifactRetentionPolicy,
        sensitivity: RedactionClassification
    ) async throws -> ArtifactReference {
        throw ScriptedFailure()
    }
}

private actor RecordingLogger: ToolRedactedLogging {
    private var records: [String] = []
    func record(code: String, metadata: [String: String]) { records.append(code) }
}

private actor RecordingSink: ToolExecutionEventSink {
    private var received: [ToolExecutionEvent] = []
    func receive(_ event: ToolExecutionEvent) { received.append(event) }
    func events() -> [ToolExecutionEvent] { received }
}

private func XCTAssertThrowsToolError(
    _ expected: ToolV2ContractError,
    expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected ToolV2ContractError", file: file, line: line)
    } catch let error as ToolV2ContractError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}

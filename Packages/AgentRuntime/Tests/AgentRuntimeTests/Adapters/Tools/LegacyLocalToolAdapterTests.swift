// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
@_spi(AgentRuntime) @testable import AgentRuntime
import Foundation
import LLMCore
import XCTest

final class LegacyLocalToolAdapterTests: XCTestCase {
    func testDescriptorConvertsEveryLegacyParameterWithoutWideningEffects() throws {
        let tool = MutableLegacyTool(
            schema: ToolSchema(
                name: "local_fixture",
                description: "Exercise a local deterministic operation.",
                parameters: [
                    ToolParam(name: "text", kind: .string, description: "Text", required: true),
                    ToolParam(name: "count", kind: .number, description: "Count", required: false),
                    ToolParam(name: "flag", kind: .boolean, description: "Flag", required: true),
                ]
            ),
            response: "done"
        )
        let adapter = try LegacyLocalToolAdapter(
            tool: tool,
            providerID: "local",
            version: try XCTUnwrap(SemanticVersion("2.3.4")),
            trustRevision: "built-in-7",
            timeoutMilliseconds: 2_500,
            maximumResponseBytes: 512
        )

        XCTAssertEqual(adapter.descriptor.id.logicalID.providerID, "local")
        XCTAssertEqual(adapter.descriptor.id.logicalID.name, "local_fixture")
        XCTAssertEqual(adapter.descriptor.id.version.description, "2.3.4")
        XCTAssertEqual(adapter.descriptor.id.trustRevision, "built-in-7")
        XCTAssertEqual(adapter.descriptor.effects, [AgentEffect.localPure])
        XCTAssertTrue(adapter.descriptor.requiredCapabilities.values.isEmpty)
        XCTAssertEqual(adapter.descriptor.timeoutPolicy.maximumMilliseconds, 2_500)
        XCTAssertEqual(adapter.descriptor.retryPolicy, .never)
        XCTAssertEqual(adapter.descriptor.idempotency, .pureRead)
        XCTAssertFalse(adapter.descriptor.supportsProgress)
        XCTAssertTrue(adapter.descriptor.supportsCancellation)
        XCTAssertEqual(adapter.descriptor.id.schemaDigest, adapter.descriptor.inputSchema.digest)

        let valid = JSONValue.object([
            "text": .string("hello"),
            "flag": .bool(true),
        ])
        let withOptionalNumber = JSONValue.object([
            "text": .string("hello"),
            "count": .number(2.5),
            "flag": .bool(false),
        ])
        XCTAssertTrue(try adapter.descriptor.inputSchema.validates(instance: valid))
        XCTAssertTrue(try adapter.descriptor.inputSchema.validates(instance: withOptionalNumber))
        XCTAssertFalse(
            try adapter.descriptor.inputSchema.validates(
                instance: .object(["text": .string("hello"), "flag": .string("true")])
            )
        )
        XCTAssertFalse(
            try adapter.descriptor.inputSchema.validates(
                instance: .object([
                    "text": .string("hello"),
                    "flag": .bool(true),
                    "extra": .string("not advertised"),
                ])
            )
        )
    }

    func testRejectsZeroResponseLimit() {
        XCTAssertThrowsError(
            try LegacyLocalToolAdapter(
                tool: MutableLegacyTool.fixture(),
                trustRevision: "built-in-1",
                maximumResponseBytes: 0
            )
        ) { error in
            XCTAssertEqual(error as? LegacyLocalToolAdapterError, .invalidResponseLimit)
        }
    }

    func testPrepareBindsExactDescriptorArgumentsAndFrozenSchema() async throws {
        let tool = MutableLegacyTool.fixture()
        let fixture = try LegacyAdapterFixture(tool: tool)
        let prepared = try await fixture.adapter.prepare(
            request: fixture.request,
            context: fixture.preparationContext
        )

        XCTAssertEqual(prepared.request, fixture.request)
        XCTAssertEqual(prepared.externalOperation.plan.kind, .localPure)
        XCTAssertEqual(
            prepared.externalOperation.plan.subjectID,
            fixture.adapter.descriptor.id.logicalID.description
        )
        XCTAssertEqual(prepared.externalOperation.plan.canonicalArguments, fixture.sanitized)
        XCTAssertEqual(prepared.externalOperation.plan.payloadDigest, fixture.sanitized.fingerprint)
        XCTAssertEqual(prepared.externalOperation.plan.maximumResponseBytes, 64 * 1_024)

        let other = try LegacyAdapterFixture(
            tool: MutableLegacyTool.fixture(name: "other_fixture"),
            offset: 20
        )
        await XCTAssertThrowsLegacyAdapterError(.descriptorMismatch) {
            _ = try await fixture.adapter.prepare(
                request: other.request,
                context: fixture.preparationContext
            )
        }

        tool.replaceSchema(
            ToolSchema(
                name: "local_fixture",
                description: "Changed after registration.",
                parameters: []
            )
        )
        await XCTAssertThrowsLegacyAdapterError(.descriptorMismatch) {
            _ = try await fixture.adapter.prepare(
                request: fixture.request,
                context: fixture.preparationContext
            )
        }
    }

    func testExecutorRunsExactCanonicalArgumentsOnceInsideAuthorizedBoundary() async throws {
        let recorder = LegacyToolRecorder()
        let tool = MutableLegacyTool.fixture(response: "42", recorder: recorder)
        let fixture = try LegacyAdapterFixture(tool: tool)
        let execution = try await fixture.execution()
        let sink = LegacyEventSink()

        let outcome = try await ToolExecutor().execute(
            tool: fixture.adapter,
            authorized: execution.authorized,
            context: execution.context,
            eventSink: sink
        )

        let expected = try ToolResultCollection([.text(try ToolTextResult("42"))])
        XCTAssertEqual(outcome, .completed(expected))
        let arguments = await recorder.arguments()
        XCTAssertEqual(arguments, [fixture.arguments.string])
        let events = await sink.events()
        XCTAssertEqual(events, [.completed(expected)])

        do {
            _ = try await ToolExecutor().execute(
                tool: fixture.adapter,
                authorized: execution.authorized,
                context: execution.context
            )
            XCTFail("The authorization boundary must be one-shot")
        } catch {
            XCTAssertEqual(
                error as? ToolV2ContractError,
                .providerThrewBeforeTerminal
            )
        }
        let finalArguments = await recorder.arguments()
        XCTAssertEqual(finalArguments, [fixture.arguments.string])
    }

    func testCancellationIsTypedAndNeverInvokesLegacyTool() async throws {
        let recorder = LegacyToolRecorder()
        let tool = MutableLegacyTool.fixture(response: "unused", recorder: recorder)
        let fixture = try LegacyAdapterFixture(tool: tool)
        let execution = try await fixture.execution(cancellation: AlwaysCancelledLegacyTool())

        let outcome = try await ToolExecutor().execute(
            tool: fixture.adapter,
            authorized: execution.authorized,
            context: execution.context
        )

        guard case .failed(let failure) = outcome else {
            return XCTFail("Expected a typed cancellation failure")
        }
        XCTAssertEqual(failure.code, "tool.cancelled")
        XCTAssertEqual(failure.classification, .cancelled)
        XCTAssertEqual(failure.externalEffect, .confirmedNone)
        let invocationCount = await recorder.count()
        XCTAssertEqual(invocationCount, 0)
    }

    func testResponseCeilingFailsClosedWithoutPublishingTerminalSuccess() async throws {
        let recorder = LegacyToolRecorder()
        let tool = MutableLegacyTool.fixture(response: "12345", recorder: recorder)
        let fixture = try LegacyAdapterFixture(
            tool: tool,
            maximumResponseBytes: 4
        )
        let execution = try await fixture.execution()
        let sink = LegacyEventSink()

        do {
            _ = try await ToolExecutor().execute(
                tool: fixture.adapter,
                authorized: execution.authorized,
                context: execution.context,
                eventSink: sink
            )
            XCTFail("A legacy result larger than its approved ceiling must fail")
        } catch {
            XCTAssertEqual(error as? ToolV2ContractError, .providerThrewBeforeTerminal)
        }
        let invocationCount = await recorder.count()
        XCTAssertEqual(invocationCount, 1)
        let events = await sink.events()
        XCTAssertTrue(events.isEmpty)
    }

    func testExecuteRejectsSchemaMutationBeforeCrossingBoundary() async throws {
        let recorder = LegacyToolRecorder()
        let tool = MutableLegacyTool.fixture(response: "unused", recorder: recorder)
        let fixture = try LegacyAdapterFixture(tool: tool)
        let execution = try await fixture.execution()
        tool.replaceSchema(
            ToolSchema(name: "local_fixture", description: "Mutated", parameters: [])
        )

        do {
            _ = try await ToolExecutor().execute(
                tool: fixture.adapter,
                authorized: execution.authorized,
                context: execution.context
            )
            XCTFail("A changed schema must invalidate the frozen descriptor")
        } catch {
            XCTAssertEqual(error as? ToolV2ContractError, .executingWrongDescriptor)
        }
        let invocationCount = await recorder.count()
        XCTAssertEqual(invocationCount, 0)
    }
}

private struct LegacyAdapterFixture {
    let adapter: LegacyLocalToolAdapter
    let runID: AgentRunID
    let arguments: CanonicalJSON
    let sanitized: SanitizedCanonicalJSON
    let request: ToolExecutionRequest
    let preparationContext: ToolPreparationContext
    let authority: TrustedRunAuthority
    let attestor: LocalSanitizationAttestor

    init(
        tool: MutableLegacyTool,
        maximumResponseBytes: UInt64 = 64 * 1_024,
        offset: Int = 0
    ) throws {
        func uuid(_ value: Int) -> UUID {
            UUID(uuidString: String(format: "10000000-0000-0000-0000-%012x", value + offset))!
        }
        adapter = try LegacyLocalToolAdapter(
            tool: tool,
            trustRevision: "built-in-1",
            maximumResponseBytes: maximumResponseBytes
        )
        runID = AgentRunID(rawValue: uuid(1))
        arguments = try CanonicalJSON(.object([
            "count": .number(2.5),
            "flag": .bool(true),
            "text": .string("hello"),
        ]))
        attestor = try LocalSanitizationAttestor(
            key: Data(repeating: UInt8(0x60 + offset), count: 32),
            policyRevision: 1
        )
        sanitized = try attestor.attest(
            value: arguments,
            redaction: RedactionMetadata(classification: .sensitive, policyVersion: 1)
        )
        let call = ProposedToolCall(
            invocationID: ToolInvocationID(rawValue: uuid(2)),
            toolID: adapter.descriptor.id.logicalID,
            arguments: arguments
        )
        request = try ToolExecutionRequest(
            proposedCall: call,
            descriptor: adapter.descriptor,
            sanitizedArguments: sanitized
        )
        let ceiling = RunCapabilityCeiling(authority: .empty)
        let grant = try StepCapabilityGrant(runCeiling: ceiling, authority: .empty)
        preparationContext = ToolPreparationContext(
            requestID: AgentRequestID(rawValue: uuid(3)),
            runID: runID,
            conversationID: ConversationID(rawValue: uuid(4)),
            stepID: AgentStepID(rawValue: uuid(5)),
            capabilityGrant: grant
        )
        authority = try TrustedRunAuthority(
            runID: runID,
            ceiling: ceiling,
            policyRevision: 1
        )
    }

    func execution(
        cancellation: any ToolCancellationChecking = NeverCancelledLegacyTool()
    ) async throws -> (authorized: AuthorizedToolInvocation, context: ToolExecutionContext) {
        let prepared = try await adapter.prepare(
            request: request,
            context: preparationContext
        )
        let engine = try DefaultApprovalPolicyEngine(
            policyVersion: 1,
            sanitizationValidator: attestor
        )
        let authorization = try await engine.bindLocalPolicy(
            prepared: prepared.externalOperation,
            approvalID: ApprovalID(),
            trustedRunAuthority: authority,
            at: AgentTimestamp(rawValue: 1_000)
        )
        let authorized = try AuthorizedToolInvocation(
            prepared: prepared,
            authorization: authorization
        )
        let context = try ToolExecutionContext(
            authorized: authorized,
            deadline: AgentTimestamp(rawValue: 9_000),
            attemptNumber: 1,
            budgetReservationID: BudgetReservationID(),
            cancellation: cancellation,
            artifactWriter: RejectingLegacyArtifactWriter(),
            logger: LegacyLogger(),
            authorizationClock: FixedAuthorizationClock(),
            authorizationPolicyValidator: engine,
            attemptLedger: TestAttemptLedger()
        )
        return (authorized, context)
    }
}

private final class MutableLegacyTool: LLMCore.Tool, @unchecked Sendable {
    private let lock = NSLock()
    private var storedSchema: ToolSchema
    private let response: String
    private let recorder: LegacyToolRecorder

    init(schema: ToolSchema, response: String, recorder: LegacyToolRecorder = LegacyToolRecorder()) {
        storedSchema = schema
        self.response = response
        self.recorder = recorder
    }

    var schema: ToolSchema {
        lock.withLock { storedSchema }
    }

    func replaceSchema(_ schema: ToolSchema) {
        lock.withLock { storedSchema = schema }
    }

    func execute(argumentsJSON: String) async -> String {
        await recorder.record(argumentsJSON)
        return response
    }

    static func fixture(
        name: String = "local_fixture",
        response: String = "done",
        recorder: LegacyToolRecorder = LegacyToolRecorder()
    ) -> MutableLegacyTool {
        MutableLegacyTool(
            schema: ToolSchema(
                name: name,
                description: "Exercise a local deterministic operation.",
                parameters: [
                    ToolParam(name: "text", kind: .string, description: "Text"),
                    ToolParam(name: "count", kind: .number, description: "Count", required: false),
                    ToolParam(name: "flag", kind: .boolean, description: "Flag"),
                ]
            ),
            response: response,
            recorder: recorder
        )
    }
}

private actor LegacyToolRecorder {
    private var values: [String] = []

    func record(_ arguments: String) { values.append(arguments) }
    func count() -> Int { values.count }
    func arguments() -> [String] { values }
}

private struct NeverCancelledLegacyTool: ToolCancellationChecking {
    func isCancelled() async -> Bool { false }
}

private struct AlwaysCancelledLegacyTool: ToolCancellationChecking {
    func isCancelled() async -> Bool { true }
}

private struct RejectingLegacyArtifactWriter: ToolArtifactWriting {
    func commit(
        data: Data,
        mimeType: String,
        semanticType: String?,
        retention: ArtifactRetentionPolicy,
        sensitivity: RedactionClassification
    ) async throws -> ArtifactReference {
        throw LegacyAdapterTestError.unexpectedArtifact
    }
}

private actor LegacyLogger: ToolRedactedLogging {
    func record(code: String, metadata: [String: String]) {}
}

private actor LegacyEventSink: ToolExecutionEventSink {
    private var recorded: [ToolExecutionEvent] = []

    func receive(_ event: ToolExecutionEvent) { recorded.append(event) }
    func events() -> [ToolExecutionEvent] { recorded }
}

private enum LegacyAdapterTestError: Error {
    case unexpectedArtifact
}

private func XCTAssertThrowsLegacyAdapterError(
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

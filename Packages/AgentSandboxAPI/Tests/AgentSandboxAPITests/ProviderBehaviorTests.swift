// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import AgentContracts
import AgentSandboxAPI

// TEST-ID: AHT-SANDBOX-001
// TEST-ID: AHT-SANDBOX-002
final class ProviderBehaviorTests: XCTestCase {
    func testStartIsIdempotentAndConflictingReuseFails() async throws {
        let fixture = try makeFixture()
        XCTAssertEqual(fixture.provider.descriptor, fixture.values.descriptor)
        let capabilities = try await fixture.provider.capabilities()
        XCTAssertEqual(capabilities, fixture.values.report)
        for invalidKey in ["", "   ", String(repeating: "x", count: 257), "bad\nkey"] {
            do {
                _ = try await fixture.provider.start(fixture.request, idempotencyKey: invalidKey)
                XCTFail("Expected invalid idempotency key")
            } catch {
                XCTAssertEqual(
                    error as? AgentSandboxAPIError,
                    .invalidValue("start idempotency key")
                )
            }
        }
        let first = try await fixture.provider.start(fixture.request, idempotencyKey: fixture.key)
        let duplicate = try await fixture.provider.start(fixture.request, idempotencyKey: fixture.key)
        XCTAssertEqual(first, duplicate)

        let differentRequest = try SandboxTestValues.request(
            negotiated: fixture.values.negotiated,
            requiredFeatures: [.artifactOutput]
        )
        do {
            _ = try await fixture.provider.start(differentRequest, idempotencyKey: fixture.key)
            XCTFail("Expected idempotency conflict")
        } catch {
            XCTAssertEqual(error as? AgentSandboxAPIError, .idempotencyConflict)
        }
        do {
            _ = try await fixture.provider.attach(
                to: SandboxTestValues.id(SandboxExecutionHandleIDDomain.self, 99)
            )
            XCTFail("Expected missing execution")
        } catch {
            XCTAssertEqual(error as? AgentSandboxAPIError, .executionNotFound)
        }
    }

    func testMultipleObserversReceiveIdenticalEventsAndTerminalResultIsStable() async throws {
        let fixture = try makeFixture()
        let id = try await fixture.provider.start(fixture.request, idempotencyKey: fixture.key)
        let handle = try await fixture.provider.attach(to: id)
        var first = handle.events(after: nil).makeAsyncIterator()
        var second = handle.events(after: nil).makeAsyncIterator()

        let firstAccepted = try await first.next()
        let secondAccepted = try await second.next()
        XCTAssertEqual(firstAccepted, secondAccepted)
        XCTAssertEqual(firstAccepted?.payload.sequence, 1)

        try await fixture.provider.begin(id)
        let firstStarted = try await first.next()
        let secondStarted = try await second.next()
        XCTAssertEqual(firstStarted, secondStarted)
        XCTAssertEqual(firstStarted?.payload.sequence, 2)

        let progress = try AgentExecutionProgress(
            phase: "sandbox.running",
            completedUnits: 1,
            totalUnits: 2
        )
        try await fixture.provider.emitProgress(progress, for: id)
        let firstProgress = try await first.next()
        let secondProgress = try await second.next()
        XCTAssertEqual(firstProgress, secondProgress)

        let output = try CanonicalJSON(.object(["answer": .string("ok")]))
        try await fixture.provider.complete(id, output: output)
        let firstTerminal = try await first.next()
        let secondTerminal = try await second.next()
        XCTAssertEqual(firstTerminal, secondTerminal)
        guard case .terminal(let eventResult)? = firstTerminal?.payload.event else {
            return XCTFail("Expected terminal event")
        }
        let result1 = try await handle.result()
        let result2 = try await handle.result()
        XCTAssertEqual(result1, result2)
        XCTAssertEqual(result1, eventResult)
        let finalStatus = try await handle.status()
        let firstEnd = try await first.next()
        let secondEnd = try await second.next()
        XCTAssertEqual(finalStatus, eventResult.terminalStatus)
        XCTAssertNil(firstEnd)
        XCTAssertNil(secondEnd)
    }

    func testDetachDoesNotCancelAndReattachReplaysAfterCursor() async throws {
        let fixture = try makeFixture()
        let id = try await fixture.provider.start(fixture.request, idempotencyKey: fixture.key)
        let handle = try await fixture.provider.attach(to: id)
        var observerTask: Task<Void, Never>? = Task {
            do {
                for try await _ in handle.events(after: nil) {
                    try Task.checkCancellation()
                }
            } catch {}
        }
        await waitForObserverCount(1, provider: fixture.provider, id: id)
        observerTask?.cancel()
        observerTask = nil
        await waitForObserverCount(0, provider: fixture.provider, id: id)
        let detachedStatus = try await handle.status()
        let detachedResult = try await handle.result()
        XCTAssertEqual(detachedStatus.state, .accepted)
        XCTAssertNil(detachedResult)

        try await fixture.provider.begin(id)
        let reattached = try await fixture.provider.attach(to: id)
        var fullReplay = reattached.events(after: nil).makeAsyncIterator()
        let acceptedValue = try await fullReplay.next()
        let startedValue = try await fullReplay.next()
        let accepted = try XCTUnwrap(acceptedValue)
        let started = try XCTUnwrap(startedValue)
        XCTAssertEqual(accepted.payload.sequence, 1)
        XCTAssertEqual(started.payload.sequence, 2)

        var afterCursor = reattached.events(after: try accepted.payload.cursor).makeAsyncIterator()
        let replayedStarted = try await afterCursor.next()
        XCTAssertEqual(replayedStarted, started)
        try await fixture.provider.complete(id)
        _ = try await fullReplay.next()
        _ = try await afterCursor.next()
        let terminalStatus = try await reattached.status()
        XCTAssertEqual(terminalStatus.state, .completed)
    }

    func testInvalidCursorFailsInsideStreamWithoutMutatingExecution() async throws {
        let fixture = try makeFixture()
        let id = try await fixture.provider.start(fixture.request, idempotencyKey: fixture.key)
        let handle = try await fixture.provider.attach(to: id)
        var initial = handle.events(after: nil).makeAsyncIterator()
        let firstValue = try await initial.next()
        let first = try XCTUnwrap(firstValue)
        let valid = try first.payload.cursor
        let cursor = try AgentEventCursor(
            executionHandleID: valid.executionHandleID,
            eventID: SandboxTestValues.id(AgentEventIDDomain.self, 88),
            sequence: valid.sequence,
            runStateVersion: valid.runStateVersion,
            runState: valid.runState,
            timestamp: valid.timestamp,
            cumulativeUsage: valid.cumulativeUsage,
            recordDigest: valid.recordDigest,
            isTerminal: valid.isTerminal
        )
        var iterator = handle.events(after: cursor).makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("Expected cursor rejection")
        } catch {
            XCTAssertEqual(error as? AgentSandboxAPIError, .invalidCursor)
        }
        let status = try await handle.status()
        XCTAssertEqual(status.state, .accepted)
    }

    func testCASIdempotentCommandsAndExplicitCancellation() async throws {
        let fixture = try makeFixture()
        let id = try await fixture.provider.start(fixture.request, idempotencyKey: fixture.key)
        let handle = try await fixture.provider.attach(to: id)
        try await fixture.provider.begin(id)
        let running = try await handle.status()

        let wrongTarget = try SandboxCommandEnvelope(
            payload: SandboxCommand(
                commandID: SandboxTestValues.id(SandboxCommandIDDomain.self, 79),
                handleID: SandboxTestValues.id(SandboxExecutionHandleIDDomain.self, 99),
                expectedStateVersion: running.stateVersion,
                action: .cancel,
                issuedAt: AgentTimestamp(rawValue: 1_999)
            )
        )
        do {
            _ = try await handle.send(wrongTarget)
            XCTFail("Expected command target binding failure")
        } catch {
            XCTAssertEqual(error as? AgentSandboxAPIError, .requestBindingMismatch)
        }

        let staleID = SandboxTestValues.id(SandboxCommandIDDomain.self, 80)
        let stale = try SandboxCommandEnvelope(
            payload: SandboxCommand(
                commandID: staleID,
                handleID: id,
                expectedStateVersion: running.stateVersion - 1,
                action: .cancel,
                issuedAt: AgentTimestamp(rawValue: 2_000)
            )
        )
        let staleReceipt = try await handle.send(stale)
        XCTAssertEqual(staleReceipt.disposition, .stale)
        XCTAssertEqual(staleReceipt.currentStatus, running)
        let duplicateStaleReceipt = try await handle.send(stale)
        XCTAssertEqual(duplicateStaleReceipt, staleReceipt)
        let alternateProtocol = try SemanticVersion(major: 1, minor: 0, patch: 1)
        let versionTamperedDuplicate = try SandboxCommandEnvelope(
            protocolVersion: alternateProtocol,
            payloadVersion: SandboxCommand.currentPayloadVersion,
            payload: stale.payload
        )
        do {
            _ = try await handle.send(versionTamperedDuplicate)
            XCTFail("Expected command protocol mismatch")
        } catch {
            XCTAssertEqual(error as? AgentSandboxAPIError, .incompatibleProtocol)
        }

        let conflicting = try SandboxCommandEnvelope(
            payload: SandboxCommand(
                commandID: staleID,
                handleID: id,
                expectedStateVersion: running.stateVersion,
                action: .cancel,
                issuedAt: AgentTimestamp(rawValue: 2_000)
            )
        )
        do {
            _ = try await handle.send(conflicting)
            XCTFail("Expected command identity conflict")
        } catch {
            XCTAssertEqual(error as? AgentSandboxAPIError, .idempotencyConflict)
        }

        let cancel = try SandboxCommandEnvelope(
            payload: SandboxCommand(
                commandID: SandboxTestValues.id(SandboxCommandIDDomain.self, 81),
                handleID: id,
                expectedStateVersion: running.stateVersion,
                action: .cancel,
                issuedAt: AgentTimestamp(rawValue: 2_001)
            )
        )
        let accepted = try await handle.send(cancel)
        XCTAssertEqual(accepted.disposition, .accepted)
        XCTAssertEqual(accepted.currentStatus.state, .cancellationRequested)
        let duplicateAccepted = try await handle.send(cancel)
        XCTAssertEqual(duplicateAccepted, accepted)

        let terminalStatus = try await handle.status()
        let terminalResultValue = try await handle.result()
        let terminalResult = try XCTUnwrap(terminalResultValue)
        XCTAssertEqual(terminalStatus.state, .cancelled)
        XCTAssertEqual(terminalResult.terminalStatus, terminalStatus)
        XCTAssertEqual(terminalStatus.failure?.classification, .cancelled)

        let afterTerminal = try SandboxCommandEnvelope(
            payload: SandboxCommand(
                commandID: SandboxTestValues.id(SandboxCommandIDDomain.self, 82),
                handleID: id,
                expectedStateVersion: terminalStatus.stateVersion,
                action: .cancel,
                issuedAt: AgentTimestamp(rawValue: 2_002)
            )
        )
        let rejected = try await handle.send(afterTerminal)
        XCTAssertEqual(rejected.disposition, .rejected)
        XCTAssertEqual(rejected.currentStatus, terminalStatus)
    }

    func testFailureProducesOneConsistentTerminalEventStatusAndResult() async throws {
        let fixture = try makeFixture()
        let id = try await fixture.provider.start(fixture.request, idempotencyKey: fixture.key)
        let handle = try await fixture.provider.attach(to: id)
        try await fixture.provider.begin(id)
        try await fixture.provider.fail(id, failure: SandboxTestValues.failure())

        let status = try await handle.status()
        let resultValue = try await handle.result()
        let result = try XCTUnwrap(resultValue)
        XCTAssertEqual(status.state, .failed)
        XCTAssertEqual(result.terminalStatus, status)
        var iterator = handle.events(after: nil).makeAsyncIterator()
        var events: [SandboxEventEnvelope] = []
        while let event = try await iterator.next() { events.append(event) }
        XCTAssertEqual(events.filter { $0.payload.status.state.isTerminal }.count, 1)
        try SandboxEventPageValidator.validate(events, after: nil)
        guard case .terminal(let eventResult) = events.last?.payload.event else {
            return XCTFail("Expected terminal result event")
        }
        XCTAssertEqual(eventResult, result)
    }

    private typealias Fixture = (
        provider: StrictFakeSandboxProvider,
        request: SandboxExecutionRequest,
        key: String,
        values: (
            descriptor: AgentSandboxProviderDescriptor,
            report: SandboxCapabilities,
            policy: RegisteredSandboxProviderPolicy,
            negotiated: NegotiatedSandboxCapabilities
        )
    )

    private func makeFixture() throws -> Fixture {
        let values = try SandboxTestValues.negotiated()
        let request = try SandboxTestValues.request(negotiated: values.negotiated)
        let key = SandboxStartIdempotencyKey(
            requestFingerprint: request.fingerprint,
            callerScope: SandboxTestValues.digest("d")
        ).description
        return (
            StrictFakeSandboxProvider(
                descriptor: values.descriptor,
                report: values.report,
                policy: values.policy
            ),
            request,
            key,
            values
        )
    }

    private func waitForObserverCount(
        _ expected: Int,
        provider: StrictFakeSandboxProvider,
        id: SandboxExecutionHandleID
    ) async {
        for _ in 0 ..< 1_000 {
            if await provider.observerCount(for: id) == expected { return }
            await Task.yield()
        }
        XCTFail("Observer count did not become \(expected)")
    }
}

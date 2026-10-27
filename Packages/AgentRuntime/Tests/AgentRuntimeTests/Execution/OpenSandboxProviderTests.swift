// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
import AgentSandboxAPI
@testable import AgentRuntime
import Foundation
import XCTest

// TEST-ID: AHT-SANDBOX-001
final class OpenSandboxProviderTests: XCTestCase, @unchecked Sendable {
    func testRealBrowserScreenshotAndSourceArchiveSurviveLogTailLimits() async throws {
        guard let path = ProcessInfo.processInfo.environment["MOBILELLM_LIVE_SANDBOX_CONFIG"] else {
            throw XCTSkip("Explicit local OpenSandbox configuration is required")
        }
        struct Configuration: Decodable { let endpoint: String; let apiKey: String }
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let connection = try await OpenSandboxHTTPClient.connect(endpoint: config.endpoint, apiKey: config.apiKey)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mobilellm-browser-test-" + UUID().uuidString)
        let provider = try OpenSandboxProvider(connection: connection, scopeID: UUID(), directory: directory, apiKey: { config.apiKey })
        addTeardownBlock { try await provider.closeWorkspace(); try? FileManager.default.removeItem(at: directory) }
        let html = """
        <!doctype html><title>Artifact contract</title><h1>Real browser</h1><canvas width="800" height="600"></canvas>
        <script>const c=document.querySelector('canvas').getContext('2d');let s=7;
        for(let y=0;y<600;y+=4)for(let x=0;x<800;x+=4){s=(s*1664525+1013904223)>>>0;c.fillStyle='rgb('+(s&255)+','+((s>>>8)&255)+','+((s>>>16)&255)+')';c.fillRect(x,y,4,4)}</script>
        """
        let write = try await request(provider, payload: .object(["action": .string("write"), "files": .array([.object([
            "path": .string("index.html"), "content": .string(html), "expectedSHA256": .null])])]))
        _ = try await execute(provider, request: write, key: "source")
        let start = try await request(provider, payload: .object(["action": .string("start"),
            "command": .string("python3 -m http.server 8011 --bind 0.0.0.0"), "port": .integer(8011)]))
        let started = try await execute(provider, request: start, key: "server")
        XCTAssertEqual(started.terminalStatus.state, .completed)
        let browser = try await request(provider, payload: .object(["action": .string("browser"), "port": .integer(8011),
            "script": .string("await expect(page.get_by_role('heading', name='Real browser')).to_be_visible()\nreturn {'checked': True}")]))
        let inspected = try await execute(provider, request: browser, key: "browser")
        let image = try object(inspected)
        guard case .string(let encoded)? = image["screenshotBase64"], let pixels = Data(base64Encoded: encoded) else {
            return XCTFail("No original screenshot: \(inspected.terminalStatus.failure?.safeMessage ?? "missing result")")
        }
        XCTAssertGreaterThan(pixels.count, 65_536)
        XCTAssertEqual(image["screenshotSHA256"], .string(StableDigest.sha256(pixels).rawValue))
        let export = try await request(provider, payload: .object(["action": .string("export")]))
        let archive = try object(try await execute(provider, request: export, key: "archive"))
        guard case .string(let data)? = archive["dataBase64"], let zip = Data(base64Encoded: data) else { return XCTFail("No archive") }
        XCTAssertEqual(Array(zip.prefix(2)), [0x50, 0x4b])
        XCTAssertEqual(archive["sha256"], .string(StableDigest.sha256(zip).rawValue))
        XCTAssertEqual(archive["sourceDigest"], image["sourceDigest"])
    }

    func testPersistedConnectionCannotBypassEndpointOrCapabilityValidation() throws {
        let value = try OpenSandboxConnection(id: UUID(), endpoint: URL(string: "https://execution.example/")!,
            image: "sha256:test", capabilities: [.workspaceFiles, .codeExecution])
        let encoder = JSONEncoder()
        let encoded = try encoder.encode(value)
        XCTAssertEqual(try JSONDecoder().decode(OpenSandboxConnection.self, from: encoded), value)
        var fields = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        fields["endpoint"] = "http://untrusted.example"
        XCTAssertThrowsError(try JSONDecoder().decode(OpenSandboxConnection.self, from: JSONSerialization.data(withJSONObject: fields)))
        XCTAssertThrowsError(try OpenSandboxConnection.validatedEndpoint("https://user:secret@execution.example"))
        let process = try XCTUnwrap(OpenSandboxTool.descriptors(connection: value).first { $0.id.logicalID.name == "sandbox_process" })
        XCTAssertFalse(try process.inputSchema.validates(instance: .object(["processID": .string("12345")])))
        XCTAssertTrue(try process.inputSchema.validates(instance: .object(["processID": .string(UUID().uuidString)])))
        fields["endpoint"] = "https://execution.example"
        fields["capabilities"] = ["publication"]
        XCTAssertThrowsError(try JSONDecoder().decode(OpenSandboxConnection.self, from: JSONSerialization.data(withJSONObject: fields)))
    }

    func testRealProviderPreservesExecutionAcrossReconnectAndCancelsChildren() async throws {
        guard let path = ProcessInfo.processInfo.environment["MOBILELLM_LIVE_SANDBOX_CONFIG"] else {
            throw XCTSkip("Explicit local OpenSandbox configuration is required")
        }
        struct Configuration: Decodable { let endpoint: String; let apiKey: String }
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let connection = try await OpenSandboxHTTPClient.connect(endpoint: config.endpoint, apiKey: config.apiKey)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mobilellm-provider-test-" + UUID().uuidString)
        let scope = UUID()
        let provider = try OpenSandboxProvider(connection: connection, scopeID: scope, directory: directory, apiKey: { config.apiKey })
        addTeardownBlock {
            try await provider.closeWorkspace()
            try? FileManager.default.removeItem(at: directory)
        }
        let write = try await request(provider, payload: .object(["action": .string("write"), "files": .array([.object([
            "path": .string("original.txt"), "content": .string("Original Unicode: 测试 😀"), "expectedSHA256": .null])])]))
        let written = try await execute(provider, request: write, key: "write-original")
        XCTAssertEqual(written.terminalStatus.state, .completed)

        let once = try await request(provider, payload: .object(["action": .string("exec"), "command": .string(
            "python3 -c \"from pathlib import Path; p=Path('once.txt'); p.write_text(str(int(p.read_text())+1) if p.exists() else '1')\""), "timeoutSeconds": .integer(20)]))
        let onceID = try await provider.start(once, idempotencyKey: "execute-once")
        let duplicate = try await provider.start(once, idempotencyKey: "execute-once")
        XCTAssertEqual(onceID, duplicate)
        let onceResult = try await collect(provider, id: onceID)
        XCTAssertEqual(onceResult.terminalStatus.state, .completed)
        let restored = try OpenSandboxProvider(connection: connection, scopeID: scope, directory: directory, apiKey: { config.apiKey })
        let restoredID = try await restored.start(once, idempotencyKey: "execute-once")
        let restoredResult = try await collect(restored, id: restoredID)
        XCTAssertEqual(restoredID, onceID)
        XCTAssertEqual(restoredResult, onceResult)
        let read = try await request(restored, payload: .object(["action": .string("read"), "path": .string("once.txt"), "offset": .integer(0)]))
        let readResult = try await execute(restored, request: read, key: "read-count")
        XCTAssertEqual(try object(readResult)["content"], .string("1"))
        do { _ = try await restored.start(read, idempotencyKey: "execute-once"); XCTFail("Identity cannot be reused with changed arguments") }
        catch AgentSandboxAPIError.idempotencyConflict {}

        let failing = try await request(restored, payload: .object(["action": .string("exec"),
            "command": .string("python3 -c \"print('CONTRACT_FAILURE'); raise SystemExit(7)\""), "timeoutSeconds": .integer(10)]))
        let failure = try await execute(restored, request: failing, key: "failing-command")
        XCTAssertEqual(failure.terminalStatus.state, .failed)
        XCTAssertNil(failure.structuredOutput)
        XCTAssertTrue(failure.terminalStatus.failure?.safeMessage.contains("CONTRACT_FAILURE") == true)
        XCTAssertNotNil(failure.terminalStatus.failure?.details["sandbox.source"])
        let pipe = try await request(restored, payload: .object(["action": .string("exec"),
            "command": .string("printf 'original failure\\n'; false | cat; printf 'MASKED_SUCCESS'"),
            "timeoutSeconds": .integer(10)]))
        let pipeResult = try await execute(restored, request: pipe, key: "pipeline-status")
        XCTAssertEqual(pipeResult.terminalStatus.state, .failed, "A logging pipeline must preserve the failing test's exit status")
        XCTAssertFalse(pipeResult.terminalStatus.failure?.safeMessage.contains("MASKED_SUCCESS") == true)

        let sleeping = try await request(restored, payload: .object(["action": .string("exec"),
            "command": .string("python3 -c \"import time; from pathlib import Path; time.sleep(4); Path('late.txt').write_text('unexpected')\""),
            "timeoutSeconds": .integer(10)]))
        let sleepingID = try await restored.start(sleeping, idempotencyKey: "cancel-child")
        let handle = try await restored.attach(to: sleepingID)
        var status = try await handle.status()
        for _ in 0..<100 where status.state == .accepted {
            try await Task.sleep(nanoseconds: 50_000_000); status = try await handle.status()
        }
        XCTAssertEqual(status.state, .running)
        let command = try SandboxCommand(commandID: SandboxCommandID(), handleID: sleepingID,
            expectedStateVersion: status.stateVersion, action: .cancel, issuedAt: AgentTimestamp(Date()))
        let receipt = try await handle.send(SandboxCommandEnvelope(payload: command))
        let repeatedReceipt = try await handle.send(SandboxCommandEnvelope(payload: command))
        XCTAssertEqual(receipt, repeatedReceipt)
        let cancelled = try await collect(restored, id: sleepingID)
        XCTAssertEqual(cancelled.terminalStatus.state, .cancelled)
        try await Task.sleep(nanoseconds: 4_500_000_000)
        let listing = try await request(restored, payload: .object(["action": .string("list"), "path": .string(".")]))
        let listed = try await execute(restored, request: listing, key: "check-no-late-write")
        XCTAssertFalse(try XCTUnwrap(listed.structuredOutput).string.contains("late.txt"), "Cancellation must stop the command's child, not just its observer")

        let exits = try await request(restored, payload: .object(["action": .string("start"),
            "command": .string("python3 -c 'pass'"), "port": .integer(8000)]))
        let exitsID = try await restored.start(exits, idempotencyKey: "not-a-service")
        let exited = try await collect(restored, id: exitsID)
        XCTAssertEqual(exited.terminalStatus.state, .failed)
        XCTAssertEqual(exited.terminalStatus.failure?.externalEffect, .confirmedApplied)
        XCTAssertNotNil(exited.terminalStatus.failure?.details["sandbox.source"])
        let stop = try await request(restored, payload: .object(["action": .string("stop"),
            "processID": .string(exitsID.description)]))
        let stopped = try await execute(restored, request: stop, key: "stop-exited-service")
        XCTAssertEqual(try object(stopped)["running"], .bool(false))

        let freshHandle = try await restored.attach(to: onceID)
        var events: [SandboxEventRecord] = []
        for try await event in freshHandle.events(after: nil) { events.append(event.payload) }
        XCTAssertEqual(events.last?.status.state, .completed)
        let cursor = try XCTUnwrap(events.first).cursor
        var replayed: [SandboxEventRecord] = []
        for try await event in freshHandle.events(after: cursor) { replayed.append(event.payload) }
        XCTAssertEqual(replayed, Array(events.dropFirst()))
        for path in try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent(scope.uuidString), includingPropertiesForKeys: nil) {
            XCTAssertFalse(try String(contentsOf: path, encoding: .utf8).contains(config.apiKey), "Execution records must not persist the API key")
        }
    }

    private func request(_ provider: OpenSandboxProvider, payload: JSONValue) async throws -> SandboxExecutionRequest {
        let requestID = AgentRequestID(), runID = AgentRunID(), stepID = AgentStepID()
        let grant = try StepCapabilityGrant(runCeiling: RunCapabilityCeiling(authority: provider.maximumAuthority), authority: provider.maximumAuthority)
        let requirement = try SandboxRequirement(minimumProtocolVersion: AgentContractVersion.currentProtocol,
            workspaceID: provider.workspaceID, authority: provider.maximumAuthority, budget: provider.maximumBudget,
            networkDestinations: provider.connection.networkDestinations)
        let negotiated = try await provider.negotiate()
        let sanitizer = try LocalSanitizationAttestor(key: Data(repeating: 1, count: 32), policyRevision: 1)
        let sanitized = try sanitizer.sanitize(CanonicalJSON(payload), referencedSecretIDs: [],
            redaction: RedactionMetadata(classification: .sensitive, policyVersion: 1))
        return try SandboxExecutionRequest(requestID: requestID, runID: runID, stepID: stepID,
            requirement: requirement, stepGrant: grant, parentBudget: provider.maximumBudget,
            negotiatedCapabilities: negotiated, requiredFeatures: [.codeExecution, .structuredOutput], sanitizedPayload: sanitized,
            authorization: SandboxAuthorizationReference(approvalID: ApprovalID(), requestID: requestID, runID: runID, stepID: stepID,
                sanitizedPayloadFingerprint: sanitized.fingerprint, externalPlanFingerprint: StableDigest.sha256(Data("contract-test".utf8)),
                executionConstraintDigest: requirement.fingerprint, negotiatedCapabilitiesFingerprint: negotiated.fingerprint))
    }
    private func execute(_ provider: OpenSandboxProvider, request: SandboxExecutionRequest, key: String) async throws -> SandboxExecutionResult {
        let id = try await provider.start(request, idempotencyKey: key)
        return try await collect(provider, id: id)
    }
    private func collect(_ provider: OpenSandboxProvider, id: SandboxExecutionHandleID) async throws -> SandboxExecutionResult {
        let handle = try await provider.attach(to: id)
        for _ in 0..<600 {
            if let result = try await handle.result() { return result }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw OpenSandboxError.unavailable
    }
    private func object(_ result: SandboxExecutionResult) throws -> [String: JSONValue] {
        guard case .object(let value) = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(result.structuredOutput).data) else {
            throw OpenSandboxError.invalidResponse
        }
        return value
    }
}

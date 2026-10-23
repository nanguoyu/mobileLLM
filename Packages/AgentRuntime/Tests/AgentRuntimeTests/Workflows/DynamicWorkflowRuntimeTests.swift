// SPDX-License-Identifier: MIT

import AgentContracts
@testable import AgentRuntime
import XCTest

// TEST-ID: AHT-DYNAMIC-001

final class DynamicWorkflowRuntimeTests: XCTestCase {
    func testWebEvidenceQueryFindsMiddleFieldsWithoutIncreasingExcerptBudget() throws {
        let text = String(repeating: "Unrelated introduction.\n", count: 100)
            + "| need_content | When false, content is empty; when true it may contain page content. |\n"
            + "| extra_snippets | Up to five additional excerpts, not full page text. |\n"
            + String(repeating: "Unrelated footer.\n", count: 100)
        let record = WorkflowWebObservation(invocationID: "read", toolID: try AgentToolLogicalID(providerID: "builtin", name: "fetch_webpage"),
            requestedURL: "https://example.edu/reference", status: "completed", text: text)
        let packet = try WorkflowWebEvidence.packet([("reader", record)], matching: "Compare `need_content` and `extra_snippets` fields")
        guard case .object(let root) = packet, case .array(let observations)? = root["observations"],
              case .object(let observation)? = observations.first,
              case .array(let excerpts)? = observation["matchingExcerpts"] else { return XCTFail("Missing matching excerpts") }
        let matches = excerpts.compactMap { if case .string(let text) = $0 { return text }; return nil }
        XCTAssertTrue(matches.contains { $0.contains("When false, content is empty") })
        XCTAssertTrue(matches.contains { $0.contains("Up to five additional excerpts") })
        XCTAssertTrue(matches.allSatisfy { text.contains($0) && $0.utf8.count <= 480 })
        let snippetBytes = matches.reduce(0) { $0 + $1.utf8.count } + 400 + 200
        XCTAssertLessThanOrEqual(snippetBytes, 1200 + 400 + 4 * 120)
        XCTAssertEqual(observation["excerptTruncated"], .bool(true))
        XCTAssertThrowsError(try WorkflowWebEvidence.packet([("reader", record)], matching: String(repeating: "x", count: 65_537)))
    }

    func testJavaScriptEvidenceQueryReachesReadOnlyHostWithoutSpawningAChild() async throws {
        let script = try analyze(wrapped("return await webEvidence('need_content');"))
        let host = WorkflowScriptHost(agent: { _ in XCTFail("Evidence queries do not spawn children"); return .stopped },
            queryWebEvidence: { query in
                XCTAssertEqual(query, "need_content")
                return .string("recorded middle excerpt")
            })
        let output = try await JavaScriptCoreWorkflowRuntime().execute(script, args: nil, limits: try limits(), requirement: .init(), host: host)
        XCTAssertEqual(try decode(output), .string("recorded middle excerpt"))
    }


    func testAgentPromptCanonicalizesOuterWhitespaceBeforeHostDispatch() async throws {
        let script = try analyze(wrapped("return await agent('  \\nfirst line\\n  indented data\\n\\t');"))
        let result = try await JavaScriptCoreWorkflowRuntime().execute(script, args: nil, limits: try limits(),
            requirement: .init(), host: WorkflowScriptHost(agent: { invocation in
                XCTAssertEqual(invocation.prompt, "first line\n  indented data")
                return .value(.string(invocation.prompt))
            }))
        XCTAssertEqual(try decode(result), .string("first line\n  indented data"))
    }

    func testBoundedUniqueCountsWholeCodesAndWebEvidenceIsAReadOnlyHostSnapshot() async throws {
        let value = try analyze(wrapped("""
        const packet = await webEvidence();
        const codes = unique(['GB','AT','GB','IT','AT','CH','IT']);
        return { codes: codes, countries: codes.length, url: packet.sources[0].url };
        """))
        let packet: JSONValue = .object(["sources": .array([.object(["url": .string("https://example.edu/group")])])])
        let host = WorkflowScriptHost(agent: { _ in XCTFail("Evidence reads must not spawn an agent"); return .stopped }, webEvidence: { packet })
        let output = try await JavaScriptCoreWorkflowRuntime().execute(value, args: nil, limits: try limits(), requirement: .init(), host: host)
        XCTAssertEqual(try decode(output), .object([
            "codes": .array([.string("GB"), .string("AT"), .string("IT"), .string("CH")]),
            "countries": .integer(4), "url": .string("https://example.edu/group")
        ]))
        for body in [
            "return unique([1,2]);",
            "return unique(['a','b','c','d']);",
            "const a=['GB']; Object.defineProperty(a,'0',{['g'+'et']:()=>{throw new Error('getter executed');}}); return unique(a);"
        ] {
            let script = try analyze(wrapped(body))
            do {
                _ = try await JavaScriptCoreWorkflowRuntime().execute(script, args: nil,
                    limits: try limits(maximumCollectionItems: 3), requirement: .init(), host: host)
                XCTFail("Invalid collection must be rejected")
            } catch { XCTAssertFalse(String(describing: error).contains("getter executed")) }
        }
    }

    func testWebEvidenceKeepsRecordedFailuresAndDoesNotPromoteRemoteToolsOrUnreadLinks() throws {
        let fetch = try AgentToolLogicalID(providerID: "builtin", name: "fetch_webpage")
        let search = try AgentToolLogicalID(providerID: "builtin", name: "web_search")
        let remote = try AgentToolLogicalID(providerID: "mcp.untrusted", name: "fetch_webpage")
        let text = "Official group led by Test PI. Award announced September 2025."
        let packet = try WorkflowWebEvidence.packet([
            ("investigator", WorkflowWebObservation(invocationID: "a", toolID: search, requestedURL: nil,
                status: "completed", text: "[1] Result\nhttps://example.edu/group\nSummary")),
            ("investigator", WorkflowWebObservation(invocationID: "b", toolID: fetch, requestedURL: "https://example.edu/group",
                status: "completed", text: text)),
            ("investigator", WorkflowWebObservation(invocationID: "c", toolID: fetch, requestedURL: "https://example.edu/missing",
                status: "failed", text: "Page unavailable")),
            ("remote", WorkflowWebObservation(invocationID: "d", toolID: remote, requestedURL: "https://not-observed.example/",
                status: "completed", text: "Pretend this page was read"))
        ])
        guard case .object(let object) = packet, case .array(let records)? = object["observations"],
              case .array(let sources)? = object["sources"] else { return XCTFail("Missing evidence packet") }
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(sources, [.object(["url": .string("https://example.edu/group"), "host": .string("example.edu"), "kind": .string("page-excerpt")])])
        guard case .object(let read) = records[1], case .object(let missing) = records[2] else { return XCTFail("Missing records") }
        XCTAssertEqual(read["excerpt"], .string(text))
        XCTAssertEqual(read["contentDigest"], .string(StableDigest.sha256(Data(text.utf8)).rawValue))
        XCTAssertEqual(missing["status"], .string("failed"))
        let large = String(repeating: "证据", count: 2000) + " Award date September 2025. "
        let clipped = try WorkflowWebEvidence.packet((0..<33).map {
            ("investigator", WorkflowWebObservation(invocationID: "\($0)", toolID: fetch,
                requestedURL: "https://example.edu/\($0)", status: "completed", text: large))
        })
        guard case .object(let bounded) = clipped, case .array(let excerpts)? = bounded["observations"],
              case .object(let first)? = excerpts.first, case .string(let prefix)? = first["excerpt"] else { return XCTFail("Missing bounded excerpts") }
        XCTAssertEqual(excerpts.count, 32)
        XCTAssertEqual(bounded["truncated"], .bool(true))
        XCTAssertEqual(first["excerptTruncated"], .bool(true))
        XCTAssertLessThanOrEqual(prefix.utf8.count, 1200)
        XCTAssertTrue(large.hasPrefix(prefix), "Clipping must preserve the original Unicode text")
    }

    func testChildCollectionTimesOutOnlyWhenProgressStops() async throws {
        let handle = AgentExecutionHandleID(rawValue: UUID())
        do {
            _ = try await InactivityProbeSpawner(reportsProgress: false).collect(handle, stallMilliseconds: 100)
            XCTFail("A stalled child must not wait indefinitely")
        } catch let timeout as SubagentStallTimeout { XCTAssertEqual(timeout.milliseconds, 100) }
        let result = try await InactivityProbeSpawner(reportsProgress: true).collect(handle, stallMilliseconds: 150)
        XCTAssertEqual(result.handleID, handle)
    }

    func testAnalyzerExtractsPureMetadataAndInstrumentsEveryBracedLoop() throws {
        let analysis = try analyze("""
        // Leading comments are allowed before the first statement.
        export const meta = {
          name: 'audit-routes',
          description: 'Audit routes',
          whenToUse: 'When routes change',
          phases: [{ title: 'Discover', detail: 'Find files', model: 'small' }],
        };
        let count = 0;
        for (const item of args.items) { log(item); }
        while (count < 0) { log(count); }
        do { log('once'); } while (false);
        return { ok: true };
        """)

        XCTAssertEqual(analysis.metadata.name, "audit-routes")
        XCTAssertEqual(analysis.metadata.phases.first?.title, "Discover")
        XCTAssertEqual(analysis.checkpointSites, 4) // entry + for + while + do
        XCTAssertFalse(analysis.executableSource.contains("export const meta"))
        XCTAssertEqual(
            analysis.instrumentedSource.components(separatedBy: "__workflowCheckpoint").count - 1,
            4
        )
    }

    func testAnalyzerRejectsDynamicMetadataForbiddenCapabilitiesAndUnsafeLoops() throws {
        XCTAssertThrowsError(try analyze("return 1"))
        XCTAssertThrowsError(try analyze("""
        export const meta = { name: getName(), description: 'bad' };
        return 1;
        """))

        for source in [
            "return fetch('https://example.com')",
            "return import('module')",
            "return Function('return 1')()",
            "return ({})['constructor']",
            "return Math.random()",
            "return this",
            "return __mllmStartAgent(1, 'x', '{}')",
        ] {
            XCTAssertThrowsError(try analyze(wrapped(source)), source)
        }
        XCTAssertThrowsError(try analyze(wrapped("while (true) log('x')")))

        // Capability names in ordinary strings and comments are data, not executable identifiers.
        XCTAssertNoThrow(try analyze(wrapped("// fetch eval\nreturn 'Function constructor fetch'")))
    }

    func testAnalyzerFailurePublishesItsSafeDiagnosticThroughLocalizedError() throws {
        let error = WorkflowScriptAnalysisError.malformedMetadata(
            "workflow name must be lowercase kebab-case"
        )
        XCTAssertEqual(
            error.localizedDescription,
            "Invalid workflow metadata: workflow name must be lowercase kebab-case"
        )
    }

    func testLiteralSchemaFieldNamesAreDataButExecutableBuiltinsStillFail() throws {
        XCTAssertNoThrow(try analyze(wrapped("""
        const schema = { type: 'object', properties: {
          test: { type: 'string', minLength: 1 },
          search: { type: 'number', minimum: -1 }
        }, required: ['test', 'search'], additionalProperties: false };
        return await agent('Analyze the incident', { schema: schema });
        """)))
        for body in [
            "const schema = {type: 'object', properties: {test: fetch('https://example.com')}}; return schema;",
            "const schema = {type: 'object', test() { return true; }}; return schema;",
            "const schema = {type: 'object', properties: {['test']: {type: 'string'}}}; return schema;",
            "const schema = {type: 'object', properties: {__proto__: {type: 'string'}}}; return schema;",
            "const schema = {type: 'object', required: ['test']}; return args.value.test('x');",
            "const schema = {type: 'object', required: ['test']}; return args.value['test']('x');",
        ] {
            XCTAssertThrowsError(try analyze(wrapped(body)), body)
        }
    }

    func testTemplateAnalysisIgnoresRawProseAndChecksEveryInterpolation() throws {
        XCTAssertNoThrow(try analyze(wrapped(
            "return `Synthesize with ${args.model} and review with ${args.device.name}.`;"
        )))

        for body in [
            "return `unsafe ${fetch('https://example.com')}`;",
            "return `unsafe ${Object['pro' + 'totype']}`;",
            "return `hidden dispatch ${agent('not-visible')}`;",
        ] {
            XCTAssertThrowsError(try analyze(wrapped(body)), body)
        }
    }

    func testJavaScriptCoreRunsSequentialAgentArgsPhaseLogAndBudget() async throws {
        let recorder = WorkflowInvocationRecorder()
        let analysis = try analyze("""
        export const meta = { name: 'sequential', description: 'Sequential bridge' };
        phase('Research');
        log({ started: true });
        const answer = await agent('hello ' + args.name + ' ' + serialize({ tags: ['a', 'b'] }), { label: 'primary' });
        return { answer, total: budget.total, spent: budget.spent(), remaining: budget.remaining() };
        """)
        let arguments = try CanonicalJSON(.object(["name": .string("Dong")]))
        let host = WorkflowScriptHost(
            agent: { invocation in
                let prompt = invocation.prompt
                let options = invocation.options
                await recorder.record(prompt: prompt, options: options)
                return .value(.string(prompt + "!"))
            },
            phase: { value in Task { await recorder.record(phase: value) } },
            log: { value in Task { await recorder.record(log: value) } },
            budget: { WorkflowBudgetSnapshot(totalOutputTokens: 100, spentOutputTokens: 25) }
        )

        let result = try await JavaScriptCoreWorkflowRuntime().execute(
            analysis,
            args: arguments,
            limits: try limits(),
            requirement: .init(),
            host: host
        )
        let value = try decode(result)
        XCTAssertEqual(value, .object([
            "answer": .string("hello Dong {\"tags\":[\"a\",\"b\"]}!"),
            "total": .integer(100),
            "spent": .integer(25),
            "remaining": .integer(75),
        ]))
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.prompts, ["hello Dong {\"tags\":[\"a\",\"b\"]}"])
        XCTAssertEqual(snapshot.options.first?.label, "primary")
        XCTAssertEqual(snapshot.options.first?.phase, "Research")
        XCTAssertEqual(snapshot.phases, ["Research"])
        XCTAssertEqual(snapshot.logs, ["{\"started\":true}"])
    }

    func testParallelIsConcurrentBarrierOrderedAndUnavailableBecomesNull() async throws {
        let recorder = WorkflowInvocationRecorder(delays: ["slow": 120_000_000, "fast": 5_000_000])
        let analysis = try analyze(wrapped("""
        return await parallel([
          () => agent('slow'),
          () => agent('fast'),
          () => agent('missing'),
        ]);
        """))
        let host = WorkflowScriptHost(agent: { invocation in
            let prompt = invocation.prompt
            let options = invocation.options
            return try await recorder.execute(prompt: prompt, options: options)
        })

        let result = try await JavaScriptCoreWorkflowRuntime().execute(
            analysis,
            args: nil,
            limits: try limits(),
            requirement: .init(),
            host: host
        )
        XCTAssertEqual(try decode(result), .array([.string("slow"), .string("fast"), .null]))
        let snapshot = await recorder.snapshot()
        XCTAssertGreaterThanOrEqual(snapshot.maximumActive, 2)
    }

    func testPipelineLetsItemsAdvanceIndependentlyAndPreservesItemOrder() async throws {
        let recorder = WorkflowInvocationRecorder(delays: ["discover-a": 140_000_000, "discover-b": 5_000_000])
        let analysis = try analyze(wrapped("""
        return await pipeline(
          ['a', 'b'],
          item => agent(`discover-${item}`),
          (value, item) => agent(`verify-${item}`),
        );
        """))
        let host = WorkflowScriptHost(agent: { invocation in
            let prompt = invocation.prompt
            let options = invocation.options
            return try await recorder.execute(prompt: prompt, options: options)
        })

        let result = try await JavaScriptCoreWorkflowRuntime().execute(
            analysis,
            args: nil,
            limits: try limits(),
            requirement: .init(),
            host: host
        )
        XCTAssertEqual(try decode(result), .array([.string("verify-a"), .string("verify-b")]))
        let snapshot = await recorder.snapshot()
        let verifyB = try XCTUnwrap(snapshot.starts.firstIndex(of: "verify-b"))
        let verifyA = try XCTUnwrap(snapshot.starts.firstIndex(of: "verify-a"))
        XCTAssertLessThan(verifyB, verifyA)
    }

    func testAgentOptionsValidateSchemaAndRejectUnknownFieldsBeforeHostDispatch() async throws {
        let recorder = WorkflowInvocationRecorder()
        let valid = try analyze(wrapped("""
        return await agent('structured', {
          schema: { type: 'object', required: ['ok'], properties: { ok: { type: 'boolean' } }, additionalProperties: false },
          model: 'local-small', agentType: 'reviewer', isolation: 'sandbox', stallMs: 50, maxToolCalls: 0,
        });
        """))
        let host = WorkflowScriptHost(agent: { invocation in
            let prompt = invocation.prompt
            let options = invocation.options
            await recorder.record(prompt: prompt, options: options)
            return .value(.object(["ok": .bool(true)]))
        })
        _ = try await JavaScriptCoreWorkflowRuntime().execute(
            valid, args: nil, limits: try limits(), requirement: .init(), host: host
        )
        let validSnapshot = await recorder.snapshot()
        let options = try XCTUnwrap(validSnapshot.options.first)
        XCTAssertEqual(options.requestedModel, "local-small")
        XCTAssertEqual(options.requestedAgentType, "reviewer")
        XCTAssertTrue(options.requiresIsolatedWorkspace)
        XCTAssertEqual(options.stallMilliseconds, 50)
        XCTAssertEqual(options.maximumToolCalls, 0)
        XCTAssertNotNil(options.schema)

        for value in ["-1", "0.5", "1001", "true", "'3'"] {
            let invalid = try analyze(wrapped("return await agent('bad cap', {maxToolCalls: \(value)});"))
            do {
                _ = try await JavaScriptCoreWorkflowRuntime().execute(invalid, args: nil, limits: try limits(), requirement: .init(), host: host)
                XCTFail("Invalid cap reached the host: \(value)")
            } catch { }
        }
        let afterInvalidCaps = await recorder.snapshot()
        XCTAssertEqual(afterInvalidCaps.options.count, 1, "Bad numeric caps must fail before dispatch")
        let legacy = try WorkflowAgentOptionsV1()
        let capped = try WorkflowAgentOptionsV1(maximumToolCalls: 0)
        XCTAssertNotEqual(try legacy.outputIdentity(), try capped.outputIdentity())
        let encoded = try JSONEncoder().encode(capped)
        XCTAssertEqual(try JSONDecoder().decode(WorkflowAgentOptionsV1.self, from: encoded), capped)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        old.removeValue(forKey: "maximumToolCalls")
        let decodedLegacy = try JSONDecoder().decode(WorkflowAgentOptionsV1.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(try decodedLegacy.outputIdentity(), try legacy.outputIdentity())

        for invalid in [
            "return await agent('bad', { scema: {} });",
            "return await agent('bad', { tools: ['web'] });",
            "const options = { label: 'hidden' }; return await agent('bad', options);",
            "return await agent('bad', { ['label']: 'hidden' });",
            "return await agent('bad', { isolation: 'logical-realm' });",
            "return await agent('bad', { isolation: 'none' });",
        ] {
            XCTAssertThrowsError(try analyze(wrapped(invalid))) { error in
                guard case WorkflowScriptAnalysisError.unsupportedConstruct = error else {
                    return XCTFail("Expected agent option rejection, got \(error)")
                }
            }
        }
        let finalSnapshot = await recorder.snapshot()
        XCTAssertEqual(finalSnapshot.prompts, ["structured"])
    }

    func testStepCollectionAndRuntimeCapabilityLimitsFailClosed() async throws {
        let loop = try analyze(wrapped("let i = 0; while (true) { i += 1; }"))
        await XCTAssertThrowsErrorAsync(expected: WorkflowScriptRuntimeError.stepLimitExceeded) {
            _ = try await JavaScriptCoreWorkflowRuntime().execute(
                loop,
                args: nil,
                limits: try self.limits(maximumScriptSteps: 64),
                requirement: .init(),
                host: WorkflowScriptHost(agent: { _ in .stopped })
            )
        }

        let collection = try analyze(wrapped("return await parallel([() => 1, () => 2, () => 3]);"))
        await XCTAssertThrowsErrorAsync {
            _ = try await JavaScriptCoreWorkflowRuntime().execute(
                collection,
                args: nil,
                limits: try self.limits(maximumCollectionItems: 2),
                requirement: .init(),
                host: WorkflowScriptHost(agent: { _ in .stopped })
            )
        }

        await XCTAssertThrowsErrorAsync(expected: WorkflowScriptRuntimeError.unsupportedRequirement) {
            _ = try await JavaScriptCoreWorkflowRuntime().execute(
                collection,
                args: nil,
                limits: try self.limits(),
                requirement: .init(minimumIsolation: .hardenedSandbox),
                host: WorkflowScriptHost(agent: { _ in .stopped })
            )
        }
    }

    func testArgumentsAreDeepFrozenAndFinalValuesMustBeJSON() async throws {
        let frozen = try analyze(wrapped("""
        let rejected = false;
        try { args.profile.name = 'changed'; } catch (_) { rejected = true; }
        return { rejected, name: args.profile.name };
        """))
        let args = try CanonicalJSON(.object([
            "profile": .object(["name": .string("Dong")])
        ]))
        let result = try await JavaScriptCoreWorkflowRuntime().execute(
            frozen,
            args: args,
            limits: try limits(),
            requirement: .init(),
            host: WorkflowScriptHost(agent: { _ in .stopped })
        )
        XCTAssertEqual(try decode(result), .object(["rejected": .bool(true), "name": .string("Dong")]))

        let cyclic = try analyze(wrapped("const value = {}; value.self = value; return value;"))
        await XCTAssertThrowsErrorAsync {
            _ = try await JavaScriptCoreWorkflowRuntime().execute(
                cyclic,
                args: nil,
                limits: try self.limits(),
                requirement: .init(),
                host: WorkflowScriptHost(agent: { _ in .stopped })
            )
        }
    }

    func testBridgeIntrinsicsCannotBeReachedThroughComputedPropertyNames() throws {
        for body in [
            "Promise['pro' + 'totype'].then = () => 1; return 'escaped';",
            "Map['pro' + 'totype'].get = () => null; return 'escaped';",
            "JSON['string' + 'ify'] = () => 'null'; return 'escaped';",
        ] {
            XCTAssertThrowsError(try analyze(wrapped(body))) { error in
                guard case WorkflowScriptAnalysisError.forbiddenCapability = error else {
                    return XCTFail("Expected computed intrinsic access rejection, got \(error)")
                }
            }
        }
    }

    func testUserSourceCannotReferenceOrForgePrivateDriverBindings() async throws {
        for name in [
            "__settle", "__pending", "__finishedNative", "__startAgentNative",
            "__mllmFinished", "__mllmUserFunction", "__workflowCheckpoint",
        ] {
            XCTAssertThrowsError(try analyze(wrapped("return typeof \(name);")), name) { error in
                guard case WorkflowScriptAnalysisError.forbiddenCapability = error else {
                    return XCTFail("Expected private-binding rejection for \(name), got \(error)")
                }
            }
        }

        // Unprefixed lookalikes are not driver capabilities either. The separately compiled user
        // function has only the public ABI parameters in scope, so it cannot settle or finish early.
        let recorder = WorkflowInvocationRecorder()
        let forged = try analyze(wrapped("settle(1, true, 'forged'); return 'forged';"))
        await XCTAssertThrowsErrorAsync {
            _ = try await JavaScriptCoreWorkflowRuntime().execute(
                forged,
                args: nil,
                limits: try self.limits(),
                requirement: .init(),
                host: WorkflowScriptHost(agent: { invocation in
                    await recorder.record(prompt: invocation.prompt, options: invocation.options)
                    return .value(.null)
                })
            )
        }
        let snapshot = await recorder.snapshot()
        XCTAssertTrue(snapshot.prompts.isEmpty)
    }

    func testNonPreemptibleRegularExpressionsAndAmplifyingBuiltinsFailClosedInAnalysis() throws {
        for body in [
            "return /^(a+)+$/.test(args.input);",
            "return new RegExp('^(a+)+$').test(args.input);",
            "return 'x'.repeat(1000000000);",
            "return 'x'.padEnd(1000000000, 'x');",
            "return [1].fill(0, 0, 1000000000);",
            "return [args, args].join(',');",
            "return JSON.stringify(args);",
            "return JSON['stringify'](args);",
            "return JSON.parse(args.payload);",
            "return Array.from({ length: 1000000000 });",
            "return Object.assign({}, args, args);",
            "return String.fromCharCode(...args.codes);",
            "return ['x'].concat(args);",
            "return ({ toJSON: () => 'forged' });",
        ] {
            XCTAssertThrowsError(try analyze(wrapped(body)), body) { error in
                guard case WorkflowScriptAnalysisError.forbiddenCapability = error else {
                    return XCTFail("Expected synchronous builtin rejection, got \(error)")
                }
            }
        }
    }

    func testRejectsUnbracedWhileAfterUnrelatedBlock() throws {
        for body in ["if (true) {} while (true);", "{} while (true);", "do {} while (false); while (true);"] {
            XCTAssertThrowsError(try analyze(wrapped(body)))
        }
    }

    func testExpressionArrowsAndAsyncMethodsCannotSpinWithoutCheckpoints() async throws {
        for body in [
            "const spin = () => Promise.resolve().then(spin); return await spin();",
            "const obj = { async spin() { await 0; return obj.spin(); } }; return await obj.spin();",
            "const spin = () => spin(); return spin();",
            "while ((() => { while (true) {} })()) {}",
            "do {} while ((() => { while (true) {} })());",
        ] {
            let script = try analyze(wrapped(body))
            await XCTAssertThrowsErrorAsync(expected: WorkflowScriptRuntimeError.stepLimitExceeded) {
                _ = try await JavaScriptCoreWorkflowRuntime().execute(
                    script, args: nil, limits: try self.limits(maximumScriptSteps: 32),
                    requirement: .init(), host: WorkflowScriptHost(agent: { _ in .stopped })
                )
            }
        }
    }

    private func analyze(_ source: String) throws -> AnalyzedWorkflowScriptV1 {
        let script = try WorkflowScriptV1(scriptID: WorkflowScriptID(), version: 1, source: source)
        return try DynamicWorkflowScriptAnalyzer().analyze(script)
    }

    private func wrapped(_ body: String) -> String {
        "export const meta = { name: 'runtime-test', description: 'Runtime test' };\n" + body
    }

    private func limits(
        maximumCollectionItems: UInt32 = 32,
        maximumScriptSteps: UInt64 = 10_000
    ) throws -> WorkflowRunLimitsV1 {
        try WorkflowRunLimitsV1(
            maximumConcurrentAgents: 4,
            maximumAgentCalls: 64,
            maximumCollectionItems: maximumCollectionItems,
            maximumWallClockMilliseconds: 5_000,
            maximumScriptSteps: maximumScriptSteps,
            maximumLogLines: 100,
            maximumPhaseEntries: 100,
            maximumSerializedValueBytes: 1_048_576
        )
    }

    private func decode(_ value: CanonicalJSON) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: value.data)
    }
}

private actor WorkflowInvocationRecorder {
    struct Snapshot: Sendable {
        let prompts: [String]
        let starts: [String]
        let options: [WorkflowAgentOptionsV1]
        let phases: [String]
        let logs: [String]
        let maximumActive: Int
    }

    private let delays: [String: UInt64]
    private var prompts: [String] = []
    private var starts: [String] = []
    private var options: [WorkflowAgentOptionsV1] = []
    private var phases: [String] = []
    private var logs: [String] = []
    private var active = 0
    private var maximumActive = 0

    init(delays: [String: UInt64] = [:]) { self.delays = delays }

    func record(prompt: String, options: WorkflowAgentOptionsV1) {
        prompts.append(prompt)
        starts.append(prompt)
        self.options.append(options)
    }

    func record(phase: String) { phases.append(phase) }
    func record(log: String) { logs.append(log) }

    func execute(prompt: String, options: WorkflowAgentOptionsV1) async throws -> WorkflowAgentBridgeResult {
        prompts.append(prompt)
        starts.append(prompt)
        self.options.append(options)
        active += 1
        maximumActive = max(maximumActive, active)
        if let delay = delays[prompt] { try await Task.sleep(nanoseconds: delay) }
        active -= 1
        if prompt == "missing" { return .unavailable("not found") }
        return .value(.string(prompt))
    }

    func snapshot() -> Snapshot {
        Snapshot(
            prompts: prompts,
            starts: starts,
            options: options,
            phases: phases,
            logs: logs,
            maximumActive: maximumActive
        )
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    expected: WorkflowScriptRuntimeError? = nil,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> T
) async {
    do {
        _ = try await body()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        if let expected { XCTAssertEqual(error as? WorkflowScriptRuntimeError, expected, file: file, line: line) }
    }
}

private struct InactivityProbeSpawner: SubagentSpawning {
    let reportsProgress: Bool
    func spawn(_ request: SubagentSpawnRequest) async throws -> AgentExecutionHandleID {
        throw SubagentSpawnError.resultUnavailable
    }
    func collect(_ handle: AgentExecutionHandleID) async throws -> SubagentResult {
        try await collect(handle, onProgress: {})
    }
    func collect(_ handle: AgentExecutionHandleID,
                 onProgress: @escaping @Sendable () async -> Void) async throws -> SubagentResult {
        if !reportsProgress { try await Task.sleep(for: .seconds(30)) }
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(30))
            await onProgress()
        }
        return SubagentResult(runID: AgentRunID(rawValue: UUID()), handleID: handle, outcome: .cancelled)
    }
}

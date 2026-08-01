// SPDX-License-Identifier: MIT

import XCTest
@_spi(AgentRuntime) @testable import AgentContracts

final class ModelAndToolContractTests: XCTestCase {
    func testModelAuthorizationPayloadBindsFullArtifactsAndToolManifest() throws {
        let managed = TestValues.artifact(
            locator: try ArtifactLocator(kind: .managedRelativePath, value: "runs/input.txt")
        )
        let opaque = TestValues.artifact(
            locator: try ArtifactLocator(
                kind: .providerOpaque,
                value: "opaque-1",
                providerID: "artifact-provider"
            )
        )
        let schema = try inputSchema()
        let descriptor = try toolDescriptor(schema: schema)
        let first = try modelRequest(
            message: AgentModelMessage(
                role: .user,
                content: "Inspect this",
                isUntrustedData: false,
                artifacts: [managed]
            ),
            advertisedTools: [descriptor]
        )
        let changedLocator = try modelRequest(
            message: AgentModelMessage(
                role: .user,
                content: "Inspect this",
                isUntrustedData: false,
                artifacts: [opaque]
            ),
            advertisedTools: [descriptor]
        )
        XCTAssertNotEqual(try first.fingerprint(), try changedLocator.fingerprint())
        XCTAssertTrue(try first.authorizationPayload().string.contains("artifact-provider") == false)
        XCTAssertTrue(try changedLocator.authorizationPayload().string.contains("artifact-provider"))
        XCTAssertTrue(try first.authorizationPayload().string.contains("test-provider"))
    }

    func testPreparedModelRequestRejectsSameIdentityPromptReplacement() throws {
        let request = try modelRequest(
            message: AgentModelMessage(role: .user, content: "Original", isUntrustedData: false)
        )
        let external = try localPreparedOperation(for: request)
        XCTAssertNoThrow(try PreparedModelRequest(request: request, externalOperation: external))
        let replaced = try modelRequest(
            message: AgentModelMessage(role: .user, content: "Replacement", isUntrustedData: false),
            requestID: request.requestID,
            runID: request.runID,
            stepID: request.stepID
        )
        XCTAssertThrowsError(try PreparedModelRequest(request: replaced, externalOperation: external))
    }

    func testModelStreamHasOneActionAndMonotonicFinalUsage() throws {
        let call = try ProposedToolCall(
            invocationID: TestValues.id(ToolInvocationIDDomain.self, 101),
            toolID: AgentToolLogicalID(providerID: "test-provider", name: "lookup"),
            arguments: CanonicalJSON(.object(["query": .string("hello")]))
        )
        let interim = try usage(input: 10, output: 1, milliseconds: 2)
        let final = try usage(input: 10, output: 3, milliseconds: 4)
        let completion = try AgentModelCompletion(action: .callTools([call]), usage: final)
        XCTAssertNoThrow(
            try AgentModelEventStreamValidator.validate([
                .usage(interim), .toolCalls([call]), .completed(completion),
            ])
        )
        let regression = try AgentModelCompletion(
            action: .callTools([call]),
            usage: usage(input: 9, output: 3, milliseconds: 4)
        )
        XCTAssertThrowsError(
            try AgentModelEventStreamValidator.validate([
                .usage(interim), .toolCalls([call]), .completed(regression),
            ])
        )
        let answer = try AgentAnswer(text: "not the tool action")
        let conflicting = try AgentModelCompletion(action: .finalAnswer(answer), usage: final)
        XCTAssertThrowsError(
            try AgentModelEventStreamValidator.validate([
                .toolCalls([call]), .completed(conflicting),
            ])
        )
        XCTAssertThrowsError(
            try AgentModelEventStreamValidator.validate([
                .toolCalls([call]), .toolCalls([call]), .completed(completion),
            ])
        )
    }

    func testTerminalToolActionMustUseAdvertisedPinnedSchema() throws {
        let schema = try inputSchema()
        let descriptor = try toolDescriptor(schema: schema)
        let request = try modelRequest(
            message: AgentModelMessage(role: .user, content: "Look up", isUntrustedData: false),
            advertisedTools: [descriptor]
        )
        let validCall = ProposedToolCall(
            invocationID: TestValues.id(ToolInvocationIDDomain.self, 110),
            toolID: descriptor.id.logicalID,
            arguments: try CanonicalJSON(.object(["query": .string("hello")]))
        )
        let validCompletion = try AgentModelCompletion(
            action: .callTools([validCall]),
            usage: usage()
        )
        XCTAssertNoThrow(
            try validCompletion.validate(against: request, resolvedToolDescriptors: [descriptor])
        )

        let invalidCall = ProposedToolCall(
            invocationID: TestValues.id(ToolInvocationIDDomain.self, 111),
            toolID: descriptor.id.logicalID,
            arguments: try CanonicalJSON(.object(["query": .integer(42)]))
        )
        let invalidCompletion = try AgentModelCompletion(
            action: .callTools([invalidCall]),
            usage: usage()
        )
        XCTAssertThrowsError(
            try invalidCompletion.validate(against: request, resolvedToolDescriptors: [descriptor])
        )

        let otherCall = ProposedToolCall(
            invocationID: TestValues.id(ToolInvocationIDDomain.self, 112),
            toolID: try AgentToolLogicalID(providerID: "other-provider", name: "lookup"),
            arguments: try CanonicalJSON(.object(["query": .string("hello")]))
        )
        let unadvertised = try AgentModelCompletion(action: .callTools([otherCall]), usage: usage())
        XCTAssertThrowsError(
            try unadvertised.validate(against: request, resolvedToolDescriptors: [descriptor])
        )
    }

    func testFinalAnswerMustSatisfyRequestedOutput() throws {
        let schema = try JSONSchemaDocument(root: .object([
            "type": .string("object"),
            "properties": .object(["answer": .object(["type": .string("string")])]),
            "required": .array([.string("answer")]),
            "additionalProperties": .bool(false),
        ]))
        let request = try modelRequest(
            message: AgentModelMessage(role: .user, content: "JSON", isUntrustedData: false),
            output: .structured(schema)
        )
        let valid = try AgentModelCompletion(
            action: .finalAnswer(AgentAnswer(structuredOutput: .object(["answer": .string("yes")]))),
            usage: usage()
        )
        XCTAssertNoThrow(try valid.validate(against: request, resolvedToolDescriptors: []))
        let invalid = try AgentModelCompletion(
            action: .finalAnswer(AgentAnswer(structuredOutput: .object(["answer": .integer(1)]))),
            usage: usage()
        )
        XCTAssertThrowsError(try invalid.validate(against: request, resolvedToolDescriptors: []))
    }

    func testLogicalToolIDsAndDescriptorVersionsCannotCollide() throws {
        let first = try AgentToolLogicalID(providerID: "ab", name: "c")
        let second = try AgentToolLogicalID(providerID: "a", name: "bc")
        XCTAssertNotEqual(first.description, second.description)

        let schema = try inputSchema()
        let one = try toolDescriptor(schema: schema, version: SemanticVersion("1.0.0")!)
        let two = try toolDescriptor(schema: schema, version: SemanticVersion("2.0.0")!)
        XCTAssertThrowsError(
            try modelRequest(
                message: AgentModelMessage(role: .user, content: "x", isUntrustedData: false),
                advertisedTools: [one, two]
            )
        )
    }

    func testGenerationParametersAreBoundedRoundTrippableAndFullyFingerprintBound() throws {
        let baseline = try generationParameters()
        try assertContractRoundTrip(baseline)
        let request = try modelRequest(
            message: AgentModelMessage(role: .user, content: "Generate", isUntrustedData: false),
            generationParameters: baseline
        )
        try assertContractRoundTrip(request)
        let payload = try request.authorizationPayload().string
        XCTAssertTrue(payload.contains("maximumOutputTokens"))
        XCTAssertTrue(payload.contains("thinkingMode"))

        let variants = try [
            generationParameters(maximumOutputTokens: 65),
            generationParameters(maximumContextTokens: 129),
            generationParameters(temperature: 0.8),
            generationParameters(topP: 0.8),
            generationParameters(topK: 20),
            generationParameters(repetitionPenalty: 1.1),
            generationParameters(thinkingMode: .enabled),
            generationParameters(seed: 42),
        ]
        let baselineFingerprint = try request.fingerprint()
        var fingerprints: Set<StableDigest> = [baselineFingerprint]
        for variant in variants {
            let changed = try modelRequest(
                message: AgentModelMessage(role: .user, content: "Generate", isUntrustedData: false),
                generationParameters: variant
            )
            let fingerprint = try changed.fingerprint()
            XCTAssertNotEqual(fingerprint, baselineFingerprint)
            fingerprints.insert(fingerprint)
        }
        XCTAssertEqual(fingerprints.count, variants.count + 1)

        XCTAssertThrowsError(try generationParameters(maximumOutputTokens: 0))
        XCTAssertThrowsError(try generationParameters(maximumOutputTokens: 129))
        XCTAssertThrowsError(try generationParameters(temperature: -.leastNonzeroMagnitude))
        XCTAssertThrowsError(try generationParameters(temperature: .infinity))
        XCTAssertThrowsError(try generationParameters(topP: 0))
        XCTAssertThrowsError(try generationParameters(topP: 1.1))
        XCTAssertThrowsError(try generationParameters(topK: 0))
        XCTAssertThrowsError(try generationParameters(repetitionPenalty: 0))
        XCTAssertThrowsError(try generationParameters(repetitionPenalty: .nan))
        XCTAssertThrowsError(try generationParameters(seed: 9_007_199_254_740_992))
    }

    func testAdvertisedDescriptorOrderAndSelectorRationaleAreFrozenWithoutReordering() throws {
        let schema = try inputSchema()
        let first = try toolDescriptor(schema: schema, name: "alpha")
        let second = try toolDescriptor(schema: schema, name: "beta")
        let forwardSelection = try selectionSnapshot(
            tools: [first, second],
            inputDigest: TestValues.digest("1"),
            rationale: "request.relevant"
        )
        let reverseSelection = try selectionSnapshot(
            tools: [second, first],
            inputDigest: TestValues.digest("1"),
            rationale: "request.relevant"
        )
        let message = try AgentModelMessage(role: .user, content: "Use a tool", isUntrustedData: false)
        let forward = try modelRequest(
            message: message,
            advertisedTools: [first, second],
            toolSelectionSnapshot: forwardSelection
        )
        let reverse = try modelRequest(
            message: message,
            advertisedTools: [second, first],
            toolSelectionSnapshot: reverseSelection
        )
        XCTAssertEqual(forward.advertisedToolIDs, [first.id, second.id])
        XCTAssertEqual(reverse.advertisedToolIDs, [second.id, first.id])
        let forwardFingerprint = try forward.fingerprint()
        XCTAssertNotEqual(forwardFingerprint, try reverse.fingerprint())

        let changedInput = try modelRequest(
            message: message,
            advertisedTools: [first, second],
            toolSelectionSnapshot: selectionSnapshot(
                tools: [first, second],
                inputDigest: TestValues.digest("2"),
                rationale: "request.relevant"
            )
        )
        let changedRationale = try modelRequest(
            message: message,
            advertisedTools: [first, second],
            toolSelectionSnapshot: selectionSnapshot(
                tools: [first, second],
                inputDigest: TestValues.digest("1"),
                rationale: "user.pinned"
            )
        )
        XCTAssertNotEqual(forwardFingerprint, try changedInput.fingerprint())
        XCTAssertNotEqual(forwardFingerprint, try changedRationale.fingerprint())
        try assertContractRoundTrip(forwardSelection)

        XCTAssertThrowsError(try modelRequest(
            message: message,
            advertisedTools: [first, second],
            toolSelectionSnapshot: reverseSelection
        ))
        XCTAssertThrowsError(try AgentToolSelectionDecision(
            descriptorID: first.id,
            rationaleCodes: []
        ))
        XCTAssertThrowsError(try AgentToolSelectionSnapshot(
            selectorID: "runtime.tool-selector",
            policyVersion: 1,
            inputDigest: TestValues.digest("1"),
            decisions: [
                AgentToolSelectionDecision(
                    descriptorID: first.id,
                    rationaleCodes: ["request.relevant"]
                ),
                AgentToolSelectionDecision(
                    descriptorID: first.id,
                    rationaleCodes: ["user.pinned"]
                ),
            ]
        ))
    }

    func testCompleteAdvertisedDescriptorNotOnlyItsIDIsAuthorizationBound() throws {
        let schema = try inputSchema()
        let descriptor = try toolDescriptor(schema: schema)
        let altered = try AgentToolDescriptor(
            id: descriptor.id,
            title: "Different local title",
            summary: descriptor.summary,
            inputSchema: descriptor.inputSchema,
            outputSchema: descriptor.outputSchema,
            effects: descriptor.effects,
            requiredCapabilities: descriptor.requiredCapabilities,
            timeoutPolicy: descriptor.timeoutPolicy,
            retryPolicy: descriptor.retryPolicy,
            idempotency: descriptor.idempotency,
            supportsProgress: !descriptor.supportsProgress,
            supportsCancellation: descriptor.supportsCancellation
        )
        let message = try AgentModelMessage(role: .user, content: "Lookup", isUntrustedData: false)
        let original = try modelRequest(message: message, advertisedTools: [descriptor])
        let changed = try modelRequest(message: message, advertisedTools: [altered])
        XCTAssertEqual(original.advertisedToolIDs, changed.advertisedToolIDs)
        let originalFingerprint = try original.fingerprint()
        XCTAssertNotEqual(originalFingerprint, try changed.fingerprint())
        try assertContractRoundTrip(original)

        let answer = try AgentModelCompletion(
            action: .finalAnswer(AgentAnswer(text: "done")),
            usage: usage()
        )
        XCTAssertThrowsError(try answer.validate(
            against: original,
            resolvedToolDescriptors: [altered]
        ))
    }

    func testProviderMetadataPreparedRequestAndTerminalSurfacesRoundTrip() throws {
        let providerA = try AgentModelProviderID("local.alpha")
        let providerB = try AgentModelProviderID("local.beta")
        XCTAssertEqual(providerA.description, "local.alpha")
        XCTAssertTrue(providerA < providerB)

        let firstSelection = AgentModelSelection(
            providerID: providerA,
            modelID: try AgentModelID("bonsai"),
            variantID: try AgentModelVariantID("8b-1bit"),
            capabilityVersion: SemanticVersion("1.0.0")!
        )
        let secondSelection = AgentModelSelection(
            providerID: providerB,
            modelID: try AgentModelID("gemma"),
            variantID: try AgentModelVariantID("e2b"),
            capabilityVersion: SemanticVersion("1.1.0")!
        )
        XCTAssertEqual([secondSelection, firstSelection].sorted().first, firstSelection)

        let features = AgentModelCapabilitySet(AgentModelCapability.allCases)
        XCTAssertTrue(features.contains(.nativeToolCalling))
        try assertContractRoundTrip(features)
        let resources = try ModelResourceConstraints(
            maximumConcurrentAttempts: 1,
            requiresResidentModel: true,
            requiresDrainBeforeSwitch: true
        )
        try assertContractRoundTrip(resources)
        let capabilities = try AgentModelCapabilities(
            maximumContextTokens: 8_192,
            maximumOutputTokens: 1_024,
            features: features,
            toolCallingMode: .nativeStructured,
            cancellationGranularity: .token,
            resourceConstraints: resources,
            reportsTokenUsage: true,
            reportsCost: false
        )
        try assertContractRoundTrip(capabilities)
        XCTAssertThrowsError(try ModelResourceConstraints(
            maximumConcurrentAttempts: 0,
            requiresResidentModel: false,
            requiresDrainBeforeSwitch: false
        ))
        XCTAssertThrowsError(try AgentModelCapabilities(
            maximumContextTokens: 10,
            maximumOutputTokens: 11,
            features: features,
            toolCallingMode: .unavailable,
            cancellationGranularity: .attemptBoundary,
            resourceConstraints: resources,
            reportsTokenUsage: false,
            reportsCost: false
        ))

        let policy = try AgentModelPolicy(
            localOnly: true,
            allowedSelections: [firstSelection, secondSelection],
            strategy: .deterministicLocalPolicy,
            requiredCapabilities: features
        )
        try assertContractRoundTrip(policy)

        let request = try modelRequest(
            message: AgentModelMessage(role: .user, content: "Answer", isUntrustedData: false)
        )
        let prepared = try PreparedModelRequest(
            request: request,
            externalOperation: localPreparedOperation(for: request)
        )
        try assertContractRoundTrip(prepared)

        let reportedUsage = try AgentModelUsage(
            inputTokens: 10,
            outputTokens: 2,
            activeMilliseconds: 3,
            peakMemoryBytes: 4,
            reportedCostMicros: 5,
            costCurrencyCode: "USD"
        )
        try assertContractRoundTrip(reportedUsage)
        let completion = try AgentModelCompletion(
            action: .finalAnswer(AgentAnswer(text: "Done")),
            usage: reportedUsage
        )
        try assertContractRoundTrip(completion)
        XCTAssertFalse(AgentModelEvent.answerDelta("Done").isTerminal)
        XCTAssertTrue(AgentModelEvent.completed(completion).isTerminal)
        XCTAssertNoThrow(try AgentModelEventStreamValidator.validate(
            [.answerDelta("Done"), .usage(reportedUsage), .completed(completion)],
            request: request,
            resolvedToolDescriptors: []
        ))

        let schema = try inputSchema()
        let descriptor = try toolDescriptor(schema: schema)
        let newer = try AgentToolDescriptorID(
            logicalID: descriptor.id.logicalID,
            version: SemanticVersion("2.0.0")!,
            schemaDigest: descriptor.id.schemaDigest,
            trustRevision: descriptor.id.trustRevision
        )
        let changedSchema = try AgentToolDescriptorID(
            logicalID: descriptor.id.logicalID,
            version: descriptor.id.version,
            schemaDigest: TestValues.digest("9"),
            trustRevision: descriptor.id.trustRevision
        )
        let changedTrust = try AgentToolDescriptorID(
            logicalID: descriptor.id.logicalID,
            version: descriptor.id.version,
            schemaDigest: descriptor.id.schemaDigest,
            trustRevision: "local-2"
        )
        XCTAssertTrue(descriptor.id < newer)
        XCTAssertNotEqual(descriptor.id < changedSchema, changedSchema < descriptor.id)
        XCTAssertNotEqual(descriptor.id < changedTrust, changedTrust < descriptor.id)
    }
}

private extension ModelAndToolContractTests {
    func inputSchema() throws -> JSONSchemaDocument {
        try JSONSchemaDocument(root: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string"), "minLength": .integer(1)]),
            ]),
            "required": .array([.string("query")]),
            "additionalProperties": .bool(false),
        ]))
    }

    func toolDescriptor(
        schema: JSONSchemaDocument,
        version: SemanticVersion = SemanticVersion("1.0.0")!,
        name: String = "lookup"
    ) throws -> AgentToolDescriptor {
        let logical = try AgentToolLogicalID(providerID: "test-provider", name: name)
        let id = try AgentToolDescriptorID(
            logicalID: logical,
            version: version,
            schemaDigest: schema.digest,
            trustRevision: "local-1"
        )
        return try AgentToolDescriptor(
            id: id,
            title: "Lookup",
            summary: "Look up a value",
            inputSchema: schema,
            effects: [AgentEffect.networkRead],
            requiredCapabilities: AgentCapabilitySet([.networkRead]),
            timeoutPolicy: ToolTimeoutPolicy(maximumMilliseconds: 5_000),
            retryPolicy: .never,
            idempotency: .pureRead,
            supportsProgress: true,
            supportsCancellation: true
        )
    }

    func selection() throws -> AgentModelSelection {
        AgentModelSelection(
            providerID: try AgentModelProviderID("local-provider"),
            modelID: try AgentModelID("gemma"),
            variantID: try AgentModelVariantID("e2b"),
            capabilityVersion: SemanticVersion("1.0.0")!
        )
    }

    func modelRequest(
        message: AgentModelMessage,
        advertisedTools: [AgentToolDescriptor] = [],
        toolSelectionSnapshot: AgentToolSelectionSnapshot? = nil,
        generationParameters: AgentModelGenerationParameters = .standard,
        output: AgentOutputRequirement = .text,
        requestID: AgentRequestID = TestValues.id(AgentRequestIDDomain.self, 90),
        runID: AgentRunID = TestValues.id(AgentRunIDDomain.self, 91),
        stepID: AgentStepID = TestValues.id(AgentStepIDDomain.self, 92)
    ) throws -> AgentModelRequest {
        let selectionSnapshot = try toolSelectionSnapshot ?? self.selectionSnapshot(
            tools: advertisedTools,
            inputDigest: TestValues.digest("d"),
            rationale: "request.relevant"
        )
        return try AgentModelRequest(
            requestID: requestID,
            runID: runID,
            stepID: stepID,
            selection: selection(),
            compiledManifestDigest: TestValues.digest("f"),
            messages: [message],
            advertisedTools: advertisedTools,
            toolSelectionSnapshot: selectionSnapshot,
            generationParameters: generationParameters,
            outputRequirement: output
        )
    }

    func selectionSnapshot(
        tools: [AgentToolDescriptor],
        inputDigest: StableDigest,
        rationale: String
    ) throws -> AgentToolSelectionSnapshot {
        try AgentToolSelectionSnapshot(
            selectorID: "runtime.tool-selector",
            policyVersion: 1,
            inputDigest: inputDigest,
            decisions: tools.map { descriptor in
                try AgentToolSelectionDecision(
                    descriptorID: descriptor.id,
                    rationaleCodes: [rationale]
                )
            }
        )
    }

    func generationParameters(
        maximumOutputTokens: UInt64 = 64,
        maximumContextTokens: UInt64 = 128,
        temperature: Double = 0.7,
        topP: Double = 1,
        topK: UInt32? = nil,
        repetitionPenalty: Double = 1,
        thinkingMode: AgentModelThinkingMode = .automatic,
        seed: UInt64? = nil
    ) throws -> AgentModelGenerationParameters {
        try AgentModelGenerationParameters(
            maximumOutputTokens: maximumOutputTokens,
            maximumContextTokens: maximumContextTokens,
            temperature: temperature,
            topP: topP,
            topK: topK,
            repetitionPenalty: repetitionPenalty,
            thinkingMode: thinkingMode,
            seed: seed
        )
    }

    func localPreparedOperation(
        for request: AgentModelRequest
    ) throws -> PreparedExternalOperationRequest {
        let canonical = try request.authorizationPayload()
        let payload = TestValues.sanitized(canonical)
        let ceiling = RunCapabilityCeiling(authority: .empty)
        let grant = try StepCapabilityGrant(runCeiling: ceiling, authority: .empty)
        let plan = try ExternalOperationPlan(
            kind: .localPure,
            subjectID: "local.model.generate",
            payloadDigest: canonical.fingerprint,
            effects: [AgentEffect.localPure],
            requiredCapabilities: AgentCapabilitySet([]),
            maximumRequestBytes: UInt64(canonical.data.count + 16),
            maximumResponseBytes: 8 * 1_024 * 1_024,
            timeoutMilliseconds: 60_000,
            retryPolicy: .never,
            idempotency: .pureRead,
            userPreview: ""
        )
        return try PreparedExternalOperationRequest(
            requestID: request.requestID,
            runID: request.runID,
            conversationID: TestValues.id(ConversationIDDomain.self, 93),
            stepID: request.stepID,
            plan: plan,
            payload: payload,
            capabilityGrant: grant
        )
    }

    func usage(
        input: UInt64 = 1,
        output: UInt64 = 1,
        milliseconds: UInt64 = 1
    ) throws -> AgentModelUsage {
        try AgentModelUsage(
            inputTokens: input,
            outputTokens: output,
            activeMilliseconds: milliseconds,
            peakMemoryBytes: 1_024
        )
    }
}

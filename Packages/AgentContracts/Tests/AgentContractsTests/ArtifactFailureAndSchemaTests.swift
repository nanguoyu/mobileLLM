// SPDX-License-Identifier: MIT

import XCTest
@testable import AgentContracts

final class ArtifactFailureAndSchemaTests: XCTestCase {
    func testArtifactLocatorsAreRootConfinedAndProviderOpaqueLocatorsAreNamespaced() throws {
        XCTAssertNoThrow(
            try ArtifactLocator(kind: .managedRelativePath, value: "runs/step/output.json")
        )
        for path in [
            "/private/output.json",
            "~/output.json",
            "../output.json",
            "runs/../output.json",
            "runs/./output.json",
            "runs//output.json",
            " runs/output.json",
            "runs/output.json\n",
        ] {
            XCTAssertThrowsError(
                try ArtifactLocator(kind: .managedRelativePath, value: path),
                "Managed path must reject \(String(reflecting: path))"
            )
        }

        XCTAssertThrowsError(
            try ArtifactLocator(
                kind: .managedRelativePath,
                value: "runs/output.json",
                providerID: "provider-a"
            )
        )
        XCTAssertThrowsError(try ArtifactLocator(kind: .providerOpaque, value: "opaque-1"))
        XCTAssertNoThrow(
            try ArtifactLocator(
                kind: .providerOpaque,
                value: "opaque-1",
                providerID: "provider-a"
            )
        )
    }

    func testArtifactMIMEProvenanceSemanticTypeAndSecretRules() throws {
        XCTAssertNoThrow(try makeArtifact(mimeType: "image/svg+xml"))
        for mimeType in ["IMAGE/PNG", "text/plain; charset=utf-8", "text", "text/", "/plain", " text/plain"] {
            XCTAssertThrowsError(
                try makeArtifact(mimeType: mimeType),
                "Artifact MIME must reject \(String(reflecting: mimeType))"
            )
        }

        let runID = TestValues.id(AgentRunIDDomain.self, 100)
        XCTAssertThrowsError(
            try ArtifactProvenance(stepID: TestValues.id(AgentStepIDDomain.self, 101))
        )
        XCTAssertThrowsError(
            try ArtifactProvenance(invocationID: TestValues.id(ToolInvocationIDDomain.self, 102))
        )
        XCTAssertNoThrow(
            try ArtifactProvenance(
                runID: runID,
                stepID: TestValues.id(AgentStepIDDomain.self, 101),
                invocationID: TestValues.id(ToolInvocationIDDomain.self, 102),
                externalOperationFingerprint: TestValues.digest("d"),
                providerID: "provider-a"
            )
        )
        XCTAssertThrowsError(try ArtifactProvenance(runID: runID, providerID: "provider\nname"))

        XCTAssertThrowsError(try makeArtifact(semanticType: ""))
        XCTAssertThrowsError(try makeArtifact(semanticType: " output"))
        XCTAssertThrowsError(try makeArtifact(sensitivity: .secret))

        let valid = try makeArtifact()
        let forgedSecret = try replacingJSONField(
            in: encodedJSON(valid),
            path: ["sensitivity"],
            with: RedactionClassification.secret.rawValue
        )
        XCTAssertThrowsError(try JSONDecoder().decode(ArtifactReference.self, from: forgedSecret))
    }

    func testSecretReferencesAreOpaqueBoundedAndDecodeValidated() throws {
        let secret = try SecretReference(
            id: TestValues.id(SecretReferenceIDDomain.self, 110),
            purpose: "model provider credential",
            providerID: "provider-a"
        )
        XCTAssertEqual(try JSONDecoder().decode(SecretReference.self, from: encodedJSON(secret)), secret)

        XCTAssertThrowsError(
            try SecretReference(id: secret.id, purpose: "", providerID: "provider-a")
        )
        XCTAssertThrowsError(
            try SecretReference(id: secret.id, purpose: " bearer-token\n", providerID: "provider-a")
        )
        XCTAssertThrowsError(
            try SecretReference(id: secret.id, purpose: "credential", providerID: "provider\nname")
        )

        let forged = try replacingJSONField(
            in: encodedJSON(secret),
            path: ["purpose"],
            with: "\nplaintext"
        )
        XCTAssertThrowsError(try JSONDecoder().decode(SecretReference.self, from: forged))
    }

    func testAgentFailureEnforcesUncertaintyIffAndRetrySemantics() throws {
        XCTAssertNoThrow(
            try makeFailure(classification: .permanent, externalEffect: .confirmedNone)
        )
        XCTAssertNoThrow(
            try makeFailure(
                classification: .potentiallySideEffecting,
                externalEffect: .uncertain,
                action: .reconcile
            )
        )

        XCTAssertThrowsError(
            try makeFailure(classification: .potentiallySideEffecting, externalEffect: .confirmedNone)
        )
        XCTAssertThrowsError(
            try makeFailure(classification: .permanent, externalEffect: .uncertain, action: .reconcile)
        )
        XCTAssertThrowsError(
            try makeFailure(classification: .potentiallySideEffecting, externalEffect: .uncertain)
        )
        XCTAssertThrowsError(
            try makeFailure(
                classification: .potentiallySideEffecting,
                externalEffect: .uncertain,
                action: .reconcile,
                retry: AgentRetryAdvice(
                    automaticallyRetryable: true,
                    maximumAdditionalAttempts: 1
                )
            )
        )

        let retry = try AgentRetryAdvice(
            automaticallyRetryable: true,
            maximumAdditionalAttempts: 2,
            delayMilliseconds: 50
        )
        XCTAssertNoThrow(
            try makeFailure(classification: .transient, externalEffect: .confirmedNone, retry: retry)
        )
        XCTAssertThrowsError(
            try makeFailure(classification: .permanent, externalEffect: .confirmedNone, retry: retry)
        )
        XCTAssertThrowsError(
            try AgentRetryAdvice(
                automaticallyRetryable: false,
                maximumAdditionalAttempts: 1
            )
        )
    }

    func testAgentFailureAndRedactionBoundsRejectConstructorAndCodableForgeries() throws {
        for code in ["failure", "Failure.code", "failure..code", "failure.code-", ".failure"] {
            XCTAssertThrowsError(try makeFailure(code: code), "Failure code must reject \(code)")
        }
        for message in ["", " leading", "trailing ", "unsafe\nmessage"] {
            XCTAssertThrowsError(try makeFailure(safeMessage: message))
        }
        XCTAssertThrowsError(try makeFailure(safeMessage: String(repeating: "x", count: 2_049)))
        XCTAssertThrowsError(try makeFailure(details: ["unsafe\nkey": "value"]))
        XCTAssertThrowsError(try makeFailure(details: ["key": "unsafe\nvalue"]))
        XCTAssertThrowsError(try makeFailure(details: ["key": String(repeating: "x", count: 2_049)]))

        let tooMany = Dictionary(uniqueKeysWithValues: (0 ..< 65).map { ("key-\($0)", "value") })
        XCTAssertThrowsError(try makeFailure(details: tooMany))
        let tooLarge = Dictionary(uniqueKeysWithValues: (0 ..< 33).map {
            ("key-\($0)", String(repeating: "x", count: 2_048))
        })
        XCTAssertThrowsError(try makeFailure(details: tooLarge))

        XCTAssertThrowsError(
            try RedactionMetadata(classification: .secret, policyVersion: 1)
        )
        XCTAssertThrowsError(
            try RedactionMetadata(
                classification: .secret,
                redactedFieldPaths: ["credential"],
                omittedByteCount: 0,
                policyVersion: 1
            )
        )
        XCTAssertNoThrow(
            try RedactionMetadata(
                classification: .secret,
                redactedFieldPaths: ["credential"],
                omittedByteCount: 16,
                policyVersion: 1
            )
        )
        for classification in [
            RedactionClassification.sensitive,
            .personalData,
            .secret,
        ] {
            XCTAssertThrowsError(
                try RedactionMetadata(
                    classification: classification,
                    redactedFieldPaths: ["field"],
                    omittedByteCount: 4,
                    policyVersion: 1,
                    omittedContentDigest: TestValues.digest("f")
                )
            )
        }

        let redaction = try RedactionMetadata(
            classification: .personalData,
            redactedFieldPaths: ["a", "b"],
            omittedByteCount: 8,
            policyVersion: 1
        )
        var object = try JSONSerialization.jsonObject(with: encodedJSON(redaction)) as! [String: Any]
        object["redactedFieldPaths"] = ["a", "a"]
        let duplicatePaths = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(try JSONDecoder().decode(RedactionMetadata.self, from: duplicatePaths))

        let failure = try makeFailure()
        let forgedFailure = try replacingJSONField(
            in: encodedJSON(failure),
            path: ["externalEffect"],
            with: ExternalEffectDisposition.uncertain.rawValue
        )
        XCTAssertThrowsError(try JSONDecoder().decode(AgentFailure.self, from: forgedFailure))
    }

    func testJSONSchemaRejectsMalformedSupportedKeywordShapes() throws {
        XCTAssertThrowsError(try JSONSchemaDocument(root: .array([])))

        var structurallyHostile: JSONValue = .object([:])
        for _ in 0 ... AgentWireDecodingLimits.inlineValue.maximumNestingDepth {
            structurallyHostile = .object(["properties": structurallyHostile])
        }
        XCTAssertThrowsError(try JSONSchemaDocument(root: structurallyHostile))

        let malformed: [JSONValue] = [
            .object(["type": .string("date")]),
            .object(["type": .array([.string("string"), .string("string")])]),
            .object(["required": .array([.string("name"), .string("name")])]),
            .object(["properties": .object(["name": .string("not-a-schema")])]),
            .object(["additionalProperties": .string("no")]),
            .object(["minItems": .integer(2), "maxItems": .integer(1)]),
            .object(["minLength": .integer(-1)]),
            .object(["multipleOf": .integer(0)]),
            .object(["allOf": .array([])]),
        ]
        for root in malformed {
            XCTAssertThrowsError(try JSONSchemaDocument(root: root), "Malformed schema accepted: \(root)")
        }
    }

    func testJSONSchemaUnknownAndUnsafePatternArePreservedButNotClaimedEnforced() throws {
        let unknown = try JSONSchemaDocument(
            root: .object([
                "type": .string("string"),
                "format": .string("email"),
                "x-policy": .string("local"),
            ])
        )
        XCTAssertEqual(unknown.enforcement, .partiallyEnforced)
        XCTAssertEqual(unknown.unenforcedKeywords, ["format", "x-policy"])
        XCTAssertThrowsError(try unknown.validates(instance: .string("person@example.com")))
        XCTAssertEqual(try JSONDecoder().decode(JSONSchemaDocument.self, from: encodedJSON(unknown)), unknown)

        let pattern = try JSONSchemaDocument(
            root: .object(["type": .string("string"), "pattern": .string("(a+)+$")])
        )
        XCTAssertEqual(pattern.enforcement, .partiallyEnforced)
        XCTAssertEqual(pattern.unenforcedKeywords, ["pattern"])
        XCTAssertThrowsError(try pattern.validates(instance: .string("aaaa")))

        let tightLimits = try JSONSchemaLimits(
            maximumEncodedBytes: 1_024,
            maximumNestingDepth: 8,
            maximumResolvedNodes: 64,
            maximumLocalReferenceDepth: 4,
            maximumPatternLength: 4
        )
        XCTAssertThrowsError(
            try JSONSchemaDocument(
                root: .object(["pattern": .string("12345")]),
                limits: tightLimits
            )
        )

        let forged = try replacingJSONField(
            in: encodedJSON(unknown),
            path: ["enforcement"],
            with: JSONSchemaEnforcement.fullyEnforced.rawValue
        )
        XCTAssertThrowsError(try JSONDecoder().decode(JSONSchemaDocument.self, from: forged))
    }

    func testJSONSchemaLocalReferencesResolveAndExpansionFailuresCloseTheContract() throws {
        let schema = try JSONSchemaDocument(
            root: .object([
                "$defs": .object([
                    "shortName": .object([
                        "type": .string("string"),
                        "minLength": .integer(2),
                        "maxLength": .integer(4),
                    ]),
                ]),
                "type": .string("object"),
                "required": .array([.string("name")]),
                "properties": .object([
                    "name": .object(["$ref": .string("#/$defs/shortName")]),
                ]),
                "additionalProperties": .bool(false),
            ])
        )
        XCTAssertTrue(try schema.validates(instance: .object(["name": .string("Dong")])))
        XCTAssertFalse(try schema.validates(instance: .object(["name": .string("D")])))

        XCTAssertThrowsError(
            try JSONSchemaDocument(root: .object(["$ref": .string("#/$defs/missing")]))
        )
        XCTAssertThrowsError(
            try JSONSchemaDocument(root: .object(["$ref": .string("https://example.invalid/schema")]))
        )
        XCTAssertThrowsError(
            try JSONSchemaDocument(
                root: .object([
                    "$defs": .object([
                        "a": .object(["$ref": .string("#/$defs/b")]),
                        "b": .object(["$ref": .string("#/$defs/a")]),
                    ]),
                    "$ref": .string("#/$defs/a"),
                ])
            )
        )

        let shallowReferences = try JSONSchemaLimits(
            maximumEncodedBytes: 4_096,
            maximumNestingDepth: 16,
            maximumResolvedNodes: 128,
            maximumLocalReferenceDepth: 1,
            maximumPatternLength: 32
        )
        XCTAssertThrowsError(
            try JSONSchemaDocument(
                root: .object([
                    "$defs": .object([
                        "a": .object(["$ref": .string("#/$defs/b")]),
                        "b": .object(["type": .string("string")]),
                    ]),
                    "$ref": .string("#/$defs/a"),
                ]),
                limits: shallowReferences
            )
        )
    }

    func testJSONSchemaInstanceValidationCoversObjectsArraysNumbersAndCombinators() throws {
        let schema = try JSONSchemaDocument(
            root: .object([
                "type": .string("object"),
                "required": .array([.string("name"), .string("score"), .string("tags")]),
                "properties": .object([
                    "name": .object([
                        "type": .string("string"),
                        "minLength": .integer(2),
                        "maxLength": .integer(4),
                    ]),
                    "score": .object([
                        "type": .string("number"),
                        "minimum": .integer(0),
                        "exclusiveMaximum": .integer(11),
                        "multipleOf": .integer(2),
                    ]),
                    "tags": .object([
                        "type": .string("array"),
                        "minItems": .integer(1),
                        "maxItems": .integer(2),
                        "uniqueItems": .bool(true),
                        "items": .object(["type": .string("string")]),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        )
        let valid: JSONValue = .object([
            "name": .string("Dong"),
            "score": .integer(10),
            "tags": .array([.string("ios"), .string("agent")]),
        ])
        XCTAssertTrue(try schema.validates(instance: valid))
        XCTAssertFalse(
            try schema.validates(
                instance: .object([
                    "name": .string("D"),
                    "score": .integer(9),
                    "tags": .array([.string("ios"), .string("ios")]),
                    "extra": .bool(true),
                ])
            )
        )

        let combinators = try JSONSchemaDocument(
            root: .object([
                "allOf": .array([
                    .object(["type": .string("integer")]),
                    .object(["minimum": .integer(2)]),
                ]),
                "anyOf": .array([
                    .object(["const": .integer(2)]),
                    .object(["const": .integer(4)]),
                ]),
                "oneOf": .array([
                    .object(["maximum": .integer(3)]),
                    .object(["minimum": .integer(4)]),
                ]),
                "not": .object(["const": .integer(3)]),
            ])
        )
        XCTAssertTrue(try combinators.validates(instance: .integer(2)))
        XCTAssertTrue(try combinators.validates(instance: .integer(4)))
        XCTAssertFalse(try combinators.validates(instance: .integer(3)))
        XCTAssertFalse(try combinators.validates(instance: .string("2")))
    }

    func testToolResultCollectionBoundsImageMIMEAndResourceURLs() throws {
        XCTAssertThrowsError(try ToolResultCollection([]))

        let emptyText = try ToolTextResult("")
        XCTAssertNoThrow(
            try ToolResultCollection(
                Array(repeating: ToolResultContent.text(emptyText), count: ToolResultCollection.maximumItemCount)
            )
        )
        XCTAssertThrowsError(
            try ToolResultCollection(
                Array(repeating: ToolResultContent.text(emptyText), count: ToolResultCollection.maximumItemCount + 1)
            )
        )

        let maximumText = try ToolTextResult(
            String(repeating: "x", count: ToolResultCollection.maximumInlineBytes)
        )
        XCTAssertNoThrow(try ToolResultCollection([.text(maximumText)]))
        XCTAssertThrowsError(
            try ToolResultCollection([
                .text(maximumText),
                .text(try ToolTextResult("x")),
            ])
        )
        XCTAssertThrowsError(
            try ToolTextResult(String(repeating: "x", count: ToolResultCollection.maximumInlineBytes + 1))
        )
        let oversizedStructured = try CanonicalJSON(
            .string(String(repeating: "x", count: ToolResultCollection.maximumInlineBytes))
        )
        XCTAssertThrowsError(try ToolStructuredResult(oversizedStructured))

        let image = try makeArtifact(mimeType: "image/png")
        let text = try makeArtifact(mimeType: "text/plain")
        XCTAssertNoThrow(try ToolResultCollection([.image(image)]))
        XCTAssertThrowsError(try ToolResultCollection([.image(text)]))
        XCTAssertNoThrow(try ToolResultCollection([.artifact(text)]))

        XCTAssertNoThrow(
            try ToolResourceLink(url: "https://example.invalid/result", mimeType: "application/json")
        )
        XCTAssertNoThrow(try ToolResourceLink(url: "http://example.invalid/result"))
        for url in [
            "file:///tmp/result",
            "/relative/result",
            "https:///missing-host",
            "https://user@example.invalid/result",
            "https://user:password@example.invalid/result",
        ] {
            XCTAssertThrowsError(try ToolResourceLink(url: url), "Resource URL must reject \(url)")
        }
        XCTAssertThrowsError(
            try ToolResourceLink(url: "https://example.invalid", mimeType: "Text/Plain")
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ToolResultCollection.self,
                from: encodedJSON([ToolResultContent.image(text)])
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ToolResultCollection.self,
                from: encodedJSON(
                    Array(
                        repeating: ToolResultContent.text(emptyText),
                        count: ToolResultCollection.maximumItemCount + 1
                    )
                )
            )
        )
    }

    private func makeArtifact(
        mimeType: String = "text/plain",
        semanticType: String? = "test-output",
        sensitivity: RedactionClassification = .publicMetadata
    ) throws -> ArtifactReference {
        try ArtifactReference(
            id: TestValues.id(ArtifactIDDomain.self, 120),
            contentDigest: TestValues.digest("c"),
            byteCount: 12,
            mimeType: mimeType,
            semanticType: semanticType,
            provenance: ArtifactProvenance(runID: TestValues.id(AgentRunIDDomain.self, 121)),
            createdAt: AgentTimestamp(rawValue: 1_000),
            retentionPolicy: .run,
            locator: ArtifactLocator(kind: .managedRelativePath, value: "runs/output.bin"),
            sensitivity: sensitivity,
            integrityStatus: .verified
        )
    }

    private func makeFailure(
        code: String = "test.failure",
        classification: AgentFailureClassification = .permanent,
        safeMessage: String = "Safe failure",
        externalEffect: ExternalEffectDisposition = .confirmedNone,
        action: AgentRequiredUserAction = .none,
        retry: AgentRetryAdvice = .never,
        details: [String: String] = [:]
    ) throws -> AgentFailure {
        try AgentFailure(
            code: code,
            classification: classification,
            safeMessage: safeMessage,
            retryAdvice: retry,
            externalEffect: externalEffect,
            requiredUserAction: action,
            details: details,
            redaction: TestValues.redaction()
        )
    }
}

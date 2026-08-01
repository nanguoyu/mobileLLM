// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import AgentContracts

final class IdentifiersVersioningAndWireTests: XCTestCase {
    private struct SamplePayload: AgentContractPayload, Equatable {
        static let schemaID = "test.contract.sample"
        let value: String
    }

    private struct InvalidDeclarationPayload: AgentContractPayload {
        static let schemaID = "Not Valid"
        static let supportedPayloadVersions: ClosedRange<UInt16> = 1 ... 1
        static let currentPayloadVersion: UInt16 = 2
        let value: String
    }

    // TEST-ID: AHT-CONTRACT-001
    func testStableIdentifierRoundTripsAndDomains() throws {
        let run = TestValues.id(AgentRunIDDomain.self, 1)
        let request = TestValues.id(AgentRequestIDDomain.self, 1)
        XCTAssertEqual(run.description, "00000000-0000-4000-8000-000000000001")
        XCTAssertEqual(try AgentWireDecoder.decode(AgentRunID.self, from: encodedJSON(run)), run)
        XCTAssertNotEqual(String(describing: type(of: run)), String(describing: type(of: request)))

        let uppercase = Data("\"00000000-0000-4000-8000-00000000000A\"".utf8)
        XCTAssertThrowsError(try AgentWireDecoder.decode(AgentRunID.self, from: uppercase))
    }

    // TEST-ID: AHT-CONTRACT-002
    func testVersionedEnvelopeCompatibilityAndGoldenWire() throws {
        let envelope = try AgentEnvelope(payload: SamplePayload(value: "hello"))
        let bytes = try encodedJSON(envelope)
        XCTAssertEqual(try AgentEnvelope<SamplePayload>.decodeUntrusted(from: bytes), envelope)
        XCTAssertEqual(
            String(decoding: bytes, as: UTF8.self),
            #"{"payload":{"value":"hello"},"payloadVersion":1,"protocolVersion":"1.0.0","schemaID":"test.contract.sample"}"#
        )

        let wrongVersion = try replacingJSONField(in: bytes, path: ["payloadVersion"], with: 2)
        XCTAssertThrowsError(try AgentEnvelope<SamplePayload>.decodeUntrusted(from: wrongVersion))
        let wrongSchema = try replacingJSONField(in: bytes, path: ["schemaID"], with: "test.contract.other")
        XCTAssertThrowsError(try AgentEnvelope<SamplePayload>.decodeUntrusted(from: wrongSchema))
        XCTAssertThrowsError(try AgentEnvelope(payload: InvalidDeclarationPayload(value: "x")))
    }

    func testSemVerFullNumericPrereleaseOrderingAndASCIIValidation() throws {
        let huge = SemanticVersion("1.0.0-184467440737095516160")!
        let larger = SemanticVersion("1.0.0-184467440737095516161")!
        XCTAssertLessThan(huge, larger)
        XCTAssertLessThan(SemanticVersion("1.0.0-9")!, huge)
        XCTAssertNil(SemanticVersion("1.0.0-１"))
        XCTAssertNil(SemanticVersion("01.0.0"))
        XCTAssertLessThan(SemanticVersion("1.0.0+aaa")!, SemanticVersion("1.0.0+bbb")!)
        XCTAssertFalse(
            SemanticVersion("1.0.0+aaa")!.hasLowerSemanticPrecedence(
                than: SemanticVersion("1.0.0+bbb")!
            )
        )
    }

    func testCanonicalJSONRFC8785NumbersOrderingAndIJSONGuard() throws {
        XCTAssertEqual(try JSONValue.number(1.0).canonicalStringForTest, "1")
        XCTAssertEqual(try JSONValue.number(-0.0).canonicalStringForTest, "0")
        XCTAssertEqual(try JSONValue.number(1e-7).canonicalStringForTest, "1e-7")
        XCTAssertEqual(try JSONValue.number(1e20).canonicalStringForTest, "100000000000000000000")
        XCTAssertEqual(try JSONValue.number(1.2e20).canonicalStringForTest, "120000000000000000000")
        XCTAssertEqual(try JSONValue.number(1e21).canonicalStringForTest, "1e+21")
        XCTAssertEqual(try JSONValue.number(1e30).canonicalStringForTest, "1e+30")
        XCTAssertEqual(
            try JSONValue.number(Double.greatestFiniteMagnitude).canonicalStringForTest,
            "1.7976931348623157e+308"
        )
        XCTAssertEqual(
            try JSONValue.number(Double.leastNonzeroMagnitude).canonicalStringForTest,
            "5e-324"
        )
        XCTAssertEqual(
            try JSONValue.number(333_333_333.33333329).canonicalStringForTest,
            "333333333.3333333"
        )
        XCTAssertThrowsError(try JSONValue.integer(9_007_199_254_740_992).canonicalData())
        XCTAssertEqual(
            try JSONValue.number(9_007_199_254_740_992.0).canonicalStringForTest,
            "9007199254740992"
        )

        let object = JSONValue.object(["\u{20ac}": .integer(1), "\r": .integer(2), "a": .integer(3)])
        XCTAssertEqual(try object.canonicalStringForTest, #"{"\r":2,"a":3,"€":1}"#)
    }

    func testUntrustedWireDecoderPreflightsBeforeTypedDecode() throws {
        let tiny = try AgentWireDecodingLimits(
            maximumBytes: 32,
            maximumNestingDepth: 2,
            maximumCollectionItems: 4,
            maximumStringBytes: 8
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(JSONValue.self, from: Data("[[[0]]]".utf8), limits: tiny)
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(
                JSONValue.self,
                from: Data(#""123456789""#.utf8),
                limits: tiny
            )
        )
        let forgedLimits = Data(
            #"{"maximumBytes":0,"maximumNestingDepth":0,"maximumCollectionItems":0,"maximumStringBytes":0}"#.utf8
        )
        XCTAssertThrowsError(try AgentWireDecoder.decode(AgentWireDecodingLimits.self, from: forgedLimits))
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(
                JSONValue.self,
                from: Data(#"{"a":1,"\u0061":2}"#.utf8)
            )
        )
    }

    func testTimestampsAndSecretRedactionFailClosed() throws {
        XCTAssertThrowsError(try AgentTimestamp(Date(timeIntervalSince1970: .infinity)))
        XCTAssertThrowsError(
            try RedactionMetadata(
                classification: .secret,
                policyVersion: 1,
                omittedContentDigest: TestValues.digest()
            )
        )
        XCTAssertNoThrow(
            try RedactionMetadata(
                classification: .secret,
                redactedFieldPaths: ["credential.password"],
                omittedByteCount: 12,
                policyVersion: 1
            )
        )
    }
}

private extension JSONValue {
    var canonicalStringForTest: String {
        get throws { String(decoding: try canonicalData(), as: UTF8.self) }
    }
}

// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI
@testable import LLMCore

/// `Message.attachments` is strictly additive + Codable-back-compat (C2.2): an old record (no key)
/// decodes with attachments nil, a text-only turn re-encodes without the key, and refs round-trip.
final class MessageAttachmentCodableTests: XCTestCase {

    func testOldRecordWithoutAttachmentsKeyDecodesNil() throws {
        // A record written before `attachments` existed — the key is simply absent.
        let json = Data("""
        {"id":"\(UUID().uuidString)","role":"user","createdAt":0,"answer":"hello"}
        """.utf8)
        let message = try JSONDecoder().decode(Message.self, from: json)
        XCTAssertNil(message.attachments, "a missing key decodes as nil (back-compat)")
        XCTAssertNil(message.generatedBy, "old records also decode without generation attribution")
        XCTAssertEqual(message.answer, "hello")
    }

    func testTextOnlyMessageReEncodesWithoutAttachmentsKey() throws {
        let message = Message(role: .user, answer: "just text")
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(message), encoding: .utf8))
        XCTAssertFalse(json.contains("attachments"),
                       "a text-only turn omits the key (byte-compatible with the old form)")
        XCTAssertFalse(json.contains("generatedBy"), "unknown legacy attribution stays omitted")
    }

    func testAttachmentsRoundTrip() throws {
        let refs = [ImageRef(), ImageRef()]
        let message = Message(role: .user, answer: "look at these", attachments: refs)
        let back = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(back.attachments, refs, "attachment refs survive a Codable round-trip")
        XCTAssertEqual(back, message)
    }

    func testImageRefFileNameDerivesFromID() {
        let ref = ImageRef()
        XCTAssertEqual(ref.fileName, "\(ref.id.uuidString).jpg")
    }

    func testGenerationAttributionRoundTrips() throws {
        let attribution = GenerationModel(
            modelID: "bonsai-8b",
            variantID: "bonsai-8b-gguf-1bit",
            displayName: "Bonsai 8B",
            engine: .llamaCpp
        )
        let message = Message(role: .assistant, answer: "hello", generatedBy: attribution)

        let decoded = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(message))

        XCTAssertEqual(decoded.generatedBy, attribution)
        XCTAssertEqual(decoded, message)
    }
}

// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

/// The image-input schema additions (C1.1): `ChatTurn.images`, `LLMVariant.visionProjector`, and the pure
/// file-selection logic. Every assertion is Codable back-compat or pure-function behavior — no model, no
/// network. The back-compat cases are load-bearing: `ChatStore` conversations and adopted-model registries
/// were persisted before these fields existed and must still decode.
final class VisionSchemaTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - ChatTurn.images

    /// Old persisted turns (no `images` key) still decode, defaulting to an empty attachment list.
    func testChatTurnDecodesLegacyJSONWithoutImages() throws {
        let legacy = Data(#"{"role":"user","content":"hi"}"#.utf8)
        let turn = try decoder.decode(ChatTurn.self, from: legacy)
        XCTAssertEqual(turn.role, .user)
        XCTAssertEqual(turn.content, "hi")
        XCTAssertEqual(turn.images, [])
    }

    /// A text-only turn re-encodes to the SAME shape as before — the `images` key is omitted when empty —
    /// so nothing about existing persisted conversations changes on a rewrite.
    func testChatTurnTextOnlyEncodesWithoutImagesKey() throws {
        let json = String(decoding: try encoder.encode(ChatTurn(role: .assistant, content: "yo")), as: UTF8.self)
        XCTAssertFalse(json.contains("images"), "a text-only turn must not emit an images key")
    }

    /// An image-bearing turn round-trips: encode then decode yields the identical value (Data survives as
    /// base64), and the key is present.
    func testChatTurnWithImagesRoundTrips() throws {
        let img = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])   // JPEG magic-ish bytes
        let turn = ChatTurn(role: .user, content: "look", images: [img, Data([1, 2, 3])])
        let json = String(decoding: try encoder.encode(turn), as: UTF8.self)
        XCTAssertTrue(json.contains("images"))
        let back = try decoder.decode(ChatTurn.self, from: try encoder.encode(turn))
        XCTAssertEqual(back, turn)
        XCTAssertEqual(back.images.count, 2)
    }

    /// The default initializer keeps every existing `ChatTurn(role:content:)` call site meaning exactly what
    /// it did — an empty attachment list.
    func testChatTurnDefaultInitHasNoImages() {
        XCTAssertEqual(ChatTurn(role: .user, content: "x").images, [])
    }

    // MARK: - LLMVariant.visionProjector

    private func gguf(_ projector: VisionProjector?) -> LLMVariant {
        LLMVariant(quant: .gguf4bit, backend: .llamaCppGGUF, onDiskBytes: 1_000,
                   source: ModelSource(huggingFaceRepo: "org/repo", fileName: "model.gguf"),
                   visionProjector: projector)
    }

    /// A variant persisted before `visionProjector` existed (no key) decodes with it nil — the adopted
    /// registry / cached remote catalog survives the upgrade.
    func testLLMVariantDecodesLegacyJSONWithoutProjector() throws {
        // Encoding a projector-less variant IS the legacy shape (the key is omitted when nil); decoding it
        // back proves a pre-field snapshot round-trips.
        let legacyData = try encoder.encode(gguf(nil))
        let legacyJSON = String(decoding: legacyData, as: UTF8.self)
        XCTAssertFalse(legacyJSON.contains("visionProjector"), "a text variant must not emit the key")
        let back = try decoder.decode(LLMVariant.self, from: legacyData)
        XCTAssertNil(back.visionProjector)
        XCTAssertEqual(back, gguf(nil))
    }

    /// A vision variant round-trips with its projector intact.
    func testLLMVariantWithProjectorRoundTrips() throws {
        let v = gguf(VisionProjector(fileName: "mmproj-F16.gguf", sizeBytes: 672_423_616))
        let json = String(decoding: try encoder.encode(v), as: UTF8.self)
        XCTAssertTrue(json.contains("visionProjector"))
        XCTAssertEqual(try decoder.decode(LLMVariant.self, from: try encoder.encode(v)), v)
    }

    func testSupportsVisionInputReflectsProjector() {
        XCTAssertTrue(gguf(VisionProjector(fileName: "m.gguf", sizeBytes: 1)).supportsVisionInput)
        XCTAssertFalse(gguf(nil).supportsVisionInput)
    }

    // MARK: - requiredFileNames (the pure file-selection logic, C1.3)

    /// A single-file GGUF variant with a projector needs BOTH files, weight first then projector.
    func testRequiredFileNamesGGUFWithProjector() {
        let v = gguf(VisionProjector(fileName: "mmproj-F16.gguf", sizeBytes: 1))
        XCTAssertEqual(v.requiredFileNames, ["model.gguf", "mmproj-F16.gguf"])
    }

    /// A single-file GGUF variant without a projector needs just its one weight file.
    func testRequiredFileNamesGGUFOnly() {
        XCTAssertEqual(gguf(nil).requiredFileNames, ["model.gguf"])
    }

    /// A flat repo (no `source.fileName`, the MLX case) needs the whole repo — an empty selection.
    func testRequiredFileNamesFlatRepoIsEmpty() {
        let mlx = LLMVariant(quant: .binary1bit, backend: .mlxFork, onDiskBytes: 1,
                             source: ModelSource(huggingFaceRepo: "org/mlx"))
        XCTAssertEqual(mlx.requiredFileNames, [])
    }
}

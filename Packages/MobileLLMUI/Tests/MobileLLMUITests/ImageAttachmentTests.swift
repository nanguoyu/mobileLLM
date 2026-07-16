// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI

/// The pure downscale/re-encode helper (C2.1): a picked photo is shrunk to a bounded long edge and
/// re-encoded as JPEG BEFORE it ever rides the prompt or lands on disk.
final class ImageAttachmentTests: XCTestCase {

    func testDownscaleShrinksLongEdgeToBound() throws {
        let big = makeTestImageData(width: 4000, height: 3000)   // 12 MP, 4:3
        let jpeg = try XCTUnwrap(ImageAttachment.downscaledJPEG(from: big, maxLongEdge: 1568))
        let size = try XCTUnwrap(ImageAttachment.pixelSize(of: jpeg))
        let longEdge = max(size.width, size.height)
        XCTAssertLessThanOrEqual(longEdge, 1568, "long edge is capped at the bound")
        XCTAssertGreaterThan(longEdge, 1500, "and it actually downscaled to near the bound")
        // Aspect ratio is preserved (4:3).
        XCTAssertEqual(size.width / size.height, 4.0 / 3.0, accuracy: 0.02)
    }

    func testDownscaleNeverUpscalesASmallImage() throws {
        let small = makeTestImageData(width: 120, height: 80)
        let jpeg = try XCTUnwrap(ImageAttachment.downscaledJPEG(from: small, maxLongEdge: 1568))
        let size = try XCTUnwrap(ImageAttachment.pixelSize(of: jpeg))
        XCTAssertEqual(size.width, 120, accuracy: 1, "a small image keeps its size (no upscale)")
        XCTAssertEqual(size.height, 80, accuracy: 1)
    }

    func testDownscaleReEncodesToJpeg() throws {
        let png = makeTestImageData(width: 800, height: 600)
        let jpeg = try XCTUnwrap(ImageAttachment.downscaledJPEG(from: png))
        // JPEG SOI marker (0xFFD8) — proves it re-encoded, not passed the PNG through.
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8])
    }

    func testDownscaleRejectsNonImageBytes() {
        XCTAssertNil(ImageAttachment.downscaledJPEG(from: Data("this is not an image".utf8)))
        XCTAssertNil(ImageAttachment.pixelSize(of: Data()))
    }
}

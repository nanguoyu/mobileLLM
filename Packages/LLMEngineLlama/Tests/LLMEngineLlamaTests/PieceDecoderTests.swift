// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMEngineLlama

/// The UTF-8 reassembly contract: multi-byte characters split across token pieces must survive, and
/// nothing is dropped or duplicated across `feed`/`flush`.
final class PieceDecoderTests: XCTestCase {

    private func cchars(_ s: String) -> [CChar] { s.utf8.map { CChar(bitPattern: $0) } }
    private func bytes(_ b: [UInt8]) -> [CChar] { b.map { CChar(bitPattern: $0) } }

    func testAsciiPassesThrough() {
        var d = PieceDecoder()
        XCTAssertEqual(d.feed(cchars("Hello")), "Hello")
        XCTAssertEqual(d.feed(cchars(", world")), ", world")
        XCTAssertEqual(d.flush(), "")
    }

    func testMultiByteSplitAcrossPieces() {
        // "世" is E4 B8 96 — split it 1 byte / 2 bytes across two pieces.
        let s = "世".utf8.map { $0 }
        var d = PieceDecoder()
        XCTAssertEqual(d.feed(bytes([s[0]])), "", "incomplete lead byte must be held back")
        XCTAssertEqual(d.feed(bytes([s[1]])), "", "still incomplete after 2 of 3 bytes")
        XCTAssertEqual(d.feed(bytes([s[2]])), "世", "completes on the third byte")
        XCTAssertEqual(d.flush(), "")
    }

    func testEmojiSplitFourBytes() {
        // "🐇" is F0 9F 90 87 (4 bytes). Feed one byte at a time.
        let e = "🐇".utf8.map { $0 }
        var d = PieceDecoder()
        var out = ""
        for b in e { out += d.feed(bytes([b])) }
        out += d.flush()
        XCTAssertEqual(out, "🐇")
    }

    func testMixedRunReassembles() {
        // A realistic run where CJK boundaries fall mid-piece: concatenate all outputs, expect the whole.
        let full = "Paris 是法国的首都。🇫🇷 done"
        let all = full.utf8.map { $0 }
        var d = PieceDecoder()
        var out = ""
        // Chop into irregular 3-byte pieces to force mid-character splits.
        var i = 0
        while i < all.count {
            let end = min(i + 3, all.count)
            out += d.feed(bytes(Array(all[i..<end])))
            i = end
        }
        out += d.flush()
        XCTAssertEqual(out, full)
    }

    func testFlushSurfacesTruncatedTail() {
        // A genuinely truncated stream (lead byte only) should not silently vanish — flush emits U+FFFD.
        var d = PieceDecoder()
        XCTAssertEqual(d.feed(bytes([0xE4])), "")   // held back
        let tail = d.flush()
        XCTAssertFalse(tail.isEmpty, "flush must surface the held-back byte rather than drop it")
    }

    func testIncompleteSuffixLength() {
        XCTAssertEqual(PieceDecoder.incompleteSuffixLength([0x41]), 0)                 // 'A' complete
        XCTAssertEqual(PieceDecoder.incompleteSuffixLength([0xE4, 0xB8, 0x96]), 0)     // full 3-byte
        XCTAssertEqual(PieceDecoder.incompleteSuffixLength([0xE4, 0xB8]), 2)           // 2 of 3
        XCTAssertEqual(PieceDecoder.incompleteSuffixLength([0x41, 0xF0]), 1)           // trailing 4-byte lead
    }
}

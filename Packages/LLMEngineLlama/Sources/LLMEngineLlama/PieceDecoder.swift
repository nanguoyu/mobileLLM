// SPDX-License-Identifier: MIT

import Foundation

/// Reassembles UTF-8 text from the raw byte pieces `llama_token_to_piece` emits. A single token's bytes
/// can end in the MIDDLE of a multi-byte UTF-8 sequence (CJK, emoji, combining marks split across two
/// tokens), so decoding each piece independently would corrupt those characters. This buffers bytes and
/// only emits the longest *complete* UTF-8 prefix, holding back an incomplete trailing sequence until the
/// next piece completes it.
///
/// CRITICAL (mirrors ThinkSplitter.finish): call `flush()` at stream end to surface any final bytes. In
/// well-formed output the tail is always complete so `flush` returns "", but a truncated stream would
/// otherwise silently drop its last partial character.
struct PieceDecoder {
    private var buffer: [UInt8] = []

    /// Feed one token's raw bytes (the `CChar` piece from `llama_token_to_piece`, without a terminator).
    /// Returns any newly-completed text (may be empty while a multi-byte char is still assembling).
    mutating func feed(_ piece: [CChar]) -> String {
        buffer.append(contentsOf: piece.map { UInt8(bitPattern: $0) })
        let hold = Self.incompleteSuffixLength(buffer)
        guard buffer.count > hold else { return "" }
        let head = Array(buffer[0..<(buffer.count - hold)])
        buffer.removeFirst(buffer.count - hold)
        return String(decoding: head, as: UTF8.self)
    }

    /// Emit whatever is still buffered at stream end (a genuinely truncated trailing sequence is rendered
    /// with the Unicode replacement character rather than dropped).
    mutating func flush() -> String {
        guard !buffer.isEmpty else { return "" }
        let s = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll()
        return s
    }

    /// Length of the trailing bytes that form an INCOMPLETE UTF-8 sequence (0 when the buffer ends on a
    /// character boundary). Walks back at most 4 bytes to the last lead byte and compares the bytes
    /// present against the length that lead byte announces.
    static func incompleteSuffixLength(_ bytes: [UInt8]) -> Int {
        var back = 0
        var i = bytes.count - 1
        while i >= 0 && back < 4 {
            let b = bytes[i]
            if b & 0b1100_0000 != 0b1000_0000 {   // a lead byte (or ASCII) — end of the walk-back
                let expected: Int
                if b & 0b1000_0000 == 0 { expected = 1 }                 // 0xxxxxxx
                else if b & 0b1110_0000 == 0b1100_0000 { expected = 2 }  // 110xxxxx
                else if b & 0b1111_0000 == 0b1110_0000 { expected = 3 }  // 1110xxxx
                else if b & 0b1111_1000 == 0b1111_0000 { expected = 4 }  // 11110xxx
                else { return 0 }                                        // invalid lead → let it render as U+FFFD
                let have = back + 1
                return have < expected ? have : 0
            }
            back += 1
            i -= 1
        }
        return 0
    }
}

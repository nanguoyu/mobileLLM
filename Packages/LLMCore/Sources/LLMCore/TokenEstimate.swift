// SPDX-License-Identifier: MIT

import Foundation

/// A CJK-aware token-count estimate (DESIGN §2.5 — context/trim math).
///
/// The flat `count / 4` heuristic used elsewhere assumes ~4 characters per token, which holds for Latin
/// text but UNDER-counts CJK by roughly 3×: a subword tokenizer almost never merges Chinese/Japanese/
/// Korean characters, so each one is ≈1 token, not ¼. On a Chinese chat that error compounds until the
/// context window and history-trim logic silently overrun. This estimator segments a string by script and
/// estimates each run on its own terms: CJK ideographs, kana, hangul (and emoji) at ≈1 token per scalar,
/// everything else at ≈chars/4.
///
/// It is a heuristic, not a tokenizer — good enough for budgeting, never a substitute for the model's own
/// tokenizer when exactness matters.
public enum TokenEstimate {

    /// Estimated token count for `text`. Empty string → 0; any non-empty string → at least 1.
    public static func tokens(in text: String) -> Int {
        var total = 0
        var narrowRun = 0   // consecutive non-CJK scalars pending the ~chars/4 estimate
        for scalar in text.unicodeScalars {
            if isWide(scalar) {
                total += narrowTokens(narrowRun); narrowRun = 0
                total += 1
            } else {
                narrowRun += 1
            }
        }
        total += narrowTokens(narrowRun)
        return max(text.isEmpty ? 0 : 1, total)
    }

    /// ~chars/4 for a run of non-CJK scalars, rounded UP so a 1–3 character word still costs a token.
    private static func narrowTokens(_ count: Int) -> Int {
        count == 0 ? 0 : (count + 3) / 4
    }

    /// A scalar that a tokenizer almost never merges with its neighbor, so it costs ≈1 token on its own:
    /// CJK ideographs (incl. extensions + compatibility), kana, hangul (syllables + jamo), CJK symbols /
    /// fullwidth forms, and emoji. Everything else is "narrow" and estimated by the chars/4 rule.
    private static func isWide(_ s: Unicode.Scalar) -> Bool {
        if s.properties.isEmojiPresentation { return true }   // 😀 yes; '#'/'*'/digits (no default emoji) no
        switch s.value {
        case 0x3000...0x303F,    // CJK symbols & punctuation
             0x3040...0x30FF,    // hiragana + katakana
             0x31F0...0x31FF,    // katakana phonetic extensions
             0x3400...0x4DBF,    // CJK unified ideographs ext A
             0x4E00...0x9FFF,    // CJK unified ideographs
             0xF900...0xFAFF,    // CJK compatibility ideographs
             0x1100...0x11FF,    // hangul jamo
             0x3130...0x318F,    // hangul compatibility jamo
             0xA960...0xA97F,    // hangul jamo extended-A
             0xAC00...0xD7AF,    // hangul syllables
             0xD7B0...0xD7FF,    // hangul jamo extended-B
             0xFF00...0xFFEF,    // halfwidth & fullwidth forms
             0x20000...0x2FA1F:  // CJK ideographs ext B–F + compatibility supplement
            return true
        default:
            return false
        }
    }
}

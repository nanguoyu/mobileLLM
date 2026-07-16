// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMEngineApple

/// The cumulative→incremental contract. FoundationModels streams SNAPSHOTS (each carrying the whole
/// answer so far) while `EngineDelta` is append-only, so a pass-through would repeat the entire response
/// on every chunk. These pin the subtraction — including the cases that make a naive `dropFirst` wrong.
final class SnapshotDifferTests: XCTestCase {

    /// Feed a whole stream and return the deltas, dropping empties (what the engine yields).
    private func deltas(_ snapshots: [String]) -> [String] {
        var differ = SnapshotDiffer()
        return snapshots.map { differ.delta(for: $0) }.filter { !$0.isEmpty }
    }

    /// Concatenating the deltas must reproduce the final snapshot — the property the UI depends on.
    private func assertRebuilds(_ snapshots: [String], _ expected: [String],
                                file: StaticString = #filePath, line: UInt = #line) {
        let out = deltas(snapshots)
        XCTAssertEqual(out, expected, file: file, line: line)
        XCTAssertEqual(out.joined(), snapshots.last ?? "",
                       "the deltas must rebuild the final snapshot exactly", file: file, line: line)
    }

    // MARK: - The normal, append-only stream

    func testGrowingSnapshotsYieldOnlyTheNewText() {
        assertRebuilds(["Hi", "Hi there", "Hi there!"], ["Hi", " there", "!"])
    }

    func testSingleSnapshotIsEmittedWhole() {
        assertRebuilds(["The whole answer at once."], ["The whole answer at once."])
    }

    func testTableDrivenStreams() {
        let cases: [(name: String, snapshots: [String], expected: [String])] = [
            ("empty stream", [], []),
            ("empty snapshots only", ["", "", ""], []),
            ("leading empty snapshot", ["", "a", "ab"], ["a", "b"]),
            ("one character at a time", ["a", "ab", "abc"], ["a", "b", "c"]),
            ("large jump", ["a", "abcdefgh"], ["a", "bcdefgh"]),
            ("trailing whitespace grows", ["ok", "ok ", "ok !"], ["ok", " ", "!"]),
            ("newlines", ["a", "a\n", "a\nb"], ["a", "\n", "b"]),
        ]
        for c in cases {
            let out = deltas(c.snapshots)
            XCTAssertEqual(out, c.expected, c.name)
            XCTAssertEqual(out.joined(), c.snapshots.last ?? "", "\(c.name): deltas must rebuild the answer")
        }
    }

    // MARK: - Repeats and rewinds

    /// A repeated snapshot adds nothing. Emitting it again would duplicate the whole answer.
    func testRepeatedSnapshotYieldsNothing() {
        assertRebuilds(["Hello", "Hello", "Hello world", "Hello world"], ["Hello", " world"])
    }

    /// A SHORTER snapshot we've already covered must not rewind the high-water mark: if it did, the next
    /// (longer) snapshot would re-emit the tail the UI already has.
    func testShorterSnapshotDoesNotRewindAndCauseDuplication() {
        var differ = SnapshotDiffer()
        XCTAssertEqual(differ.delta(for: "Hello world"), "Hello world")
        XCTAssertEqual(differ.delta(for: "Hello"), "", "already emitted — nothing new to say")
        XCTAssertEqual(differ.delta(for: "Hello world"), "", "must NOT re-emit ' world'")
        XCTAssertEqual(differ.delta(for: "Hello world!"), "!")
    }

    // MARK: - Grapheme clusters (why the diff is scalar-wise, not Character-wise)

    /// A cumulative stream can extend a grapheme cluster it already sent. "👨" and "👨‍👩‍👦" are each a
    /// SINGLE Character, so a Character-wise `hasPrefix` reads false and would re-emit the whole cluster
    /// ("👨👨‍👩‍👦"). Scalar-wise, only the joining scalars go out and the UI rebuilds the intended cluster.
    func testGrowingGraphemeClusterEmitsOnlyTheNewScalars() {
        var differ = SnapshotDiffer()
        XCTAssertEqual(differ.delta(for: "👨"), "👨")
        let delta = differ.delta(for: "👨‍👩‍👦")
        XCTAssertEqual("👨" + delta, "👨‍👩‍👦", "the UI's concatenation must rebuild the family emoji")
        XCTAssertFalse(delta.unicodeScalars.contains("👨"), "the man must not be sent twice")
    }

    /// The same hazard with a combining mark: "e" then "é" (e + U+0301).
    func testCombiningMarkExtendsRatherThanRepeats() {
        var differ = SnapshotDiffer()
        XCTAssertEqual(differ.delta(for: "cafe"), "cafe")
        let delta = differ.delta(for: "cafe\u{0301}")
        XCTAssertEqual(delta, "\u{0301}", "only the combining accent is new")
        XCTAssertEqual("cafe" + delta, "café")
    }

    /// Emoji as ordinary appended text still works (the common case, not the cluster-extension one).
    func testAppendedEmoji() {
        assertRebuilds(["Done", "Done ✅"], ["Done", " ✅"])
    }

    // MARK: - Divergence (defensive)

    /// If a snapshot REVISES text we already handed over, we can't unsay it — `EngineDelta` is append-only.
    /// The differ emits only what follows the common prefix and resynchronises, so a single revision costs
    /// one garbled stretch rather than a duplicated answer, and later deltas are clean again.
    func testDivergentSnapshotEmitsOnlyPastTheCommonPrefix() {
        var differ = SnapshotDiffer()
        XCTAssertEqual(differ.delta(for: "Hello world"), "Hello world")
        XCTAssertEqual(differ.delta(for: "Hello there"), "there", "only the revised tail, not the whole snapshot")
        // Resynchronised: the stream continues cleanly from the model's own text.
        XCTAssertEqual(differ.delta(for: "Hello there!"), "!")
    }

    /// A completely different snapshot shares no prefix, so all of it is new.
    func testTotalDivergenceEmitsTheWholeSnapshot() {
        var differ = SnapshotDiffer()
        XCTAssertEqual(differ.delta(for: "abc"), "abc")
        XCTAssertEqual(differ.delta(for: "xyz"), "xyz")
    }

    /// The high-water mark tracks exactly what was handed over in the append-only case.
    func testEmittedTracksTheStream() {
        var differ = SnapshotDiffer()
        XCTAssertEqual(differ.emitted, "")
        _ = differ.delta(for: "one")
        _ = differ.delta(for: "one two")
        XCTAssertEqual(differ.emitted, "one two")
    }
}

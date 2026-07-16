// SPDX-License-Identifier: MIT

import Foundation

/// Turns FoundationModels' CUMULATIVE response stream into the incremental deltas `EngineDelta` promises.
///
/// A `LanguageModelSession.ResponseStream` yields `Snapshot`s, and a snapshot's `content` is the whole
/// partially-generated response *so far* — not the newest fragment. Passing snapshots straight through
/// would make the UI re-append the entire answer on every chunk ("Hi" → "Hi there" → "Hi there!" renders
/// as "HiHi thereHi there!"). This subtracts whatever has already been emitted.
///
/// Diffing is over UNICODE SCALARS, not Characters. A cumulative stream can extend a grapheme cluster it
/// already sent — "👨" then "👨‍👩‍👦" — and because that family emoji is a SINGLE Character, a Character-wise
/// `hasPrefix` reads false and the whole cluster gets re-emitted (leaving "👨👨‍👩‍👦" on screen). Scalar-wise
/// the earlier text is still a prefix, so only the new scalars (ZWJ, 👩, ZWJ, 👦) go out and the UI
/// re-assembles the intended cluster.
struct SnapshotDiffer {

    /// Everything handed to the caller so far: the high-water mark of what the UI has concatenated.
    private(set) var emitted = ""

    /// The text in `snapshot` that hasn't been emitted yet — "" when it adds nothing.
    mutating func delta(for snapshot: String) -> String {
        let new = snapshot.unicodeScalars
        let old = emitted.unicodeScalars

        // The expected case: the response only grew.
        if new.starts(with: old) {
            let delta = String(String.UnicodeScalarView(new.dropFirst(old.count)))
            emitted = snapshot
            return delta
        }

        // A snapshot we've already fully covered (a re-send, or a shorter one): nothing new to say.
        // `emitted` deliberately does NOT rewind — dropping back to the shorter text would make the next
        // snapshot re-emit the tail the UI already has.
        if old.starts(with: new) { return "" }

        // Divergence: this snapshot REVISED text we already handed over. `EngineDelta` is append-only, so
        // what's emitted can't be taken back; the least-corrupting move is to emit only what follows the
        // common prefix and resynchronise on the model's own text — one garbled stretch instead of a
        // duplicated answer, and every later delta is clean again. Not expected from a `String` stream,
        // which grows monotonically; this is the defensive path.
        let common = zip(old, new).prefix { $0.0 == $0.1 }.count
        let delta = String(String.UnicodeScalarView(new.dropFirst(common)))
        emitted = snapshot
        return delta
    }
}

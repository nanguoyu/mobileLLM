// SPDX-License-Identifier: MIT

import Foundation

/// The stock system prompt.
///
/// Written for **small on-device models** (1.7B–27B), which is a different craft from prompting a
/// frontier model: every rule costs context that the KV cache pays for in RAM, and a long prompt makes
/// a small model worse, not better — it starts reciting the rules instead of following them. So this is
/// deliberately short, each line is a behavior the base checkpoints actually get wrong without it, and
/// there's no persona theatre ("You are an expert…") — that measurably buys nothing.
///
/// The user can edit or clear it; `SystemPrompt.standard` is what a fresh install starts with and what
/// the Reset button restores.
public enum SystemPrompt {

    public static let standard = """
    You are a helpful assistant running entirely on the user's device.

    - Answer the question first, then add only the detail that earns its place.
    - Always reply in the user's language.
    - Use Markdown: fenced code blocks with a language tag, tables only for genuinely tabular data.
    - If you don't know, or the answer depends on something you can't see, say so plainly. Never invent \
    facts, numbers, quotes, citations, or URLs.
    - Your knowledge ends at a training cutoff and you have no internet access unless a tool gives it to \
    you, so don't guess at recent events — say what you'd need to check.
    """

    /// True when the text is the stock prompt (ignoring incidental whitespace) — drives the Reset affordance.
    public static func isStandard(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            == standard.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

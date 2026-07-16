// SPDX-License-Identifier: MIT

import Foundation
import LLMCore

/// Failures from the Apple system-model engine. Each surfaces to the chat UI through
/// `error.localizedDescription`, so every case must read as guidance that names the REAL reason: this
/// engine's most likely failure — "Apple Intelligence is off" — is one the user can actually fix, and a
/// bland "couldn't load the model" would hide the fix.
public enum AppleEngineError: Error, Sendable, Equatable, LocalizedError {
    /// The OS says its model can't be used; carries the real reason it gave.
    case unavailable(SystemModelStatus.Reason)
    case noUserMessage
    /// The conversation outgrew the session's context window.
    case contextWindowExceeded
    /// The system's safety guardrails refused the prompt or the response.
    case guardrailViolation
    /// The prompt's language isn't one the system model supports.
    case unsupportedLanguage
    /// Anything else the framework threw. Carries the framework's OWN description rather than a guess.
    case generationFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            // The reason already reads as user-facing guidance ("…turn it on in Settings"): don't wrap it
            // in a second sentence that buries the fix.
            return reason.message
        case .noUserMessage:
            return "There's nothing to answer yet — send a message first."
        case .contextWindowExceeded:
            return "This conversation is longer than Apple Intelligence's context window. Start a new chat, "
                + "or switch to a downloadable model with a longer context."
        case .guardrailViolation:
            return "Apple Intelligence declined to respond to this one. Rephrasing often helps, or you can "
                + "switch to a downloadable model, which applies no such filter."
        case .unsupportedLanguage:
            return "Apple Intelligence doesn't support this language yet. Switch to a downloadable model — "
                + "they cover more languages."
        case .generationFailed(let reason):
            return "Apple Intelligence couldn't finish this response (\(reason))."
        }
    }
}

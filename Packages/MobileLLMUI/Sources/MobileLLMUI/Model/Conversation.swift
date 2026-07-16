// SPDX-License-Identifier: MIT

import Foundation
import LLMCore

/// One message in a conversation (DESIGN §2.4). Reasoning + answer are stored split so the thinking
/// disclosure can re-render a completed turn exactly as it streamed. `parentID` is plumbed for the
/// v1.0 edit/branch pager (the pager UI itself is deferred).
/// A tool the assistant invoked during a turn — its name, a short argument summary, and the result once
/// it returns (nil while running). Shown as an activity row and persisted with the message.
public struct ToolRun: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var arguments: String
    public var result: String?
    public init(id: UUID = UUID(), name: String, arguments: String, result: String? = nil) {
        self.id = id; self.name = name; self.arguments = arguments; self.result = result
    }
}

/// A reference to one image the user attached to a turn. The bytes live as a FILE
/// (`attachments/<id>.jpg` under the conversation store root, written/deleted by `ConversationStore`),
/// never inlined into the conversation JSON — so a multi-MB photo doesn't bloat every record load, and a
/// hard-delete purges the pixels with the thread (the privacy promise, DESIGN §2.4).
public struct ImageRef: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public init(id: UUID = UUID()) { self.id = id }
    /// The on-disk filename under the store's `attachments/` directory.
    public var fileName: String { "\(id.uuidString).jpg" }
}

public struct Message: Identifiable, Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable, Equatable {
        case system, user, assistant
    }

    /// Why an assistant turn ended with no answer text — the user tapped Stop, or generation errored.
    /// Drives the compact "Stopped / Failed — Retry" row instead of a ghost "0 tok" stats line. Optional
    /// → older records (and every normal turn) decode as nil.
    public enum EmptyOutcome: String, Codable, Sendable, Equatable { case stopped, failed }

    public let id: UUID
    public var role: Role
    public var createdAt: Date
    /// The visible answer text (everything outside `<think>`).
    public var answer: String
    /// The `<think>` reasoning, if the turn produced any (nil for user/system turns).
    public var reasoning: String?
    /// Set when an assistant turn committed with an empty answer (interrupted before the first token or
    /// failed). nil for every turn that produced text.
    public var emptyOutcome: EmptyOutcome?
    /// Wall-clock the model spent inside its `<think>` block, persisted so the collapsed reasoning tile
    /// shows an honest "Thought for Xs" (optional → old records without it decode as nil).
    public var thinkingSeconds: Double?
    /// Tools the assistant called during this turn (empty/absent for non-tool turns; optional → old
    /// records decode as nil).
    public var toolRuns: [ToolRun]?
    /// End-of-generation stats for an assistant turn (nil while streaming / for non-assistant turns).
    public var stats: Stats?
    /// The turn this message was branched/regenerated from (v1.0 branch pager).
    public var parentID: UUID?
    /// Images the user attached to this turn, as file references (bytes live under the store's
    /// `attachments/` dir — never inline here). Optional → old records without the key decode as nil,
    /// and a text-only turn re-encodes byte-identically (the synthesized Codable omits a nil key).
    public var attachments: [ImageRef]?

    public init(id: UUID = UUID(), role: Role, createdAt: Date = Date(),
                answer: String, reasoning: String? = nil, thinkingSeconds: Double? = nil,
                toolRuns: [ToolRun]? = nil, stats: Stats? = nil, parentID: UUID? = nil,
                emptyOutcome: EmptyOutcome? = nil, attachments: [ImageRef]? = nil) {
        self.id = id
        self.role = role
        self.createdAt = createdAt
        self.answer = answer
        self.reasoning = reasoning
        self.thinkingSeconds = thinkingSeconds
        self.toolRuns = toolRuns
        self.stats = stats
        self.parentID = parentID
        self.emptyOutcome = emptyOutcome
        self.attachments = attachments
    }

    /// A CJK-aware token estimate (`LLMCore.TokenEstimate`) used for context-window trimming — the old
    /// `count / 4` under-counted Chinese/Japanese/Korean ~3× and let the window silently overrun.
    var approximateTokens: Int { TokenEstimate.tokens(in: answer) }

    /// Whether this turn carries anything the engine should see — visible text OR image attachments. A
    /// user turn with only an image (no text) still counts; an empty assistant placeholder does not.
    var hasVisibleContent: Bool { !answer.isEmpty || !(attachments?.isEmpty ?? true) }
}

/// A chat thread (DESIGN §2.4). Persisted one-record-per-file by `ConversationStore`; a lightweight
/// `ConversationIndexEntry` mirrors it in `index.json` for fast list rendering.
public struct Conversation: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date
    /// Optional reference to a named system prompt; MVP threads inline the system prompt from Settings.
    public var systemPromptID: String?
    public var modelID: String
    /// The variant's Hugging Face repo id (`LLMVariant.id`).
    public var variantID: String
    public var messages: [Message]
    public var pinned: Bool

    public init(id: UUID = UUID(), title: String = "New Chat", createdAt: Date = Date(),
                updatedAt: Date = Date(), systemPromptID: String? = nil, modelID: String,
                variantID: String, messages: [Message] = [], pinned: Bool = false) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.systemPromptID = systemPromptID
        self.modelID = modelID
        self.variantID = variantID
        self.messages = messages
        self.pinned = pinned
    }

    /// A one-line preview for the conversation list (last user or assistant text).
    public var preview: String {
        for message in messages.reversed() where message.role != .system && !message.answer.isEmpty {
            return message.answer
        }
        return "No messages yet"
    }

    /// The index projection used for cheap list rendering + persistence consistency.
    var indexEntry: ConversationIndexEntry {
        ConversationIndexEntry(id: id, title: title, createdAt: createdAt, updatedAt: updatedAt,
                               modelID: modelID, messageCount: messages.count, pinned: pinned)
    }
}

/// The lightweight per-thread record kept in `index.json` so the list renders without loading every
/// full conversation file (DESIGN §2.4). `deletedAt` is the soft-delete tombstone.
public struct ConversationIndexEntry: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var modelID: String
    public var messageCount: Int
    public var pinned: Bool
    /// Set when the thread is soft-deleted; the underlying file is kept so the delete can be undone.
    public var deletedAt: Date?

    public init(id: UUID, title: String, createdAt: Date, updatedAt: Date, modelID: String,
                messageCount: Int, pinned: Bool, deletedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.modelID = modelID
        self.messageCount = messageCount
        self.pinned = pinned
        self.deletedAt = deletedAt
    }

    public var isDeleted: Bool { deletedAt != nil }
}

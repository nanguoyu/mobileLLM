// SPDX-License-Identifier: MIT

import Foundation
import LLMCore

/// One message in a conversation (DESIGN §2.4). Reasoning + answer are stored split so the thinking
/// disclosure can re-render a completed turn exactly as it streamed. `parentID` is plumbed for the
/// v1.0 edit/branch pager (the pager UI itself is deferred).
public struct Message: Identifiable, Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable, Equatable {
        case system, user, assistant
    }

    public let id: UUID
    public var role: Role
    public var createdAt: Date
    /// The visible answer text (everything outside `<think>`).
    public var answer: String
    /// The `<think>` reasoning, if the turn produced any (nil for user/system turns).
    public var reasoning: String?
    /// Wall-clock the model spent inside its `<think>` block, persisted so the collapsed reasoning tile
    /// shows an honest "Thought for Xs" (optional → old records without it decode as nil).
    public var thinkingSeconds: Double?
    /// End-of-generation stats for an assistant turn (nil while streaming / for non-assistant turns).
    public var stats: Stats?
    /// The turn this message was branched/regenerated from (v1.0 branch pager).
    public var parentID: UUID?

    public init(id: UUID = UUID(), role: Role, createdAt: Date = Date(),
                answer: String, reasoning: String? = nil, thinkingSeconds: Double? = nil,
                stats: Stats? = nil, parentID: UUID? = nil) {
        self.id = id
        self.role = role
        self.createdAt = createdAt
        self.answer = answer
        self.reasoning = reasoning
        self.thinkingSeconds = thinkingSeconds
        self.stats = stats
        self.parentID = parentID
    }

    /// A rough char→token proxy (matches `MockLLMEngine`), used for context-window trimming.
    var approximateTokens: Int { max(1, answer.count / 4) }
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

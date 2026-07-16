// SPDX-License-Identifier: MIT

import Foundation
import LLMCore

/// A transient banner surfaced over whichever screen the user is on (DESIGN §2.5 / §4). Errors carry
/// a forward action ("Switch to 8B"); destructive actions carry an Undo. The closure lives in the
/// store (keyed by `id`) so `Toast` stays `Equatable`.
public struct Toast: Identifiable, Equatable {
    public enum Kind: Equatable { case info, success, warning, error }
    public let id: UUID
    public var message: String
    public var kind: Kind
    /// Label for the optional forward action (Undo / Switch to 8B / Retry). `nil` = no action button.
    public var actionTitle: String?
    /// Seconds before the toast auto-dismisses. `nil` = sticky until replaced or actioned.
    public var autoDismiss: TimeInterval?

    public init(_ message: String, kind: Kind = .info, actionTitle: String? = nil,
                autoDismiss: TimeInterval? = 2.4, id: UUID = UUID()) {
        self.id = id
        self.message = message
        self.kind = kind
        self.actionTitle = actionTitle
        self.autoDismiss = autoDismiss
    }
}

/// Live state of the in-flight assistant turn (DESIGN §2.3). Only these small strings mutate per
/// token — the message array is untouched until `.done` commits — so streaming stays smooth.
public struct StreamingState: Equatable {
    public enum Phase: Equatable {
        /// Prefill latency before the first token — the composer shows a warming shimmer.
        case warming
        /// A `<think>` block is streaming — the thinking disclosure is auto-expanded.
        case thinking
        /// The answer is streaming — the disclosure has auto-collapsed to "Thought for Ns".
        case answering
        /// The user tapped Stop; we're committing at the next token boundary ("Stopping…").
        case stopping
    }

    /// The assistant message this stream will commit into.
    public var messageID: UUID
    public var phase: Phase = .warming
    public var reasoning: String = ""
    public var answer: String = ""
    public var stats: Stats?

    /// When the reasoning began + how long it lasted (frozen when the first answer token arrives).
    public var thinkingStartedAt: Date?
    public var thinkingDuration: TimeInterval?
    /// Tools invoked so far this turn (the last one is "running" until its result lands).
    public var toolActivity: [ToolRun] = []

    public init(messageID: UUID) { self.messageID = messageID }

    public var isReasoning: Bool { phase == .thinking }
    public var hasAnyContent: Bool { !reasoning.isEmpty || !answer.isEmpty || !toolActivity.isEmpty }
}

/// One image staged in the composer before sending — downscaled + JPEG-encoded bytes plus a stable id
/// so the thumbnail chips render + remove cleanly in a SwiftUI `ForEach`.
public struct PendingImage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let data: Data
    public init(id: UUID = UUID(), data: Data) {
        self.id = id
        self.data = data
    }
}

/// The currently-loaded model + variant the engine will generate with.
public struct LoadedModel: Equatable, Sendable {
    public var model: LLMModel
    public var variant: LLMVariant
    public init(model: LLMModel, variant: LLMVariant) {
        self.model = model
        self.variant = variant
    }
    public var subtitle: String { "\(model.displayName) · \(variant.quant.displayName)" }
}

/// How the thinking disclosure presents reasoning (Settings → Behavior; DESIGN §4).
public enum ThinkingDisplayMode: String, CaseIterable, Codable, Sendable {
    case autoCollapse   // default: expanded while thinking, collapses to "Thought for Ns" on answer
    case alwaysExpand   // keep reasoning visible
    case hidden         // never show reasoning

    public var label: String {
        switch self {
        case .autoCollapse: "Auto-collapse"
        case .alwaysExpand: "Always show"
        case .hidden: "Hidden"
        }
    }
}

/// In-app appearance override (Settings → Appearance).
public enum AppearanceMode: String, CaseIterable, Codable, Sendable {
    case system, light, dark
    public var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// The three top-level sections (DESIGN §4 IA). Lives here (not in the view) so the composition root can
/// raise a navigation intent — e.g. an error banner's "Download" jumping to Models — without importing the
/// shell.
public enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case chat, models, settings
    public var id: String { rawValue }
    public var title: String {
        switch self { case .chat: "Chat"; case .models: "Models"; case .settings: "Settings" }
    }
    public var icon: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .models: "square.stack.3d.up"
        case .settings: "gearshape"
        }
    }
}

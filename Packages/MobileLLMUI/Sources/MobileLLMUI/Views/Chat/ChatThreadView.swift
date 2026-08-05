// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import LLMCore
#if canImport(UIKit)
import UIKit
#endif

/// Tracks the bottom anchor's position in the scroll's coordinate space so we can detect "scrolled
/// away" (for the scroll-to-bottom pill) and sticky-bottom autoscroll on iOS 17 / macOS 14.
private struct BottomOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Tracks the thread content's own height so autoscroll can tell "content fits the viewport" apart from
/// "scrolled to the bottom of overflowing content" — scrollTo on under-filled content makes the whole
/// view judder on every token instead of scrolling.
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The message list + streaming surface (DESIGN §4). User turns are right-aligned bubbles; assistant
/// turns are full-width document text. History ALWAYS renders (a suspended/absent model never hides the
/// thread); a distinct loading state owns a cold-start load; sticky-bottom autoscroll with a "⌄ new"
/// pill when scrolled away.
struct ChatThreadView: View {
    let chat: ChatStore
    let displayMode: ThinkingDisplayMode
    /// A model is loading (cold start / switch) — shown as its own state, never as "no model".
    var isLoadingModel: Bool = false
    /// Best-effort name of the model being loaded (for the loading state).
    var loadingModelName: String = "your model"
    var onOpenModels: () -> Void
    /// Open the quick model switcher (the empty state's title is the picker).
    var onSwitchModel: () -> Void = {}
    /// The durable agent runtime projection surface; nil in legacy/preview layouts.
    var agentRuns: AgentRunStore? = nil

    @State private var atBottom = true
    /// The bottom marker's current Y in the scroll view's coordinate space.
    @State private var bottomMaxY: CGFloat = 0
    /// The thread content's total height (drives `overflowing` and growth detection).
    @State private var contentHeight: CGFloat = 0
    /// The thread content's total height at the last moment we were pinned at the bottom. A taller
    /// value later means content grew (safe to follow); an unchanged value while the bottom marker
    /// moves means the USER scrolled away (never fight it).
    @State private var lastPinnedContentHeight: CGFloat = 0
    /// True while the user is actively dragging the thread. Auto-follow is suspended during the drag
    /// so a token landing mid-gesture can never yank the user back to the bottom.
    @State private var userInteracting = false
    /// True once the thread content is taller than the viewport — the precondition for follow-scrolling.
    @State private var overflowing = false
    @State private var editing: Message?
    @State private var editText = ""
    /// A mid-history regenerate awaiting confirmation (nil = none pending).
    @State private var regenTarget: Message?
    private let bottomID = "thread-bottom"

    private var conversation: Conversation? { chat.activeConversation }
    /// Stable across tokens (only flips at generation start/stop), so reading it here never makes the
    /// whole thread re-diff mid-stream — the live row observes `streaming` on its own.
    private var isBusy: Bool { chat.streamingMessageID != nil }

    var body: some View {
        Group {
            if let convo = conversation, !convo.messages.isEmpty {
                thread(convo)                                  // history first — never hidden by model state
            } else if isLoadingModel {
                centeredOrScrolling { ModelLoadingState(modelName: loadingModelName) }
            } else if !chat.hasModel {
                centeredOrScrolling { NoModelState(onOpenModels: onOpenModels) }
            } else {
                centeredOrScrolling {
                    EmptyChatState(modelName: chat.onlineModelID.map(OnlineModelIdentity.displayLabel)
                                   ?? chat.activeModel?.model.displayName ?? "your model",
                                   onExample: { prompt in
                                       chat.draft = prompt
                                       chat.send()
                                   },
                                   onSwitchModel: onSwitchModel,
                                   activeSkill: chat.activeSkill)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // Tap anywhere in the thread AREA — every branch, including the suggestion/empty states, which
        // live outside the scroll view — to drop the keyboard. Simultaneous, so row buttons still work;
        // the composer is a sibling (safe-area inset), so focusing the field never self-dismisses.
        .simultaneousGesture(TapGesture().onEnded { Self.dismissKeyboard() })
        .sheet(item: $editing) { message in editSheet(message) }
        .alert("Regenerate this reply?",
               isPresented: Binding(get: { regenTarget != nil }, set: { if !$0 { regenTarget = nil } }),
               presenting: regenTarget) { message in
            let n = chat.discardedTurnCount(regeneratingFrom: message.id)
            Button("Discard \(n) later turn\(n == 1 ? "" : "s")", role: .destructive) {
                chat.regenerate(assistantMessageID: message.id)
                regenTarget = nil
            }
            Button("Cancel", role: .cancel) { regenTarget = nil }
        } message: { _ in
            Text("Regenerating an earlier reply removes every turn after it.")
        }
    }

    /// Center a placeholder (empty / loading / no-model) in the available height, but SCROLL instead of
    /// overflowing when that height is tight. With the keyboard up, the composer's safe-area inset shrinks
    /// this area by the keyboard's height; a plain centered VStack that's taller than what's left overflows
    /// symmetrically, and the top half draws OVER the nav bar — the reported "empty-state header on top of
    /// the model name". Pinning the content to at least the viewport height keeps it centered when there's
    /// room and lets it scroll (below the bar, never over it) when there isn't. Dragging also dismisses the
    /// keyboard, so the prompts a lifted keyboard covers are one swipe away.
    @ViewBuilder private func centeredOrScrolling<Content: View>(
        @ViewBuilder _ content: @escaping () -> Content) -> some View {
        GeometryReader { geo in
            ScrollView {
                content().frame(minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.immediately)
        }
    }

    // MARK: Thread

    private func thread(_ convo: Conversation) -> some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                        ForEach(convo.messages) { message in
                            row(message).id(message.id)
                        }
                        if let agentRuns,
                           let run = agentRuns.presentation(for: convo.id),
                           run.needsPanel
                        {
                            AgentRunPanel(store: agentRuns, conversationID: convo.id)
                                .id("agent-run-\(run.runID.description)")
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(bottomID)
                            .background(GeometryReader { geo in
                                Color.clear.preference(key: BottomOffsetKey.self,
                                                       value: geo.frame(in: .named("thread")).maxY)
                            })
                    }
                    .padding(Theme.Space.lg)
                    .frame(maxWidth: Theme.Layout.readingColumn, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
                    })
                }
                .scrollDismissesKeyboard(.interactively)   // drag the thread down to dismiss the keyboard
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { _ in userInteracting = true }
                        .onEnded { _ in
                            userInteracting = false
                            if bottomMaxY > outer.size.height + 40 {
                                atBottom = false
                            }
                        }
                )
                .coordinateSpace(name: "thread")
                .background(Theme.bg)
                .onPreferenceChange(BottomOffsetKey.self) { maxY in
                    bottomMaxY = maxY
                    followIfNeeded(proxy, viewportHeight: outer.size.height)
                }
                .onPreferenceChange(ContentHeightKey.self) { h in
                    contentHeight = h
                    overflowing = h > outer.size.height + 1
                    followIfNeeded(proxy, viewportHeight: outer.size.height)
                }
                .onChange(of: convo.messages.count) { _, _ in scrollToBottom(proxy, animated: false) }
                .onChange(of: chat.activeID) { _, _ in scrollToBottom(proxy, animated: false) }
                .onAppear { scrollToBottom(proxy, animated: false) }
                .overlay(alignment: .bottom) {
                    if !atBottom { scrollPill(proxy) }
                }
            }
        }
    }

    @ViewBuilder private func row(_ message: Message) -> some View {
        if message.role == .user {
            UserBubble(message: message,
                       onEdit: isBusy ? nil : { beginEdit(message) },
                       onCopy: { Clipboard.copy(message.answer); chat.showToast(Toast("Copied")) },
                       attachmentLoader: { await chat.attachmentData($0) })
        } else if message.id == chat.streamingMessageID {
            StreamingRow(chat: chat, displayMode: displayMode,
                         modelName: chat.streaming?.generatedBy?.displayName
                            ?? chat.activeModel?.model.displayName ?? "Model")
        } else {
            AssistantView(
                reasoning: message.reasoning ?? "",
                answer: message.answer,
                disclosurePhase: .answered(seconds: completedThinkSeconds(message)),
                displayMode: displayMode,
                isStreaming: false,
                stats: message.stats,
                modelName: message.generatedBy?.displayName ?? "Model",
                toolRuns: message.toolRuns ?? [],
                emptyOutcome: message.emptyOutcome,
                onCopy: { Clipboard.copy(message.answer); chat.showToast(Toast("Copied")) },
                onRegenerate: isBusy ? nil : { requestRegenerate(message) })
        }
    }

    /// One-tap regenerate for the newest assistant turn; confirm first when regenerating an earlier one
    /// (it silently drops every turn after it — DESIGN §4, no unrecoverable surprise).
    private func requestRegenerate(_ message: Message) {
        guard let convo = conversation else { return }
        if chat.isLastAssistantMessage(message.id, in: convo) {
            chat.regenerate(assistantMessageID: message.id)
        } else {
            regenTarget = message
        }
    }

    /// A completed turn's thinking time — the persisted wall-clock when we have it, else estimated from
    /// stats (older records that predate `thinkingSeconds`).
    private func completedThinkSeconds(_ message: Message) -> Double? {
        if let s = message.thinkingSeconds, s > 0 { return s }
        guard let reasoning = message.reasoning, !reasoning.isEmpty,
              let tps = message.stats?.tokensPerSecond, tps > 0 else { return nil }
        return Double(max(1, reasoning.count / 4)) / tps
    }

    // MARK: Scroll-to-bottom pill

    private func scrollPill(_ proxy: ScrollViewProxy) -> some View {
        Button {
            atBottom = true
            scrollToBottom(proxy)
        } label: {
            Label(isBusy ? "New" : "Latest", systemImage: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.xs)
                .background(Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.bottom, Theme.Space.md)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityLabel("Scroll to latest")
    }

    /// Resign whatever is first responder (the composer field) — SwiftUI has no global "dismiss keyboard",
    /// and threading a FocusState binding up from the composer for one tap isn't worth the coupling.
    static func dismissKeyboard() {
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated && !Motion.reduce {
            withAnimation(Motion.canvas) { proxy.scrollTo(bottomID, anchor: .bottom) }
        } else {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
        // We just pinned the thread; remember the content height so the next preference pass can tell
        // "content grew" (follow again) from "user scrolled away" (leave them alone).
        lastPinnedContentHeight = contentHeight
        atBottom = true
    }

    /// The single follow decision: re-pin the bottom when NEW CONTENT pushed the marker down while the
    /// user was at the bottom, and stay away when the user scrolled. Called from both preference
    /// callbacks. The decision is deferred one runloop turn because the bottom-marker and content-size
    /// preferences land in the SAME layout pass in unspecified order; by the next turn both values are
    /// current, so "content grew" can be told apart from "user scrolled away" deterministically.
    private func followIfNeeded(_ proxy: ScrollViewProxy, viewportHeight: CGFloat) {
        if bottomMaxY <= viewportHeight + 40 {
            atBottom = true
            lastPinnedContentHeight = contentHeight
            return
        }
        guard atBottom, overflowing else {
            atBottom = false
            return
        }
        let contentHeightAtDecision = contentHeight
        let lastPinnedAtDecision = lastPinnedContentHeight
        Task { @MainActor in
            guard !userInteracting else { return }
            if contentHeight > lastPinnedAtDecision + 1 {
                scrollToBottom(proxy, animated: false)
            } else if contentHeight == contentHeightAtDecision {
                // No content change arrived in this pass: the user scrolled away, so stop following.
                atBottom = false
            }
        }
    }

    // MARK: Edit & resend

    private func beginEdit(_ message: Message) {
        editText = message.answer
        editing = message
    }

    private func editSheet(_ message: Message) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text("Editing your message resends it and regenerates the reply.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                TextEditor(text: $editText)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(minHeight: 140)
                    .padding(Theme.Space.sm)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                Spacer()
            }
            .padding(Theme.Space.lg)
            .background(Theme.bg)
            .navigationTitle("Edit message")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editing = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Resend") {
                        chat.editAndResend(userMessageID: message.id, newText: editText)
                        editing = nil
                    }
                    .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 280)
        #endif
    }
}

/// The single live assistant row — the ONLY view that observes the per-token `streaming` state, so the
/// rest of the thread stays put while it types. Reasoning is throttled to the same ~50 ms gate the
/// answer uses.
private struct StreamingRow: View {
    let chat: ChatStore
    let displayMode: ThinkingDisplayMode
    let modelName: String

    @State private var shownReasoning = ""
    @State private var lastReasoningAt = Date.distantPast

    var body: some View {
        Group {
            if let s = chat.streaming {
                if s.phase == .warming && !s.hasAnyContent {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        WarmingShimmer()
                        if let note = s.warmingNote {
                            Text(note).font(.caption).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        AssistantView(
                            reasoning: displayedReasoning(s),
                            answer: s.answer,
                            disclosurePhase: s.phase == .thinking ? .thinking
                                : .answered(seconds: s.thinkingDuration),
                            displayMode: displayMode,
                            isStreaming: true,
                            stats: nil,
                            modelName: modelName,
                            toolRuns: s.toolActivity)
                        if let note = s.warmingNote {
                            HStack(spacing: Theme.Space.xs) {
                                ProgressView().controlSize(.small)
                                Text(note)
                            }
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
        .onAppear { shownReasoning = chat.streaming?.reasoning ?? "" }
        .onChange(of: chat.streaming?.reasoning ?? "") { _, new in
            let now = Date()
            if now.timeIntervalSince(lastReasoningAt) >= 0.05 || new.count - shownReasoning.count > 24 {
                shownReasoning = new
                lastReasoningAt = now
            }
        }
    }

    /// Throttled while thinking; the full text once thinking ends, so the frozen block is exact.
    private func displayedReasoning(_ s: StreamingState) -> String {
        s.phase == .thinking ? shownReasoning : s.reasoning
    }
}

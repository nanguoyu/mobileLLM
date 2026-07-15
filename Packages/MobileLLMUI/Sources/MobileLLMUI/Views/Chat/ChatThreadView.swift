// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import LLMCore

/// Tracks the bottom anchor's position in the scroll's coordinate space so we can detect "scrolled
/// away" (for the scroll-to-bottom pill) and sticky-bottom autoscroll on iOS 17 / macOS 14.
private struct BottomOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The message list + streaming surface (DESIGN §4). User turns are right-aligned bubbles; assistant
/// turns are full-width document text. Sticky-bottom autoscroll with a "⌄ new" pill when scrolled
/// away; warming shimmer before the first token.
struct ChatThreadView: View {
    @Bindable var chat: ChatStore
    let displayMode: ThinkingDisplayMode
    var onOpenModels: () -> Void

    @State private var atBottom = true
    @State private var editing: Message?
    @State private var editText = ""
    private let bottomID = "thread-bottom"

    private var conversation: Conversation? { chat.activeConversation }

    var body: some View {
        Group {
            if !chat.hasModel {
                NoModelState(onOpenModels: onOpenModels)
            } else if let convo = conversation, !convo.messages.isEmpty {
                thread(convo)
            } else {
                EmptyChatState(modelName: chat.activeModel?.model.displayName ?? "your model") { prompt in
                    chat.draft = prompt
                    chat.send()
                }
            }
        }
        .sheet(item: $editing) { message in editSheet(message) }
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
                        Color.clear
                            .frame(height: 1)
                            .id(bottomID)
                            .background(GeometryReader { geo in
                                Color.clear.preference(key: BottomOffsetKey.self,
                                                       value: geo.frame(in: .named("thread")).maxY)
                            })
                    }
                    .padding(Theme.Space.lg)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)   // drag the thread down to dismiss the keyboard
                .coordinateSpace(name: "thread")
                .background(Theme.bg)
                .onPreferenceChange(BottomOffsetKey.self) { maxY in
                    atBottom = maxY <= outer.size.height + 40
                }
                .onChange(of: streamSignature) { _, _ in
                    if atBottom { scrollToBottom(proxy) }
                }
                .onChange(of: chat.activeID) { _, _ in scrollToBottom(proxy, animated: false) }
                .onAppear { scrollToBottom(proxy, animated: false) }
                .overlay(alignment: .bottom) {
                    if !atBottom { scrollPill(proxy) }
                }
            }
        }
    }

    /// Changes whenever the visible content grows — drives sticky-bottom autoscroll.
    private var streamSignature: Int {
        (conversation?.messages.count ?? 0)
            &+ (chat.streaming?.answer.count ?? 0)
            &+ (chat.streaming?.reasoning.count ?? 0)
    }

    @ViewBuilder private func row(_ message: Message) -> some View {
        if message.role == .user {
            UserBubble(message: message,
                       onEdit: chat.isStreaming ? nil : { beginEdit(message) },
                       onCopy: { Clipboard.copy(message.answer); chat.showToast(Toast("Copied")) })
        } else if let streaming = chat.streaming, streaming.messageID == message.id {
            streamingAssistant(streaming)
        } else {
            AssistantView(
                reasoning: message.reasoning ?? "",
                answer: message.answer,
                disclosurePhase: .answered(seconds: completedThinkSeconds(message)),
                displayMode: displayMode,
                isStreaming: false,
                stats: message.stats,
                modelName: chat.activeModel?.model.displayName ?? "Model",
                onCopy: { Clipboard.copy(message.answer); chat.showToast(Toast("Copied")) },
                onRegenerate: chat.isStreaming ? nil : { chat.regenerate(assistantMessageID: message.id) })
        }
    }

    @ViewBuilder private func streamingAssistant(_ streaming: StreamingState) -> some View {
        if streaming.phase == .warming && !streaming.hasAnyContent {
            WarmingShimmer().frame(maxWidth: .infinity, alignment: .leading)
        } else {
            AssistantView(
                reasoning: streaming.reasoning,
                answer: streaming.answer,
                disclosurePhase: streaming.phase == .thinking ? .thinking
                    : .answered(seconds: streaming.thinkingDuration),
                displayMode: displayMode,
                isStreaming: true,
                stats: nil,
                modelName: chat.activeModel?.model.displayName ?? "Model")
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
            Label(chat.isStreaming ? "New" : "Latest", systemImage: "chevron.down")
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

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated && !Motion.reduce {
            withAnimation(Motion.canvas) { proxy.scrollTo(bottomID, anchor: .bottom) }
        } else {
            proxy.scrollTo(bottomID, anchor: .bottom)
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

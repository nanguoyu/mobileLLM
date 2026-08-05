// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import LLMCore

/// One conversation surface: the message thread + the composer, with a header that surfaces the
/// active model as a tap-target to the quick switcher (DESIGN §4).
struct ChatDetailView: View {
    let container: AppContainer
    var onOpenModels: () -> Void
    @State private var showSwitcher = false
    @State private var showTools = false
    @State private var showConversationSettings = false
    /// Net keyboard lift from UIKit's keyboardLayoutGuide (see KeyboardHeight.swift): 0 when hidden,
    /// keyboard height minus the home-indicator inset when up. Automatic avoidance is disabled below.
    @State private var keyboardOverlap: CGFloat = 0

    private var chat: ChatStore { container.chat }

    /// Best-effort name of the model currently loading — the active model if we have it, else the default
    /// (the cold-start case the loading state exists for).
    private var loadingModelName: String {
        chat.activeModel?.model.displayName
            ?? LLMCatalog.model(id: container.settings.defaultModelID)?.displayName
            ?? "your model"
    }

    var body: some View {
        // The composer's lift above the keyboard is OURS to compute, from the same primitive FlowDown
        // constrains against: UIKit's keyboardLayoutGuide. The reader reports the NET lift (0 at rest,
        // keyboard height minus the home-indicator inset when up), measured entirely in UIKit — SwiftUI's
        // own safeAreaInsets absorbs the keyboard into its bottom value while its avoidance does nothing,
        // which is both why this tree needed manual handling and why the subtraction must not use it.
        // Automatic avoidance stays OFF so nothing ever double-lifts.
        ChatThreadView(chat: container.chat,
                       displayMode: container.settings.thinkingDisplay,
                       isLoadingModel: container.models.switching,
                       loadingModelName: loadingModelName,
                       onOpenModels: onOpenModels,
                       onSwitchModel: { showSwitcher = true },
                       agentRuns: container.agentRuns)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    // The approval/question bar docks ABOVE the settings row: when it appears, the
                    // effort/approval row and composer stay anchored to the bottom instead of being
                    // pushed upward by the card.
                    if let agentRuns = container.agentRuns,
                       let activeID = container.chat.activeID
                    {
                        AgentDockedBar(store: agentRuns, conversationID: activeID)
                    }
                    ConversationModeBar(chat: container.chat)
                    Composer(chat: container.chat,
                             settings: container.settings,
                             // Online reasoning is per-conversation (the composer toggle persists a thread
                             // override, defaulting to the global Thinking default), so the control is
                             // available for both local and online models.
                             thinkingCapable: chat.isOnlineActive
                                || (chat.activeModel?.model.architecture.thinkingCapable ?? true),
                             canAttachImages: container.models.activeSupportsImageInput,
                             isLoadingModel: container.models.switching,
                             onOpenModels: onOpenModels,
                             toolEventStore: container.toolEventStore,
                             toolLocationProvider: container.toolLocationProvider,
                             onOpenToolSettings: { showTools = true })
                }
                    .padding(.bottom, keyboardOverlap)
            }
            #if os(iOS)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .background { KeyboardGuideReader(overlap: $keyboardOverlap) }
            #endif
        .background(Theme.bg)
        // NO `.navigationTitle` here on purpose. The header IS the `.principal` toolbar item (the model
        // name) below. Setting a title as well gives the inline bar TWO title sources: iOS is meant to
        // suppress the title text when a principal item is present, but a relayout — the keyboard showing
        // is one — makes the suppressed title surface and render ON TOP of the model name. The report was
        // exactly that: two lines of text overlapping in the nav bar once the keyboard came up. One header,
        // one source. (The back button on this screen is labelled by the conversation LIST's title, not
        // this one's, so dropping it costs nothing there.)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // The tab bar is why the input row kept sinking: keyboard avoidance lifts the composer by the
        // keyboard's window overlap, but the composer already sat a tab-bar-height above the window
        // bottom — every layout variant came up exactly ~50pt short. A pushed conversation hides the
        // tab bar (standard chat behavior, and the thread gains the row of space).
        .toolbar(.hidden, for: .tabBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) { modelHeader }
            ToolbarItem(placement: .primaryAction) {
                Button { showConversationSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Conversation settings")
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
        .sheet(isPresented: $showSwitcher) {
            ModelSwitcherSheet(container: container, onOpenModels: onOpenModels)
        }
        .sheet(isPresented: $showTools) {
            NavigationStack {
                ToolsView(settings: container.settings,
                          eventStore: container.toolEventStore,
                          locationProvider: container.toolLocationProvider)
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 560)
            #endif
        }
        .sheet(isPresented: $showConversationSettings) {
            ConversationSettingsView(container: container)
        }
        // Entering a conversation restores ITS model even when a platform-specific navigation path did
        // not route through select(). Cold launch itself leaves history unselected.
        .onAppear { chat.restoreConversationModelIfNeeded() }
        // Neutral recovery: list recoverable runs, and only when the user explicitly opens this thread
        // reattach to its pending run — still without resuming it (spec §9.4).
        .task {
            await chat.recoverAgentRuns()
            guard let recoverable = chat.agentRuns?.recoverableRuns.first(where: {
                $0.conversationID == chat.activeID
            }) else { return }
            await chat.reopenAgentRun(recoverable)
        }
        // Leaving the conversation frees the model's memory (reloaded lazily on the next turn), so a
        // 5 GB model doesn't sit resident while you're not chatting. No-op mid-generation.
        .onDisappear { container.suspendModel() }
    }

    private var modelHeader: some View {
        Button { showSwitcher = true } label: {
            HStack(spacing: 4) {
                Circle().fill(chat.hasModel ? Theme.fitGreen : Theme.fitGray).frame(width: 6, height: 6)
                Text(chat.activeModelLabel)
                    .font(.caption.weight(.medium)).foregroundStyle(Theme.textSecondary)
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(Theme.textTertiary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Active model")
        .accessibilityValue(chat.activeModel?.subtitle ?? "No model loaded")
        .accessibilityHint("Switch model")
    }
}

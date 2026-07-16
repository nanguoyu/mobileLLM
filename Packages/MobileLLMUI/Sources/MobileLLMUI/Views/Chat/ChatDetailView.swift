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

    private var chat: ChatStore { container.chat }

    /// Best-effort name of the model currently loading — the active model if we have it, else the default
    /// (the cold-start case the loading state exists for).
    private var loadingModelName: String {
        chat.activeModel?.model.displayName
            ?? LLMCatalog.model(id: container.settings.defaultModelID)?.displayName
            ?? "your model"
    }

    var body: some View {
        VStack(spacing: 0) {
            ChatThreadView(chat: container.chat,
                           displayMode: container.settings.thinkingDisplay,
                           isLoadingModel: container.models.switching,
                           loadingModelName: loadingModelName,
                           onOpenModels: onOpenModels)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Composer(chat: container.chat,
                     thinkingCapable: chat.activeModel?.model.architecture.thinkingCapable ?? true,
                     canAttachImages: container.models.activeSupportsImageInput,
                     isLoadingModel: container.models.switching,
                     onOpenModels: onOpenModels)
        }
        .background(Theme.bg)
        .navigationTitle(chat.activeConversation?.title ?? "New Chat")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) { modelHeader }
            ToolbarItem(placement: .primaryAction) {
                Button { chat.newConversation() } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("New chat")
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        .sheet(isPresented: $showSwitcher) {
            ModelSwitcherSheet(container: container, onOpenModels: onOpenModels)
        }
        // Leaving the conversation frees the model's memory (reloaded lazily on the next turn), so a
        // 5 GB model doesn't sit resident while you're not chatting. No-op mid-generation.
        .onDisappear { container.suspendModel() }
    }

    private var modelHeader: some View {
        Button { showSwitcher = true } label: {
            HStack(spacing: 4) {
                Circle().fill(chat.hasModel ? Theme.fitGreen : Theme.fitGray).frame(width: 6, height: 6)
                Text(chat.activeModel?.subtitle ?? "No model")
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

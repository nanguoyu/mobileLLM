// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AppUI

extension AppearanceMode {
    /// The SwiftUI scheme to force (nil = follow the system).
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// The three top-level sections (DESIGN §4 IA).
enum AppSection: String, CaseIterable, Identifiable {
    case chat, models, settings
    var id: String { rawValue }
    var title: String {
        switch self { case .chat: "Chat"; case .models: "Models"; case .settings: "Settings" }
    }
    var icon: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .models: "square.stack.3d.up"
        case .settings: "gearshape"
        }
    }
}

/// The app shell (DESIGN §4): iOS TabView (Chat / Models / Settings), macOS NavigationSplitView
/// (sidebar list + thread). Teal tint, appearance override, and the shared banner host. Bootstraps
/// persisted chats + install state, then auto-activates the default model.
public struct RootView: View {
    @Bindable var container: AppContainer
    @State private var section: AppSection = .chat

    public init(container: AppContainer) {
        self.container = container
    }

    public var body: some View {
        shell
            .tint(Theme.accent)
            .background(Theme.bg)
            .preferredColorScheme(container.settings.appearance.colorScheme)
            .bannerHost(container.chat)
            .task { await container.bootstrap() }
    }

    @ViewBuilder private var shell: some View {
        #if os(macOS)
        macShell
        #else
        iosShell
        #endif
    }

    // MARK: iOS

    #if !os(macOS)
    private var iosShell: some View {
        TabView {
            NavigationStack {
                ConversationListView(chat: container.chat) { _ in }
                    .navigationTitle("Chat")
                    .navigationDestination(isPresented: hasActive) {
                        ChatDetailView(container: container, onOpenModels: { section = .models })
                    }
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button { container.chat.newConversation() } label: { Image(systemName: "square.and.pencil") }
                                .accessibilityLabel("New chat")
                        }
                    }
            }
            .tabItem { Label("Chat", systemImage: AppSection.chat.icon) }

            NavigationStack {
                ModelsView(models: container.models, settings: container.settings) { model, variant, force in
                    container.activate(model, variant: variant, force: force)
                }
                .navigationTitle("Models")
            }
            .tabItem { Label("Models", systemImage: AppSection.models.icon) }

            NavigationStack {
                SettingsView(container: container).navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: AppSection.settings.icon) }
        }
    }

    /// Drives the push to the thread when a conversation is active.
    private var hasActive: Binding<Bool> {
        Binding(get: { container.chat.activeID != nil },
                set: { if !$0 { container.chat.activeID = nil } })
    }
    #endif

    // MARK: macOS

    #if os(macOS)
    private var macShell: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                if section == .chat {
                    ConversationListView(chat: container.chat) { _ in section = .chat }
                } else {
                    Spacer()
                }
                Divider().background(Theme.hairline)
                sidebarFooter
            }
            .frame(minWidth: 240)
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            .toolbar {
                ToolbarItem {
                    Button { section = .chat; container.chat.newConversation() } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .help("New chat")
                    .keyboardShortcut("n", modifiers: .command)
                }
            }
        } detail: {
            detail.frame(minWidth: 520, minHeight: 480)
        }
    }

    private var sidebarFooter: some View {
        HStack(spacing: Theme.Space.sm) {
            footerButton(.models)
            footerButton(.settings)
            Spacer()
        }
        .padding(Theme.Space.sm)
    }

    private func footerButton(_ target: AppSection) -> some View {
        Button { section = target } label: {
            Label(target.title, systemImage: target.icon)
                .font(.callout)
                .foregroundStyle(section == target ? Theme.accent : Theme.textSecondary)
                .padding(.horizontal, Theme.Space.sm).padding(.vertical, 6)
                .background(section == target ? Theme.accentSoft : .clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var detail: some View {
        switch section {
        case .chat:
            ChatDetailView(container: container, onOpenModels: { section = .models })
        case .models:
            ModelsView(models: container.models, settings: container.settings) { model, variant, force in
                container.activate(model, variant: variant, force: force)
            }
            .navigationTitle("Models")
        case .settings:
            SettingsView(container: container).navigationTitle("Settings")
        }
    }
    #endif
}

#if DEBUG
#Preview("Root") {
    RootView(container: AppContainer.preview())
}
#endif

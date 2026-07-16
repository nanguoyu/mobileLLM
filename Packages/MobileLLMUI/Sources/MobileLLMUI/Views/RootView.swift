// SPDX-License-Identifier: MIT

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

/// The app shell (DESIGN §4): a compact iPhone uses a TabView (Chat / Models / Settings); an iPad
/// (regular width) and macOS use a NavigationSplitView (sidebar list + thread), so the iPad isn't just a
/// stretched phone. Accent tint, appearance override, and the shared banner host. Bootstraps persisted
/// chats + install state, then auto-activates the default model.
public struct RootView: View {
    @Bindable var container: AppContainer
    @State private var section: AppSection = .chat
    #if !os(macOS)
    @Environment(\.horizontalSizeClass) private var hSize
    #endif

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
            // A navigation intent from the container (e.g. a "not installed" banner's "Open Models") drives
            // the shell's section; clear it once honored so it fires once.
            .onChange(of: container.navigationRequest) { _, request in
                guard let request else { return }
                section = request
                container.navigationRequest = nil
            }
    }

    @ViewBuilder private var shell: some View {
        #if os(macOS)
        splitShell
        #else
        // iPad (regular width) is a real two-column app, not a stretched iPhone; the phone stays a TabView.
        if hSize == .regular { splitShell } else { tabShell }
        #endif
    }

    // MARK: Compact (iPhone) — TabView

    #if !os(macOS)
    private var tabShell: some View {
        // `selection` is bound so a navigation intent can switch tabs programmatically.
        TabView(selection: $section) {
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
            .tag(AppSection.chat)
            .tabItem { Label("Chat", systemImage: AppSection.chat.icon) }

            NavigationStack {
                ModelsView(models: container.models, settings: container.settings) { model, variant, force in
                    container.activate(model, variant: variant, force: force)
                }
                .navigationTitle("Models")
            }
            .tag(AppSection.models)
            .tabItem { Label("Models", systemImage: AppSection.models.icon) }

            NavigationStack {
                SettingsView(container: container).navigationTitle("Settings")
            }
            .tag(AppSection.settings)
            .tabItem { Label("Settings", systemImage: AppSection.settings.icon) }
        }
    }

    /// Drives the push to the thread when a conversation is active.
    private var hasActive: Binding<Bool> {
        Binding(get: { container.chat.activeID != nil },
                set: { if !$0 { container.chat.activeID = nil } })
    }
    #endif

    // MARK: Regular (iPad + macOS) — NavigationSplitView

    private var splitShell: some View {
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
                    // On macOS the New Chat command (⌘N) lives in the menu bar; on iPad the toolbar owns it.
                    #if !os(macOS)
                    .keyboardShortcut("n", modifiers: .command)
                    #endif
                }
            }
        } detail: {
            detail.frame(minWidth: 520, minHeight: 480)
        }
        // The Switch-Model menu command (⌘L) opens the quick switcher over the split shell.
        .sheet(isPresented: switcherBinding) {
            ModelSwitcherSheet(container: container, onOpenModels: { section = .models })
        }
    }

    private var switcherBinding: Binding<Bool> {
        Binding(get: { container.switcherRequested }, set: { container.switcherRequested = $0 })
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
}

#if DEBUG
#Preview("Root") {
    RootView(container: AppContainer.preview())
}
#endif

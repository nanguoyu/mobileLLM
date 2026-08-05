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
/// stretched phone. Accent tint, appearance override, and the shared banner host. Bootstraps the
/// conversation list + install state without selecting history, then restores only the default model
/// identity without loading its weights.
public struct RootView: View {
    @Bindable var container: AppContainer
    @State private var section: AppSection = .chat
    #if os(macOS)
    @State private var hoveredSidebarSection: AppSection?
    #endif
    #if !os(macOS)
    @Environment(\.horizontalSizeClass) private var hSize
    #endif

    public init(container: AppContainer, initialSection: AppSection = .chat) {
        self.container = container
        _section = State(initialValue: initialSection)
    }

    public var body: some View {
        shell
            .tint(Theme.accent)
            .background(Theme.bg)
            #if os(macOS)
            // NavigationSplitView otherwise lets the detail title bar fall back to AppKit's cold grey
            // toolbar material while the app uses warm rice-paper everywhere else. Make the complete
            // unified window toolbar part of the same adaptive palette (light and dark).
            .toolbarBackground(Theme.bg, for: .windowToolbar)
            // Keep the macOS 14 deployment target; the renamed visibility spelling starts in macOS 15.
            .toolbarBackground(.visible, for: .windowToolbar)
            #endif
            .preferredColorScheme(container.settings.appearance.colorScheme)
            .bannerHost(container.chat)
            .task { await container.bootstrap() }
            // Neutral launch inbox: discover pending runs without loading a model, selecting a
            // conversation, or resuming anything (spec §9.4 / §20).
            .task { await container.chat.recoverAgentRuns() }
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
                ConversationListView(
                    chat: container.chat,
                    onSelect: { _ in },
                    agentRuns: container.agentRuns
                )
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
                ModelsView(models: container.models, settings: container.settings) { model, variant in
                    container.activate(model, variant: variant)
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
                #if os(macOS)
                // A Mac sidebar stays useful while Models or Settings is open: conversation rows remain
                // visible and selecting one returns to Chat. This avoids the empty-sidebar dead end where
                // New Chat (which mutates data) was previously the only route back.
                ConversationListView(chat: container.chat,
                                     showsActiveSelection: section == .chat,
                                     onSelect: { _ in section = .chat },
                                     agentRuns: container.agentRuns)
                #else
                if section == .chat {
                    ConversationListView(
                        chat: container.chat,
                        onSelect: { _ in section = .chat },
                        agentRuns: container.agentRuns
                    )
                } else {
                    Spacer()
                }
                #endif
                Divider().background(Theme.hairline)
                sidebarFooter
            }
            // Keep the sidebar's paper surface stable while switching sections. Without an explicit
            // background, Models and Settings exposed the system split-view material while Chat painted
            // its own background, making one sidebar alternate between beige and grey.
            #if os(macOS)
            .background(Theme.bg.ignoresSafeArea())
            #endif
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

    @ViewBuilder
    private var sidebarFooter: some View {
        #if os(macOS)
        // Mac sidebars read as vertical lists, not tab bars. Full-width rows give each destination a
        // generous hit target and use the same cinnabar selection tint as the rest of the app.
        VStack(spacing: 2) {
            macSidebarButton(.models)
            macSidebarButton(.settings)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(Theme.bg)
        #else
        HStack(spacing: Theme.Space.sm) {
            footerButton(.models)
            footerButton(.settings)
            Spacer()
        }
        .padding(Theme.Space.sm)
        #endif
    }

    #if os(macOS)
    private func macSidebarButton(_ target: AppSection) -> some View {
        let isSelected = section == target
        let isHovered = hoveredSidebarSection == target

        return Button { section = target } label: {
            HStack(spacing: 9) {
                Image(systemName: target.icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                Text(target.title)
                    .font(.callout)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Theme.onAccent : Theme.textPrimary)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Theme.accent : (isHovered ? Theme.surface2 : .clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredSidebarSection = target
            } else if hoveredSidebarSection == target {
                hoveredSidebarSection = nil
            }
        }
        .accessibilityLabel(target.title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("sidebar-navigation-\(target.rawValue)")
        .help(target.title)
    }
    #else
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
    #endif

    @ViewBuilder private var detail: some View {
        switch section {
        case .chat:
            // The split detail needs its own stack so the ••• menu's data pages can Push (spec §20).
            NavigationStack {
                ChatDetailView(container: container, onOpenModels: { section = .models })
            }
        case .models:
            ModelsView(models: container.models, settings: container.settings) { model, variant in
                container.activate(model, variant: variant)
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

// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import LLMCore
#if canImport(UIKit)
import UIKit
#endif

/// Settings → Behavior → Manage tools. The built-in tool suite the model may call when Tools are on:
/// which search engines web search scrapes, per-tool on/off (with the privacy-sensitive three clearly
/// marked as permission-gated), and a link into the MCP servers screen. Everything here persists into
/// `AppSettings` (`disabledBuiltInTools` + `searchEngines`) and takes effect on the next send via
/// `ChatStore.toolRegistry()`.
struct ToolsView: View {
    @Bindable var settings: AppSettings
    /// The privacy-gated seams (nil in previews/tests): enabling calendar/reminders/location asks the
    /// system RIGHT THEN — the user is at their own decision point, not mid-chat — and a system-level
    /// denial routes to Settings instead of silently arming a tool that can only fail.
    var eventStore: (any EventStoring)? = nil
    var locationProvider: (any LocationProviding)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var showMCP = false
    /// Which privacy row's "allowed it off in system Settings" alert is up (nil = none).
    @State private var deniedRow: BuiltInToolRow?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                searchEnginesSection
                builtInSection
                connectionsSection
            }
            .frame(maxWidth: Theme.Layout.form, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(Theme.Space.xl)
        }
        .background(Theme.bg)
        .navigationTitle("Tools")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        // A sheet, not a push: matches Settings (whose macOS detail column isn't in a NavigationStack).
        .sheet(isPresented: $showMCP) {
            NavigationStack { MCPServersView(settings: settings) }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 560)
            #endif
        }
        .alert(deniedRow.map { "\($0.title) access is off" } ?? "",
               isPresented: Binding(get: { deniedRow != nil }, set: { if !$0 { deniedRow = nil } }),
               presenting: deniedRow) { _ in
            Button("Open Settings") { openSystemSettings(); deniedRow = nil }
            Button("Not now", role: .cancel) { deniedRow = nil }
        } message: { row in
            Text("\(row.title) is turned off for mobileLLM in system Settings. The tool stays enabled "
                 + "here, but the model's calls will fail until you allow access.")
        }
    }

    // MARK: Search engines

    private var searchEnginesSection: some View {
        section("Search engines", icon: "magnifyingglass") {
            engineToggle("DuckDuckGo", .duckduckgo)
            Divider().background(Theme.hairline)
            engineToggle("Bing", .bing)
            Text(searchFootnote).font(.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func engineToggle(_ name: String, _ engine: SearchEngine) -> some View {
        Toggle(isOn: engineBinding(engine)) {
            Text(name).font(.subheadline).foregroundStyle(Theme.textPrimary)
        }
        .tint(Theme.accent)
        .disabled(!webSearchOn)
        .opacity(webSearchOn ? 1 : 0.5)
    }

    /// Web search is enabled iff the `web_search` tool isn't in the disabled set.
    private var webSearchOn: Bool { !settings.disabledBuiltInTools.contains(ToolID.webSearch.rawValue) }

    private var searchFootnote: String {
        webSearchOn
            ? "Web search reads these engines' public results pages directly (no API key), tries them in "
              + "order, and hands the model the top links. Keep at least one on."
            : "Turn on the Web search tool below to use these engines."
    }

    /// Add/remove an engine while preserving the canonical priority order, and never removing the last one
    /// (the tool needs at least one; an empty list would silently fall back to both).
    private func engineBinding(_ engine: SearchEngine) -> Binding<Bool> {
        Binding(
            get: { settings.searchEngines.contains(engine) },
            set: { on in
                var chosen = Set(settings.searchEngines)
                if on {
                    chosen.insert(engine)
                } else {
                    guard chosen.count > 1 else { return }   // at least one engine required
                    chosen.remove(engine)
                }
                settings.searchEngines = SearchEngine.allCases.filter { chosen.contains($0) }
            })
    }

    // MARK: Built-in tools

    private var builtInSection: some View {
        section("Built-in tools", icon: "wrench.and.screwdriver") {
            ForEach(Array(BuiltInToolRow.all.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().background(Theme.hairline) }
                toolRow(row)
            }
        }
    }

    private func toolRow(_ row: BuiltInToolRow) -> some View {
        Toggle(isOn: rowBinding(row)) {
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                Image(systemName: row.icon)
                    .font(.subheadline).foregroundStyle(Theme.accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.subheadline).foregroundStyle(Theme.textPrimary)
                    Text(row.subtitle).font(.caption).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if row.privacy {
                        Label("Asks for system permission when you enable it.",
                              systemImage: "lock.shield")
                            .font(.caption2).foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .tint(Theme.accent)
    }

    /// A row is on when NONE of its underlying tool ids are disabled; toggling flips them all together
    /// (so "Memory" moves remember + recall, "Calendar" moves create + list, as one switch). Enabling a
    /// privacy row immediately runs the system permission flow.
    private func rowBinding(_ row: BuiltInToolRow) -> Binding<Bool> {
        Binding(
            get: { row.isOn(in: settings) },
            set: { on in
                var disabled = settings.disabledBuiltInTools
                for id in row.toolIDs {
                    if on { disabled.remove(id.rawValue) } else { disabled.insert(id.rawValue) }
                }
                settings.disabledBuiltInTools = disabled
                if on, row.privacy { Task { await requestSystemPermission(for: row) } }
            })
    }

    /// Ask the system for the row's permission the moment it's enabled. Undetermined → the real prompt;
    /// already denied in system Settings → iOS can't re-prompt, so surface the alert that deep-links
    /// there. The toggle itself stays on either way (the user's intent is recorded; a denied tool call
    /// returns an instructive error until access is granted).
    private func requestSystemPermission(for row: BuiltInToolRow) async {
        let result: ToolPermission?
        switch row.id {
        case "calendar": result = await eventStore?.requestPermission(for: .events)
        case "reminders": result = await eventStore?.requestPermission(for: .reminders)
        case "location": result = await locationProvider?.requestPermission()
        default: result = nil
        }
        if result == .denied { deniedRow = row }
    }

    /// Deep-link to the app's page in system Settings — the only path once a permission is denied.
    private func openSystemSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #elseif os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    // MARK: Connections

    private var connectionsSection: some View {
        section("Connections", icon: "point.3.connected.trianglepath.dotted") {
            Button { showMCP = true } label: {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.subheadline).foregroundStyle(Theme.accent).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MCP servers").font(.subheadline).foregroundStyle(Theme.textPrimary)
                        Text(mcpSummary).font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: Theme.Space.sm)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var mcpSummary: String {
        let all = settings.mcpServers
        guard !all.isEmpty else { return "Connect a remote server for more tools" }
        let on = all.count(where: \.isEnabled)
        return "\(all.count) configured" + (on < all.count ? " · \(all.count - on) off" : "")
    }

    // MARK: Builders

    private func section(_ title: String, icon: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Label { Text(title.uppercased()) } icon: { Image(systemName: icon) }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: Theme.Space.md) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .studioCard()
        }
    }
}

extension ToolsView {
    /// One-line status for the Settings → "Manage tools" row: how many built-in tools are on, plus any
    /// enabled MCP servers. Static so `SettingsView` can render it without owning the row model.
    @MainActor static func summary(for settings: AppSettings) -> String {
        let total = BuiltInToolRow.all.count
        let on = BuiltInToolRow.all.count(where: { $0.isOn(in: settings) })
        var text = "\(on) of \(total) built-in tools on"
        let servers = settings.mcpServers.count(where: \.isEnabled)
        if servers > 0 { text += " · \(servers) MCP server\(servers == 1 ? "" : "s")" }
        return text
    }
}

/// One toggle row in the Tools screen. Maps a user-facing tool to the one-or-more `ToolID`s it controls —
/// "Memory" is remember + recall, "Calendar" is create + list — so a single switch enables or disables the
/// whole capability. `privacy` marks the three TCC-gated tools that prompt for system access on first use.
struct BuiltInToolRow: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let toolIDs: [ToolID]
    var privacy = false

    /// On when every underlying tool id is enabled (i.e. none are in the disabled set) — all-or-nothing,
    /// so a multi-id row never sits half-on.
    @MainActor func isOn(in settings: AppSettings) -> Bool {
        toolIDs.allSatisfy { !settings.disabledBuiltInTools.contains($0.rawValue) }
    }

    /// The rows, in display order. The privacy-sensitive three come last, grouped and marked.
    static let all: [BuiltInToolRow] = [
        .init(id: "web_search", title: "Web search",
              subtitle: "Search the live web for current info.",
              icon: "magnifyingglass", toolIDs: [.webSearch]),
        .init(id: "fetch_webpage", title: "Webpage reader",
              subtitle: "Open a link and read its main text.",
              icon: "doc.text.magnifyingglass", toolIDs: [.fetchWebpage]),
        .init(id: "wikipedia", title: "Wikipedia",
              subtitle: "Look up a topic on Wikipedia.",
              icon: "character.book.closed", toolIDs: [.wikipedia]),
        .init(id: "calculator", title: "Calculator",
              subtitle: "Do arithmetic on-device.",
              icon: "function", toolIDs: [.calculator]),
        .init(id: "clock", title: "Clock",
              subtitle: "Check the current date and time.",
              icon: "clock", toolIDs: [.currentDatetime]),
        // The switch, and only the switch: what's actually remembered is reviewed, corrected, and added to
        // in Settings → Behavior → Memory. This row points there rather than implying a toggle is the
        // whole feature — which is exactly how memory used to stay invisible.
        .init(id: "memory", title: "Memory",
              subtitle: "Remember details you share and use them later. See and edit what's saved in "
                      + "Settings → Memory.",
              icon: "bookmark", toolIDs: [.remember, .recall]),
        .init(id: "calendar", title: "Calendar",
              subtitle: "Add events and read what's on your calendar.",
              icon: "calendar", toolIDs: [.createCalendarEvent, .listCalendarEvents], privacy: true),
        .init(id: "reminders", title: "Reminders",
              subtitle: "Create reminders in the Reminders app.",
              icon: "checklist", toolIDs: [.createReminder], privacy: true),
        .init(id: "location", title: "Location",
              subtitle: "Use your approximate (city-level) location.",
              icon: "location", toolIDs: [.currentLocation], privacy: true),
    ]
}

#if DEBUG
#Preview("Tools") {
    NavigationStack { ToolsView(settings: AppContainer.preview().settings) }
        .tint(Theme.accent)
}
#endif

// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import LLMCore

/// Live connection state for one configured server. Probing is the whole point of this screen: an MCP
/// server is a URL a user typed, so "did it work, and what did it give me?" is the only question worth
/// answering — a row that just echoes the URL back tells you nothing you didn't type.
@MainActor
@Observable
final class MCPProbe {
    enum Status: Equatable {
        case idle, checking
        case ok([MCPToolSpec])
        case failed(String)
    }

    private(set) var status: [String: Status] = [:]
    private var inFlight: [String: Task<Void, Never>] = [:]

    func status(for server: MCPServer) -> Status { status[server.id] ?? .idle }

    func tools(for server: MCPServer) -> [MCPToolSpec] {
        if case .ok(let tools) = status(for: server) { return tools }
        return []
    }

    /// Connect + list tools. Re-probing a server cancels the previous attempt for it.
    func probe(_ server: MCPServer, force: Bool = false) {
        if !force, case .ok = status(for: server) { return }
        inFlight[server.id]?.cancel()
        status[server.id] = .checking
        inFlight[server.id] = Task { [weak self] in
            let client = MCPClient(server: server)
            do {
                let tools = try await client.connect()
                guard !Task.isCancelled else { return }
                self?.status[server.id] = .ok(tools)
            } catch {
                guard !Task.isCancelled else { return }
                self?.status[server.id] = .failed(Self.describe(error))
            }
        }
    }

    func forget(_ server: MCPServer) {
        inFlight[server.id]?.cancel()
        inFlight[server.id] = nil
        status[server.id] = nil
    }

    /// A message the user can act on — `error.localizedDescription` on a URLError is famously vague.
    static func describe(_ error: Error) -> String {
        if let mcp = error as? MCPClient.MCPError {
            switch mcp {
            case .badURL: return "That URL isn't valid."
            case .http(401), .http(403): return "Rejected the token (HTTP 401/403)."
            case .http(404): return "No MCP endpoint at that path (HTTP 404)."
            case .http(let code): return "Server returned HTTP \(code)."
            case .rpc(let msg): return msg
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet: return "No internet connection."
            case .timedOut: return "Timed out."
            case .cannotFindHost: return "Can't find that host."
            case .appTransportSecurityRequiresSecureConnection:
                return "iOS blocks plain http:// — the server must be https://."
            default: return url.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

// MARK: - Servers list

/// Settings → Tools → MCP servers. A managed list rather than a text field: connect, see what each
/// server actually offers, and mute individual tools — a server that advertises 30 tools will bury a
/// small model, so per-tool control is a correctness feature, not a nicety.
struct MCPServersView: View {
    @Bindable var settings: AppSettings
    @State private var probe = MCPProbe()
    @State private var showAdd = false
    @State private var editing: MCPServer?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text("Model Context Protocol servers extend the model with tools you host or subscribe to. "
                     + "They're contacted only while a chat is generating with Tools on.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)

                if settings.mcpServers.isEmpty {
                    emptyState
                } else {
                    ForEach(settings.mcpServers) { server in
                        Button { editing = server } label: { row(server) }
                            .buttonStyle(.plain)
                    }
                    Text("\(activeToolCount) tool\(activeToolCount == 1 ? "" : "s") available to the model.")
                        .font(.caption).foregroundStyle(Theme.textTertiary).padding(.horizontal, 2)
                }

                Button { showAdd = true } label: {
                    Label("Add a server", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.medium)).foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity).padding(.vertical, Theme.Space.md)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card,
                                                                        style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .strokeBorder(Theme.hairline))
                }
                .buttonStyle(.plain)
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .navigationTitle("MCP servers")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { for server in settings.mcpServers where server.isEnabled { probe.probe(server) } }
        .sheet(isPresented: $showAdd) { MCPEditorView(settings: settings, probe: probe) }
        .sheet(item: $editing) { server in
            NavigationStack {
                MCPServerDetailView(settings: settings, probe: probe, serverID: server.id)
            }
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 520)
            #endif
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.largeTitle).foregroundStyle(Theme.textTertiary)
            Text("No servers yet").font(.subheadline.weight(.medium)).foregroundStyle(Theme.textSecondary)
            Text("The built-in calculator, clock and Wikipedia lookup work without one.")
                .font(.caption).foregroundStyle(Theme.textTertiary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, Theme.Space.xl)
        .studioCard()
    }

    /// Tools the model will actually see right now — enabled servers, minus muted tools.
    private var activeToolCount: Int {
        settings.mcpServers.filter(\.isEnabled).reduce(0) { sum, server in
            sum + probe.tools(for: server).count(where: { !server.disabledTools.contains($0.name) })
        }
    }

    private func row(_ server: MCPServer) -> some View {
        HStack(spacing: Theme.Space.md) {
            StatusDot(status: probe.status(for: server), enabled: server.isEnabled)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(server.url).font(.caption2.monospaced()).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
                statusLine(server)
            }
            Spacer(minLength: Theme.Space.sm)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textTertiary)
        }
        .padding(Theme.Space.md)
        .studioCard()
        .contentShape(Rectangle())
        .opacity(server.isEnabled ? 1 : 0.55)
    }

    @ViewBuilder private func statusLine(_ server: MCPServer) -> some View {
        if !server.isEnabled {
            Text("Off").font(.caption2).foregroundStyle(Theme.textTertiary)
        } else {
            switch probe.status(for: server) {
            case .idle, .checking:
                Text("Connecting…").font(.caption2).foregroundStyle(Theme.textTertiary)
            case .ok(let tools):
                let muted = server.disabledTools.count
                Text("\(tools.count) tool\(tools.count == 1 ? "" : "s")"
                     + (muted > 0 ? " · \(muted) muted" : ""))
                    .font(.caption2).foregroundStyle(Theme.fitGreen)
            case .failed(let why):
                Text(why).font(.caption2).foregroundStyle(Theme.danger).lineLimit(1)
            }
        }
    }
}

/// Traffic light for a server: grey off, pulsing while probing, celadon connected, red failed.
private struct StatusDot: View {
    let status: MCPProbe.Status
    let enabled: Bool

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.18)).frame(width: 30, height: 30)
            if case .checking = status, enabled {
                ProgressView().controlSize(.mini).tint(Theme.accent)
            } else {
                Image(systemName: icon).font(.caption.weight(.bold)).foregroundStyle(color)
            }
        }
        .accessibilityHidden(true)
    }

    private var color: Color {
        guard enabled else { return Theme.fitGray }
        switch status {
        case .ok: return Theme.fitGreen
        case .failed: return Theme.danger
        default: return Theme.fitGray
        }
    }

    private var icon: String {
        guard enabled else { return "pause" }
        switch status {
        case .ok: return "checkmark"
        case .failed: return "exclamationmark"
        default: return "point.3.connected.trianglepath.dotted"
        }
    }
}

// MARK: - Detail

/// One server: enable, re-test, browse its tools, mute the noisy ones, delete.
/// Keyed by `serverID` and read back out of `settings` so edits stay live (the array is the source of truth).
struct MCPServerDetailView: View {
    @Bindable var settings: AppSettings
    let probe: MCPProbe
    let serverID: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    private var index: Int? { settings.mcpServers.firstIndex { $0.id == serverID } }

    var body: some View {
        Group {
            if let index {
                content(index: index)
            } else {
                Color.clear.onAppear { dismiss() }   // deleted out from under us
            }
        }
        .background(Theme.bg)
        .navigationTitle(settings.mcpServers.first { $0.id == serverID }?.name ?? "Server")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .alert("Remove this server?", isPresented: $confirmDelete) {
            Button("Remove", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its tools stop being offered to the model. Nothing on the server itself changes.")
        }
    }

    private func content(index: Int) -> some View {
        let server = settings.mcpServers[index]
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Toggle(isOn: $settings.mcpServers[index].isEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enabled").font(.subheadline).foregroundStyle(Theme.textPrimary)
                            Text("Off keeps the server configured but skips it — no connection, no tools.")
                                .font(.caption).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .tint(Theme.accent)
                    .onChange(of: settings.mcpServers[index].isEnabled) { _, on in
                        if on { probe.probe(server, force: true) }
                    }
                    Divider().background(Theme.hairline)
                    Text(server.url).font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                    if server.token?.isEmpty == false {
                        Label("Bearer token saved", systemImage: "key.fill")
                            .font(.caption2).foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(Theme.Space.md).studioCard()

                statusCard(server)
                toolsCard(server, index: index)

                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Remove server", systemImage: "trash")
                        .font(.subheadline.weight(.medium)).foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity).padding(.vertical, Theme.Space.md)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card,
                                                                        style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .strokeBorder(Theme.hairline))
                }
                .buttonStyle(.plain)
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private func statusCard(_ server: MCPServer) -> some View {
        HStack(spacing: Theme.Space.md) {
            StatusDot(status: probe.status(for: server), enabled: server.isEnabled)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline(server)).font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary)
                if case .failed(let why) = probe.status(for: server), server.isEnabled {
                    Text(why).font(.caption).foregroundStyle(Theme.danger)
                }
            }
            Spacer(minLength: Theme.Space.sm)
            Button { probe.probe(server, force: true) } label: {
                Label("Test", systemImage: "arrow.clockwise").font(.caption.weight(.medium))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            .disabled(!server.isEnabled)
        }
        .padding(Theme.Space.md).studioCard()
    }

    private func headline(_ server: MCPServer) -> String {
        guard server.isEnabled else { return "Disabled" }
        switch probe.status(for: server) {
        case .idle: return "Not tested yet"
        case .checking: return "Connecting…"
        case .ok(let tools): return "Connected · \(tools.count) tool\(tools.count == 1 ? "" : "s")"
        case .failed: return "Couldn't connect"
        }
    }

    @ViewBuilder private func toolsCard(_ server: MCPServer, index: Int) -> some View {
        let tools = probe.tools(for: server)
        if !tools.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack {
                    Text("Tools").font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("\(tools.count - server.disabledTools.count) of \(tools.count) on")
                        .font(.caption2.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                }
                Text("Mute the ones you don't need. Small models choose badly from a long list — "
                     + "fewer, sharper tools beat more.")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
                ForEach(tools, id: \.name) { tool in
                    Divider().background(Theme.hairline)
                    Toggle(isOn: toolBinding(index: index, tool: tool.name)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.name).font(.caption.monospaced().weight(.medium))
                                .foregroundStyle(Theme.textPrimary)
                            if !tool.description.isEmpty {
                                Text(tool.description).font(.caption2).foregroundStyle(Theme.textTertiary)
                                    .lineLimit(3)
                            }
                        }
                    }
                    .tint(Theme.accent)
                }
            }
            .padding(Theme.Space.md).studioCard()
        }
    }

    /// A tool's toggle reads the *inverse* of the muted set — mute is the stored state, on is the default,
    /// so a server that adds a tool later has it on without us having to notice.
    private func toolBinding(index: Int, tool: String) -> Binding<Bool> {
        Binding(
            get: { !settings.mcpServers[index].disabledTools.contains(tool) },
            set: { on in
                if on { settings.mcpServers[index].disabledTools.remove(tool) }
                else { settings.mcpServers[index].disabledTools.insert(tool) }
            }
        )
    }

    private func remove() {
        guard let index else { return }
        probe.forget(settings.mcpServers[index])
        settings.mcpServers.remove(at: index)
        dismiss()
    }
}

// MARK: - Add

/// The add sheet, with a **Test** that connects before you commit — the difference between "saved" and
/// "works" is the entire user experience of MCP, and a typo'd path is the single most common failure.
struct MCPEditorView: View {
    @Bindable var settings: AppSettings
    let probe: MCPProbe
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var test: MCPProbe.Status = .idle

    private var trimmedURL: String { url.trimmingCharacters(in: .whitespaces) }
    private var draft: MCPServer {
        MCPServer(name: name.trimmingCharacters(in: .whitespaces).isEmpty ? trimmedURL : name,
                  url: trimmedURL,
                  token: token.trimmingCharacters(in: .whitespaces).isEmpty ? nil
                       : token.trimmingCharacters(in: .whitespaces))
    }
    private var duplicate: Bool { settings.mcpServers.contains { $0.id == trimmedURL } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    Text("A remote MCP endpoint over Streamable HTTP. iOS can't run stdio servers, and "
                         + "App Transport Security requires https:// on device.")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                    field("Name", text: $name, placeholder: "DeepWiki")
                    field("Server URL", text: $url, placeholder: "https://host/mcp", mono: true)
                    field("Bearer token (optional)", text: $token, placeholder: "", mono: true, secure: true)
                    if !trimmedURL.isEmpty, !trimmedURL.lowercased().hasPrefix("https://") {
                        Label("Not https — iOS will refuse to connect on device.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(Theme.fitAmber)
                    }
                    if duplicate {
                        Label("That URL is already configured.", systemImage: "exclamationmark.circle.fill")
                            .font(.caption).foregroundStyle(Theme.fitAmber)
                    }
                    testRow
                }
                .padding(Theme.Space.lg)
                .frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            .background(Theme.bg)
            .navigationTitle("New MCP server")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }.disabled(trimmedURL.isEmpty || duplicate)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 380)
        #endif
    }

    @ViewBuilder private var testRow: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Button { runTest() } label: {
                Label("Test connection", systemImage: "bolt.horizontal.circle")
                    .font(.subheadline.weight(.medium)).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(trimmedURL.isEmpty)
            switch test {
            case .idle: EmptyView()
            case .checking:
                HStack(spacing: Theme.Space.xs) {
                    ProgressView().controlSize(.mini).tint(Theme.accent)
                    Text("Connecting…").font(.caption).foregroundStyle(Theme.textTertiary)
                }
            case .ok(let tools):
                VStack(alignment: .leading, spacing: 3) {
                    Label("Connected · \(tools.count) tool\(tools.count == 1 ? "" : "s")",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium)).foregroundStyle(Theme.fitGreen)
                    Text(tools.map(\.name).joined(separator: ", "))
                        .font(.caption2.monospaced()).foregroundStyle(Theme.textTertiary).lineLimit(3)
                }
            case .failed(let why):
                Label(why, systemImage: "xmark.circle.fill")
                    .font(.caption).foregroundStyle(Theme.danger)
            }
        }
        .padding(Theme.Space.md).studioCard()
    }

    /// The editor's own probe: `MCPProbe` is keyed by URL, and this server isn't saved yet.
    private func runTest() {
        let server = draft
        test = .checking
        Task {
            do {
                let tools = try await MCPClient(server: server).connect()
                test = .ok(tools)
            } catch {
                test = .failed(MCPProbe.describe(error))
            }
        }
    }

    private func add() {
        guard !trimmedURL.isEmpty, !duplicate else { return }
        let server = draft
        settings.mcpServers.append(server)
        probe.probe(server, force: true)
        dismiss()
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String,
                       mono: Bool = false, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(Theme.textSecondary)
            Group {
                if secure { SecureField(placeholder, text: text) } else { TextField(placeholder, text: text) }
            }
            .textFieldStyle(.plain)
            .font(mono ? .callout.monospaced() : .callout)
            #if os(iOS)
            .autocorrectionDisabled().textInputAutocapitalization(.never)
            #endif
            .padding(Theme.Space.sm)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                .strokeBorder(Theme.hairline))
            .onChange(of: text.wrappedValue) { _, _ in if !secure { test = .idle } }
        }
    }
}

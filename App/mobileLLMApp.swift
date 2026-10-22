// SPDX-License-Identifier: MIT

import SwiftUI
import AppRuntime
import MobileLLMUI
import LLMCore
import LLMEngineMLX
import LLMEngineLlama
import LLMEngineApple
import AgentRuntime

#if DEBUG
/// Deterministic Responses API transport used only by the opt-in simulator UI test. It exercises
/// the production provider parser, durable executor, analyzer, automatic one-run approval, and engine
/// without making release-gating UI behavior depend on a live model's latency or output quality.
private final class DynamicWorkflowUITestResponsesProtocol: URLProtocol, @unchecked Sendable {
    private static let environmentKey = "MOBILELLM_DYNAMIC_WORKFLOW_RESPONSES_FIXTURE"

    override class func canInit(with request: URLRequest) -> Bool {
        ProcessInfo.processInfo.environment[environmentKey] == "1"
            && request.url?.path.hasSuffix("/responses") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = Self.requestBodyString(request)
        let text: String
        if body.contains("KIMI_SYNTHESIS_TRACK") {
            text = """
            EVAL_KIMI_LOCAL: Running the complete Kimi K3 weights entirely offline on an iPhone 16 Pro is not feasible. The phone's RAM and storage are far below the order of magnitude required even after aggressive quantization. Use a much smaller on-device model, or keep Kimi K3 on a remote server/API and make the iPhone a private client.
            """
        } else if body.contains("KIMI_MODEL_TRACK") {
            text = "The full model has an enormous parameter footprint; quantization reduces bytes per weight but does not make phone-class deployment realistic."
        } else if body.contains("IPHONE_LIMIT_TRACK") {
            text = "An iPhone 16 Pro has phone-class unified memory and storage, both orders of magnitude below the complete model's practical runtime requirements."
        } else if body.contains("DEPLOYMENT_PATH_TRACK") {
            text = "Realistic paths are a smaller local model for offline work or a remote Kimi deployment/API with explicit network and privacy controls."
        } else if body.contains("mobileLLM Dynamic Workflow V1")
            || body.contains("Repair one mobileLLM Dynamic Workflow V1")
        {
            text = """
            export const meta = {
              name: "kimi-local-feasibility",
              description: "Researches model scale, device limits, and deployment alternatives before producing a concrete verdict.",
              whenToUse: "A user asks whether a very large model can run fully locally on an iPhone.",
              phases: [
                { title: "Research", detail: "Run three independent constraint tracks in parallel." },
                { title: "Synthesize", detail: "Turn the evidence into a direct deployment verdict." }
              ]
            };
            phase("Research");
            const findings = await parallel([
              () => agent("KIMI_MODEL_TRACK: Estimate the complete Kimi K3 weight and runtime footprint.", { label: "Model scale", phase: "Research" }),
              () => agent("IPHONE_LIMIT_TRACK: Assess iPhone 16 Pro RAM and storage constraints.", { label: "Device limits", phase: "Research" }),
              () => agent("DEPLOYMENT_PATH_TRACK: Identify honest local and remote deployment alternatives.", { label: "Alternatives", phase: "Research" })
            ]);
            phase("Synthesize");
            return await agent(`KIMI_SYNTHESIS_TRACK: Give a direct verdict using all three findings. Preserve the token EVAL_KIMI_LOCAL. Model: ${findings[0]} Device: ${findings[1]} Alternatives: ${findings[2]}`, { label: "Final verdict", phase: "Synthesize" });
            """
        } else {
            text = "unexpected simulator workflow request"
        }
        do {
            let delta = try JSONSerialization.data(
                withJSONObject: ["type": "response.output_text.delta", "delta": text],
                options: [.sortedKeys]
            )
            let completed = try JSONSerialization.data(
                withJSONObject: [
                    "type": "response.completed",
                    "status": "completed",
                    "usage": ["input_tokens": 16, "output_tokens": 32],
                ],
                options: [.sortedKeys]
            )
            var bytes = Data("data: ".utf8)
            bytes.append(delta)
            bytes.append(Data("\n\ndata: ".utf8))
            bytes.append(completed)
            bytes.append(Data("\n\n".utf8))
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func requestBodyString(_ request: URLRequest) -> String {
        if let data = request.httpBody { return String(data: data, encoding: .utf8) ?? "" }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let capacity = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: capacity)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func session() -> URLSession {
        guard ProcessInfo.processInfo.environment[environmentKey] == "1" else { return .shared }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DynamicWorkflowUITestResponsesProtocol.self]
        return URLSession(configuration: configuration)
    }
}
#endif

private func agentRuntimeURLSession() -> URLSession {
    #if DEBUG
    DynamicWorkflowUITestResponsesProtocol.session()
    #else
    .shared
    #endif
}

#if DEBUG && os(macOS)
import AppKit

/// Opt-in, in-process Mac screenshot configuration. Rendering the target window's own view hierarchy
/// avoids depending on the active display, Spaces, screen-capture permission, or which of several remote
/// monitors happens to be focused. Normal launches do not create this request and pay no runtime cost.
private struct MacScreenshotRequest {
    let outputURL: URL
    let errorURL: URL
    let section: AppSection
    let appearance: AppearanceMode?

    static func current(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> MacScreenshotRequest? {
        guard let outputPath = environment["MOBILELLM_MAC_SCREENSHOT_PATH"], !outputPath.isEmpty else {
            return nil
        }
        let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
        let errorPath = environment["MOBILELLM_MAC_SCREENSHOT_ERROR_PATH"]
        let errorURL = errorPath.map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? outputURL.appendingPathExtension("error.txt")
        let section = environment["MOBILELLM_MAC_SCREENSHOT_SECTION"]
            .flatMap(AppSection.init(rawValue:)) ?? .chat
        let appearance: AppearanceMode? = switch environment["MOBILELLM_MAC_SCREENSHOT_APPEARANCE"] {
        case "light": .light
        case "dark": .dark
        case "system": .system
        default: nil
        }
        return MacScreenshotRequest(outputURL: outputURL, errorURL: errorURL,
                                    section: section, appearance: appearance)
    }
}

/// Captures the largest app window from inside the process. `screencapture` and CGWindow snapshots can
/// omit privacy-protected SwiftUI windows, especially over remote desktop; an NSView cache is independent
/// of window-sharing flags, active Spaces, physical monitor geometry, and frontmost-app state.
@MainActor
private enum MacWindowSnapshotter {
    static func capture(_ request: MacScreenshotRequest) async {
        // Bootstrap has completed before this method starts. Let SwiftUI commit that observable state,
        // initial navigation, and sidebar animation before sampling rendered pixels.
        try? await Task.sleep(for: .milliseconds(700))
        var previousBounds: CGRect?
        var previousPNG: Data?
        var stablePasses = 0
        for _ in 0..<100 {
            guard !Task.isCancelled else { return }
            guard let window = captureWindow(), let contentView = window.contentView else {
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            let targetView = contentView.superview ?? contentView
            window.layoutIfNeeded()
            targetView.layoutSubtreeIfNeeded()
            targetView.displayIfNeeded()
            let bounds = targetView.bounds.integral
            guard bounds.width >= 640, bounds.height >= 480 else {
                stablePasses = 0
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            if bounds != previousBounds {
                previousBounds = bounds
                previousPNG = nil
                stablePasses = 0
            }
            do {
                let png = try renderPNG(targetView)
                if png == previousPNG {
                    stablePasses += 1
                } else {
                    previousPNG = png
                    stablePasses = 0
                }
                // Stable geometry alone is insufficient: async bootstrap can change the content without
                // resizing the window. Publish only after three identical rendered frames.
                if stablePasses >= 2 {
                    try FileManager.default.createDirectory(
                        at: request.outputURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try png.write(to: request.outputURL, options: .atomic)
                    return
                }
            } catch {
                report(error, to: request.errorURL)
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        report(MacScreenshotError.windowNeverSettled, to: request.errorURL)
    }

    private static func captureWindow() -> NSWindow? {
        NSApplication.shared.windows
            .filter { window in
                guard window.isVisible, let content = window.contentView else { return false }
                return content.bounds.width >= 640 && content.bounds.height >= 480
            }
            .max { lhs, rhs in lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height }
    }

    private static func renderPNG(_ view: NSView) throws -> Data {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw MacScreenshotError.bitmapAllocationFailed
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw MacScreenshotError.pngEncodingFailed
        }
        return png
    }

    private static func report(_ error: Error, to errorURL: URL) {
        let message = "macOS screenshot failed: \(error.localizedDescription)\n"
        do {
            try FileManager.default.createDirectory(at: errorURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(message.utf8).write(to: errorURL, options: .atomic)
        } catch {
            print(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

private enum MacScreenshotError: LocalizedError {
    case windowNeverSettled
    case bitmapAllocationFailed
    case pngEncodingFailed

    var errorDescription: String? {
        switch self {
        case .windowNeverSettled: "the app window did not reach a stable capture size"
        case .bitmapAllocationFailed: "AppKit could not allocate a window bitmap"
        case .pngEncodingFailed: "AppKit could not encode the window bitmap as PNG"
        }
    }
}
#endif

/// App assembly: a `RoutingEngine` fronting the three concrete engines (MLX-fork, llama.cpp, and Apple's
/// system model) and the resumable `ModelDownloader` are injected into the `AppContainer` composition root
/// here; everywhere else runs against the `LLMEngine` protocol. The router loads each variant on the engine
/// its `backend` names and keeps at most one resident, so switching engines never doubles memory.
@main
struct MobileLLMApp: App {
    @State private var container: AppContainer
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @State private var lifecycleMonitor: iOSSceneLifecycleMonitor?
    #endif
    #if DEBUG && os(macOS)
    private let macScreenshotRequest = MacScreenshotRequest.current()
    #endif
    #if DEBUG && os(iOS)
    private let deviceE2E = DeviceE2EConfiguration.current()
    #endif

    init() {
        // Device-test harness opt-out for cooperative thermal pacing (production never sets this).
        if ProcessInfo.processInfo.environment["MOBILELLM_DISABLE_THERMAL"] == "1" {
            ThermalGovernor.isPacingEnabled = false
        }
        // Multi-GB weights live under Application Support (a no-backup dir so they don't hit iCloud).
        let base = URL.applicationSupportDirectory.appending(path: "mobileLLM", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let downloader = ModelDownloader(downloadBase: base)
        // App.init runs on the main thread; adopt that isolation to build the @MainActor container.
        // The Apple engine is registered unconditionally, even on an OS with no FoundationModels: it owns
        // no weights and costs nothing to hold, and being present is what lets the Models card say WHY the
        // system model can't run instead of the UI having to guess.
        let engine = RoutingEngine(engines: [
            .mlx: MLXLLMEngine(),
            .llamaCpp: LlamaEngine(),
            .apple: AppleLLMEngine(),
        ])
        // The privacy-gated tool adapters are wired here (the composition root for platform frameworks,
        // like the engines above): construction is cheap and prompts for nothing — EventKit/CoreLocation
        // only ask for access lazily, on the first tool call, and only if the user enabled that tool.
        #if canImport(EventKit)
        let eventStore: (any EventStoring)? = EventKitStore()
        #else
        let eventStore: (any EventStoring)? = nil
        #endif
        #if canImport(CoreLocation)
        let locationProvider: (any LocationProviding)? = CoreLocationProvider()
        #else
        let locationProvider: (any LocationProviding)? = nil
        #endif
        let container = MainActor.assumeIsolated {
            #if os(iOS)
            // Production finite drain lease over UIApplication.beginBackgroundTask (spec §19.1).
            let lifecycle = LifecycleCoordinator(drainProvider: UIKitBackgroundDrainProvider())
            #else
            let lifecycle = LifecycleCoordinator()
            #endif
            let continuedProcessing = ContinuedProcessingCoordinator()
            return AppContainer(
                engine: engine,
                downloadBase: base,
                downloader: { repoId, revision, globs, progress in
                    _ = try await downloader.download(repoId: repoId, revision: revision,
                                                      matching: globs, progress: progress)
                },
                // The model layer is engine-free, so only this layer can ask the OS about its own model.
                // This IS the system model's install state: available ⇒ ready to use, nothing downloaded.
                systemModelProbe: { AppleSystemModel.status() },
                eventStore: eventStore,
                locationProvider: locationProvider,
                lifecycle: lifecycle,
                continuedProcessing: continuedProcessing
            )
        }
        container.mcpDiscovery.setCredentialResolver { server in
            try? KeychainBox(service: AppSettings.defaultKeychainService)
                .readString(account: server.url)
        }
        // Weight unloading is independent of agent assembly. If assembly later fails, sending is
        // fail-closed, but the app can still release any selected model cleanly.
        container.lifecycle.suspendModel = { [weak container] in
            container?.suspendModel()
        }
        // Online Responses config box: the provider reads it on worker threads; the app refreshes the
        // non-secret values from Settings on the main actor at every submission.
        let onlineConfigBox = OpenAIOnlineConfigurationBox(
            baseURL: container.settings.openAIBaseURL,
            modelID: container.settings.openAIModelID,
            maximumOutputTokens: container.settings.onlineActiveService?.maximumOutputTokens,
            credentials: container.openAICredentials
        )
        #if DEBUG
        // Local OpenAI-compatible service config: the developer stores it once at
        // ~/.mobilellm/openai.json (outside the repo); the macOS DEBUG app reads it directly, and the
        // simulator/device test runners inject the same values through launch environment variables,
        // which this block applies with env winning over the file. The key then goes into the device
        // Keychain store; base URL and model are non-secret settings.
        do {
            var config = OpenAILocalConfigLoader.loadDefault()
                ?? OpenAILocalConfig(
                    apiKey: "",
                    baseURL: OpenAIServiceConfiguration.defaultBaseURL
                )
            OpenAILocalConfigLoader.applyEnvironment(
                ProcessInfo.processInfo.environment,
                to: &config
            )
            if !config.apiKey.isEmpty {
                try? container.openAICredentials.saveAPIKey(config.apiKey)
            }
            if let baseURL = OpenAIServiceConfiguration.normalizedBaseURL(config.baseURL) {
                container.settings.openAIBaseURL = baseURL
            }
            if let model = config.model, !model.isEmpty {
                container.settings.openAIModelID = model
            }
            // DEBUG convenience for simulator/device E2E: an embedded config with a model is a
            // complete online service, so arm it instead of leaving the toggle off and forcing every
            // test run through Settings. Production builds never contain this block.
            if !config.apiKey.isEmpty, let model = config.model, !model.isEmpty {
                container.settings.openAIOnlineEnabled = true
            }
        }
        #endif
        // Rehydrate every configuration identity a durable run can legitimately reference after a
        // relaunch. If the service was deleted or its endpoint changed, the old identity is absent and
        // recovery fails closed instead of redirecting data. Reasoning effort has three finite values.
        for service in container.settings.onlineServices {
            for effort in ReasoningEffort.allCases {
                onlineConfigBox.update(
                    serviceID: service.id,
                    baseURL: service.baseURL,
                    modelID: service.modelID,
                    reasoningEffort: effort,
                    maximumOutputTokens: service.maximumOutputTokens
                )
            }
        }
        // Attach the durable agent runtime (spec §6 / §20): SQLite journal, artifact store, local
        // model providers over the same routing engine, and the run store the UI projects. A failure
        // is visible and fail-closed; production never silently changes to the legacy tool loop.
        MainActor.assumeIsolated {
            container.runtimeBootstrap = {
            #if os(iOS)
            // Register the iOS 26 continued-processing launch handler (spec §19.2). The wildcard
            // identifier must match BGTaskSchedulerPermittedIdentifiers in Info.plist.
            if #available(iOS 26.0, *) {
                let prefix = "\(Bundle.main.bundleIdentifier ?? "wang.wangdongdong.mobileLLM").continuedProcessing"
                let scheduler = BGContinuedProcessingSchedulerAdapter(identifierPrefix: prefix)
                container.continuedProcessing.scheduler = scheduler
                container.continuedProcessing.journal = { message in
                    AgentRuntimeAssembly.logger(message)
                }
                scheduler.register(identifier: "\(prefix).*") { [weak container] task in
                    guard let container else {
                        task.setTaskCompleted(success: false)
                        return
                    }
                    if let box = task as? BGContinuedProcessingTaskHandleBox {
                        box.onExpirationForwarded = { [weak container] in
                            container?.continuedProcessing.handleExpiration()
                        }
                    }
                    guard let conversationID = ContinuedProcessingCoordinator.conversationID(
                        fromIdentifier: task.identifier,
                        prefix: prefix
                    ) else {
                        task.setTaskCompleted(success: false)
                        return
                    }
                    container.continuedProcessing.handleTask(task, conversationID: conversationID)
                }
            }
            #endif
            do {
                let assembly = try AgentRuntimeAssembly(
                    engine: engine,
                    downloadBase: base,
                    conversationDirectory: container.conversationStore.directory,
                    models: container.models.allModels,
                    snapshot: { [weak container] conversationID, userTurnID, text, imageRefs in
                        if let template = AppWorkflowSnapshotRegistry.shared.template(
                            conversationID: conversationID,
                            userTurnID: userTurnID
                        ) {
                            return template.withText(text)
                        }
                        guard let container else { return nil }
                        return makeAgentSnapshot(
                            container: container,
                            conversationID: conversationID,
                            userTurnID: userTurnID,
                            text: text,
                            imageRefs: imageRefs,
                            downloadBase: base,
                            onlineConfigBox: onlineConfigBox
                        )
                    },
                    memoryStore: container.chat.memoryBook?.store,
                    eventStore: container.toolEventStore,
                    locationProvider: container.toolLocationProvider,
                    mcpDiscovery: container.mcpDiscovery,
                    session: agentRuntimeURLSession(),
                    onlineConfiguration: { onlineConfigBox.configuration(for: $0) }
                )
                container.attachAgentRuns(assembly.runStore)
                // Production outbox projector (spec §9.1/§33 gap 2): claims journal outbox rows and
                // applies them to the conversation JSON idempotently. Workflow root/child final
                // answers are owned by the workflow summary path and are acknowledged without
                // projecting raw JSON into the chat.
                let projector = ConversationOutboxProjector(
                    outbox: SQLiteOutboxProvider(repository: assembly.repository),
                    payloads: PayloadOutboxProvider(payloadStore: assembly.payloadStore),
                    store: container.conversationStore,
                    shouldProject: { item in
                        guard let runID = item.runID else { return true }
                        guard let facts = try? await assembly.repository.loadRunFacts(for: runID) else {
                            return true
                        }
                        let source = facts.submission?.request.payload.provenance.source
                        // Workflow roots and children project through their message-anchored summary;
                        // their synthetic user messages and raw answers never belong in chat.
                        return source != .workflow && source != .parentAgent
                    }
                )
                container.outboxProjector = projector
                // Bootstrap drain: project any rows committed by a previous run before a crash/quit.
                Task { await projector.drain() }
                container.chat.agentMCPToolLogicalIDs = { [weak container] in
                    guard let container else { return [] }
                    return container.mcpDiscovery
                        .descriptors(for: container.settings.mcpServers)
                        .map(\.id.logicalID)
                }
                container.agentDiagnosticSnapshot = { @MainActor in
                    await assembly.diagnosticLogger.snapshot()
                        .map { entry in
                            let fields = entry.metadata
                                .map { "\($0.key)=\($0.value)" }
                                .sorted()
                                .joined(separator: ",")
                            return "\(entry.code):\(fields)"
                        }
                        .joined(separator: "|")
                }
                AgentRuntimeAssembly.logger(
                    "Agent runtime attached (journal: \(assembly.repository.location.path))"
                )
                container.workflowStore.load()
                let launcher = WorkflowLauncher(
                    container: container,
                    assembly: assembly,
                    downloadBase: base,
                    onlineConfigBox: onlineConfigBox
                )
                container.prepareRuntimeDataErase = { try await launcher.suspendForDataErase() }
                container.eraseRuntimeData = { try await assembly.eraseAllRuntimeData() }
                container.finishRuntimeDataErase = {
                    await assembly.executor.controller.resumeAfterDataErase()
                    await assembly.dynamicWorkflows.resumeAfterDataErase()
                }
                container.quiesceWorkflows = { try await launcher.quiesceForBackground() }
                container.chat.workflowLaunch = { [launcher] goal, conversationID,
                    userMessageID, workflowID in
                    try await launcher.launch(
                        goal: goal,
                        conversationID: conversationID,
                        userMessageID: userMessageID,
                        workflowID: workflowID
                    )
                }
                // Neutral launch: interrupted workflows remain visible but never execute until the
                // user presses Resume. The handler reconstructs the journaled root and stable child
                // identities only after that explicit action.
                container.workflowStore.resumeHandler = { [launcher] workflowID in
                    try await launcher.resume(workflowID: workflowID)
                }
                container.workflowStore.dynamicRunHandler = { [launcher] workflowID in
                    try await launcher.runDynamic(workflowID: workflowID)
                }
                container.workflowStore.dynamicDenyHandler = { [launcher] workflowID in
                    try await launcher.denyDynamic(workflowID: workflowID)
                }
                container.workflowStore.dynamicStartHandler = { [launcher] workflowID in
                    try await launcher.startDynamic(workflowID: workflowID)
                }
                container.workflowStore.dynamicPauseHandler = { [launcher] workflowID in
                    try await launcher.pauseDynamic(workflowID: workflowID)
                }
                container.workflowStore.dynamicResumeHandler = { [launcher] workflowID in
                    try await launcher.resumeDynamic(workflowID: workflowID)
                }
                container.workflowStore.dynamicReconcileHandler = { [launcher] workflowID, decision in
                    try await launcher.reconcileDynamic(
                        workflowID: workflowID,
                        decision: decision
                    )
                }
                container.workflowStore.dynamicStopHandler = { [launcher] workflowID in
                    try await launcher.stopDynamic(workflowID: workflowID)
                }
                container.workflowStore.dynamicRestartHandler = { [launcher] workflowID, callID in
                    try await launcher.restartDynamicAgent(
                        workflowID: workflowID,
                        callID: callID
                    )
                }
                // Journal reconciliation is projection-only. Opening the app never starts or
                // resumes a workflow and never loads a model.
                Task { await launcher.reconcileDynamicWorkflows() }
            } catch {
                container.recordAgentRuntimeFailure(error)
                AgentRuntimeAssembly.logger(
                    "Agent runtime unavailable; sending disabled: \(error.localizedDescription)"
                )
            }
        }
        }
        #if DEBUG && os(macOS)
        if let appearance = macScreenshotRequest?.appearance {
            container.settings.appearance = appearance
        }
        #endif
        _container = State(initialValue: container)
        #if os(iOS)
        _lifecycleMonitor = State(initialValue: iOSSceneLifecycleMonitor(coordinator: container.lifecycle))
        #endif
        #if DEBUG && os(macOS)
        // Keep screenshot automation independent of SwiftUI view identity. A view-scoped `.task` can be
        // cancelled while bootstrap publishes its first observable changes, leaving a remote QA runner
        // waiting forever even though the app window is healthy. This unstructured MainActor task lives
        // for the short capture attempt and finds the app-owned window after launch has settled.
        if let request = macScreenshotRequest {
            let screenshotContainer = container
            Task { @MainActor in
                // Capture a fully hydrated page, not merely a stable-sized window. `bootstrap()` is
                // idempotent, so RootView can safely await the same operation at the same time.
                await screenshotContainer.bootstrap()
                await Task.yield()
                await MacWindowSnapshotter.capture(request)
            }
        }
        #endif
    }

    private var initialSection: AppSection {
        #if DEBUG && os(macOS)
        macScreenshotRequest?.section ?? .chat
        #else
        .chat
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView(container: container, initialSection: initialSection)
                #if DEBUG && os(iOS)
                .overlay(alignment: .topLeading) {
                    if deviceE2E != nil { DeviceE2EDiagnosticsOverlay(container: container) }
                }
                #endif
                // `bootstrap()` is awaited by RootView's own `.task` and is idempotent — a second `.task`
                // here would race it (sessions decoded and selection restored twice), so it's
                // deliberately NOT started from the App scene.
                .onChange(of: scenePhase) { _, phase in
                    #if os(iOS)
                    // The scene monitor aggregates every connected scene (spec §19.1); scenePhase is
                    // only a launch-ordering safety net. The coordinator's enter guards make the
                    // double call harmless.
                    if phase == .background {
                        container.lifecycle.enterBackground()
                    } else if phase == .active || phase == .inactive {
                        container.lifecycle.enterForeground()
                    }
                    #else
                    // Free the resident model when the app leaves the foreground: it stops a 5 GB model
                    // hogging memory while unused and stops macOS jetsam-killing the app in the background.
                    if phase == .background {
                        container.suspendModel()
                        // Durable agent quiescence (spec §19.1): every active run pauses at its next
                        // safe boundary; recovery is explicit user Resume, never automatic.
                        Task { await container.chat.agentRuns?.quiesceForBackground() }
                    }
                    #endif
                }
        }
        // A postfix `#if` may contain ONLY member-expression continuations (SE-0308), so the Settings
        // scene sits in its own block below rather than sharing this one.
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        .commands { AppCommands(container: container) }
        #endif

        // macOS Settings scene (⌘,) — the same Settings surface, hosted in its own window.
        #if os(macOS)
        Settings {
            MacSettingsWindow(container: container)
        }
        #endif
    }
}

@MainActor
func makeAgentSnapshot(
    container: AppContainer,
    conversationID: UUID,
    userTurnID: UUID,
    text: String,
    imageRefs: [ImageRef],
    downloadBase: URL,
    onlineConfigBox: OpenAIOnlineConfigurationBox
) -> AgentRunRequestSnapshot? {
    guard let conversation = container.chat.conversation(id: conversationID) else { return nil }

    // Derive every conversation-scoped field from the requested conversation, never `activeID` or
    // the currently visible model. Workflow/recovery callers may legitimately snapshot a background
    // conversation, and normal sends can suspend immediately after this boundary.
    let onlineParts = OnlineModelIdentity.serviceParts(fromConversationModelID: conversation.modelID)
    let onlineService = onlineParts.flatMap { parts in
        container.settings.onlineServices.first { $0.id == parts.serviceID }
    }
    let onlineConfigurationID: String?
    if let onlineParts, let onlineService {
        onlineConfigurationID = onlineConfigBox.update(
            serviceID: onlineParts.serviceID,
            baseURL: onlineService.baseURL,
            modelID: onlineParts.model,
            reasoningEffort: conversation.reasoningEffort ?? .medium,
            maximumOutputTokens: onlineService.maximumOutputTokens
        )
    } else {
        onlineConfigurationID = nil
    }

    let onlineModelID = onlineParts?.model
    // Online runs need no local weights, so a device with zero installed models can still send. The
    // fallback identity only feeds context-policy bookkeeping; the run selection is the online provider
    // and the runtime never touches its weights directory.
    let identity: (model: LLMModel, variant: LLMVariant, weightsDirectory: URL)
    if onlineParts == nil,
       let model = container.models.model(id: conversation.modelID),
       let variant = model.variants.first(where: { $0.id == conversation.variantID })
            ?? model.variants.sorted(by: { $0.id < $1.id }).first(where: {
                $0.matchesPersistedID(conversation.variantID)
            })
            ?? model.variants.sorted(by: { $0.id < $1.id }).first
    {
        identity = (
            model,
            variant,
            ModelDownloader(downloadBase: downloadBase)
                .localURL(repoId: variant.source.huggingFaceRepo)
        )
    } else if onlineModelID != nil,
              let fallback = container.models.model(id: container.settings.defaultModelID)
                ?? LLMCatalog.all.first
    {
        let variant = fallback.defaultVariantValue
        identity = (
            fallback,
            variant,
            ModelDownloader(downloadBase: downloadBase)
                .localURL(repoId: variant.source.huggingFaceRepo)
        )
    } else {
        return nil
    }
    let contextLength = conversation.contextLength
    let localContextLength = contextLength ?? container.settings.contextLength
    let onlineContextLength = contextLength ?? container.settings.onlineContextLength
    let sampling = conversation.sampling
    let onlineOutputBudgetAuto = onlineParts != nil
        && (sampling?.maxTokens.map { $0 == 0 } ?? (container.settings.onlineMaxTokens == 0))
    let maxTokens: Int
    if let override = sampling?.maxTokens {
        maxTokens = onlineParts != nil && override == 0 ? onlineContextLength : override
    } else if onlineParts != nil {
        maxTokens = container.settings.onlineMaxTokens == 0
            ? onlineContextLength
            : container.settings.onlineMaxTokens
    } else {
        maxTokens = container.settings.maxTokens
    }
    let toolsEnabled = conversation.toolPolicy?.masterEnabled ?? container.settings.toolsEnabled
    let localToolNames: [String]
    if let policy = conversation.toolPolicy {
        localToolNames = policy.allowedToolIDs
            .filter { $0.providerID == "builtin" }
            .map(\.name)
            .sorted()
    } else {
        localToolNames = container.settings.builtInToolConfig.enabled.map(\.rawValue).sorted()
    }
    return AgentRunRequestSnapshot(
        conversationID: conversationID,
        userTurnID: userTurnID,
        text: text,
        imageRefs: imageRefs,
        messages: conversation.messages,
        systemPrompt: container.settings.systemPrompt,
        memoryFacts: container.settings.memoryEnabled
            ? ChatStore.selectedMemoryFacts(
                container.chat.memoryBook?.snapshotFacts ?? [],
                query: ChatStore.memoryQuery(draft: text, history: conversation.messages.filter { $0.id != userTurnID })
            ) : [],
        activeSkill: conversation.skillID.flatMap { container.chat.skillStore?.skill(id: $0) },
        model: identity.model,
        variant: identity.variant,
        weightsDirectory: identity.weightsDirectory,
        thinkingEnabled: container.chat.thinkingEnabled,
        contextLength: localContextLength,
        maxTokens: maxTokens,
        temperature: sampling?.temperature ?? container.settings.temperature,
        topP: sampling?.topP ?? container.settings.topP,
        topK: container.settings.topK,
        repetitionPenalty: container.settings.repetitionPenalty,
        toolsEnabled: toolsEnabled,
        localToolNames: localToolNames,
        memorySeamAvailable: container.chat.memoryBook != nil,
        eventSeamAvailable: container.toolEventStore != nil,
        locationSeamAvailable: container.toolLocationProvider != nil,
        mcpToolDescriptors: toolsEnabled
            ? container.mcpDiscovery.descriptors(for: container.settings.mcpServers)
            : [],
        webSearchDestinations: toolsEnabled
            ? (try? container.settings.builtInToolConfig.searchEngines.map {
                try AppWebSearchToolAdapter.destination(engine: $0)
            }) ?? []
            : [],
        toolPolicy: conversation.toolPolicy,
        onlineModelEnabled: onlineParts != nil,
        onlineModelID: onlineModelID,
        onlineServiceID: onlineParts?.serviceID,
        onlineConfigurationID: onlineConfigurationID,
        onlineReasoningEnabled: conversation.onlineReasoningEnabled
            ?? container.settings.thinkingDefault,
        onlineContextLength: onlineContextLength,
        onlineOutputBudgetAuto: onlineOutputBudgetAuto,
        onlineMaximumOutputTokens: onlineService?.maximumOutputTokens,
        approvalMode: conversation.approvalMode ?? .safePreset,
        onlineReasoningEffort: conversation.reasoningEffort ?? .medium
    )
}

#if os(macOS)
/// The macOS menu-bar commands (DESIGN §4): the keyboard-first affordances a Mac app is expected to have,
/// acting on the container the App owns. New Chat (⌘N, replacing the default File ▸ New), and a Model menu
/// with Switch Model (⌘L → the quick switcher), Toggle Thinking (⇧⌘T), and Stop Generating (⌘.).
struct AppCommands: Commands {
    let container: AppContainer

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { container.chat.newConversation() }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandMenu("Model") {
            Button("Switch Model…") { container.switcherRequested = true }
                .keyboardShortcut("l", modifiers: .command)
            Button("Toggle Thinking") { container.chat.thinkingEnabled.toggle() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Button("Stop Generating") { container.chat.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!container.chat.isStreaming)
        }
    }
}
#endif

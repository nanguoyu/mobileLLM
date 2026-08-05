// SPDX-License-Identifier: MIT

#if DEBUG && os(iOS)
import SwiftUI
import UIKit
import CryptoKit
import LLMCore
import MobileLLMUI

/// Opt-in diagnostics used only by the signed DEBUG build driven by the physical-device E2E target.
/// Release builds contain none of this surface, and a normal DEBUG launch without the environment flag
/// behaves exactly like production.
struct DeviceE2EConfiguration {
    let attachVisionFixture: Bool

    static func current() -> DeviceE2EConfiguration? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MOBILELLM_DEVICE_E2E"] == "1" else { return nil }
        return DeviceE2EConfiguration(
            attachVisionFixture: environment["MOBILELLM_DEVICE_E2E_FIXTURE"] == "1"
        )
    }
}

/// Two stable accessibility values make asynchronous engine state observable without changing the UI.
/// A header and composer prove only model *identity*; `resident=true` proves the real engine has loaded.
struct DeviceE2EDiagnosticsOverlay: View {
    let container: AppContainer
    @State private var agentLog = ""

    var body: some View {
        VStack(spacing: 0) {
            diagnostic("device-e2e.runtime", value: runtimeValue)
            diagnostic("device-e2e.inventory", value: inventoryValue)
            diagnostic("device-e2e.agent", value: agentValue)
            diagnostic("device-e2e.fixture", value: "pendingImages=\(container.chat.pendingImages.count)")
        }
        .frame(width: 1, height: 1)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(false)
        .task {
            guard DeviceE2EConfiguration.current()?.attachVisionFixture == true else { return }
            _ = container.chat.attach(imageData: DeviceE2EVisionFixture.pngData())
        }
        .task {
            while !Task.isCancelled {
                if let snapshot = container.agentDiagnosticSnapshot {
                    agentLog = await snapshot()
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func diagnostic(_ id: String, value: String) -> some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(id)
            .accessibilityValue(value)
            .accessibilityIdentifier(id)
    }

    private var runtimeValue: String {
        let active = container.models.active
        let phase: String
        switch container.chat.streaming?.phase {
        case .warming: phase = "warming"
        case .thinking: phase = "thinking"
        case .answering: phase = "answering"
        case .stopping: phase = "stopping"
        case nil: phase = "idle"
        }
        return [
            "model=\(active?.model.id ?? "none")",
            "variant=\(active?.variant.id ?? "none")",
            "engine=\(active?.variant.engine.label ?? "none")",
            "resident=\(container.models.engineResident)",
            "phase=\(phase)",
            "thermal=\(thermalState)",
            "openaiModel=\(container.settings.openAIModelID ?? "none")",
            "openaiEnabled=\(container.settings.openAIOnlineEnabled)",
            "openaiKey=\((try? container.openAICredentials.loadAPIKey()) == nil ? "missing" : "stored")",
            "openaiBaseURL=\(container.settings.openAIBaseURL)",
            "openaiKeyFingerprint=\(openAIKeyFingerprint)",
        ].joined(separator: ";")
    }

    /// First 16 hex chars of SHA-256 over the stored key — enough to compare the phone's Keychain
    /// against the Mac's ~/.mobilellm/openai.json without ever exposing the secret.
    private var openAIKeyFingerprint: String {
        guard let key = try? container.openAICredentials.loadAPIKey() else { return "none" }
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    private var thermalState: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private var inventoryValue: String {
        let ids = container.models.allModels
            .flatMap(\.variants)
            .filter { container.models.isInstalled($0) && !$0.isSystemProvided }
            .map(\.id)
            .sorted()
        return ids.isEmpty ? "none" : ids.joined(separator: ",")
    }

    private var agentValue: String {
        let run = container.agentRuns?.presentation(for: container.chat.activeID ?? UUID())
        return [
            "enabled=\(container.chat.agentRuntimeEnabled)",
            "run=\(run?.state?.rawValue ?? "none")",
            "steps=\(run?.steps.count ?? 0)",
            "recoverable=\(container.agentRuns?.recoverableRuns.count ?? 0)",
            "error=\(container.agentRuntimeError ?? "none")",
            "failure=\(run?.failureMessage ?? "none")",
            "sendError=\(container.chat.agentLastSendError ?? "none")",
            "log=\(agentLog)",
        ].joined(separator: ";")
    }
}

/// A deterministic, high-contrast image for the real Gemma/mmproj path. It is injected through the same
/// `ChatStore.attach` downscale/persist pipeline as a picker image, but never opens Photos or Camera and
/// never touches the user's media. The model must read both geometry and the `ORBIT 7421` text.
enum DeviceE2EVisionFixture {
    @MainActor static func pngData() -> Data {
        let size = CGSize(width: 768, height: 768)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            UIColor.systemRed.setFill()
            context.cgContext.fill(CGRect(x: 72, y: 80, width: 250, height: 250))

            UIColor.systemBlue.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 446, y: 80, width: 250, height: 250))

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 82, weight: .black),
                .foregroundColor: UIColor.black,
                .paragraphStyle: paragraph,
            ]
            NSString(string: "ORBIT 7421").draw(
                in: CGRect(x: 24, y: 430, width: 720, height: 150),
                withAttributes: attributes
            )

            let captionAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 38, weight: .bold),
                .foregroundColor: UIColor.darkGray,
                .paragraphStyle: paragraph,
            ]
            NSString(string: "RED SQUARE   BLUE CIRCLE").draw(
                in: CGRect(x: 24, y: 610, width: 720, height: 80),
                withAttributes: captionAttributes
            )
        }
        return image.pngData() ?? Data()
    }
}
#endif

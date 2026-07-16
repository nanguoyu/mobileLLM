// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI

/// A calm, centered empty/placeholder panel with warm, action-oriented copy (DESIGN §4/§6 states).
struct ChatPlaceholder: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: icon)
                .font(.largeTitle.weight(.light))   // semantic size → scales with Dynamic Type
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(StudioButtonStyle(.primary))
                    .padding(.top, Theme.Space.xs)
            }
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .accessibilityElement(children: .combine)
    }
}

/// The "no model loaded" state — points at Models (DESIGN §6: no-model).
struct NoModelState: View {
    var onOpenModels: () -> Void
    var body: some View {
        ChatPlaceholder(
            icon: "cpu",
            title: "No model loaded",
            message: "mobileLLM runs entirely on your device — pick a model to download once, then chat "
                   + "offline with nothing leaving your phone.",
            actionTitle: "Choose a model", action: onOpenModels)
    }
}

/// A distinct model-loading state (DESIGN §6): a slow cold-start load is honest work, not "no model
/// loaded" — so it gets its own spinner + the model name, never the no-model dead-end.
struct ModelLoadingState: View {
    let modelName: String
    var body: some View {
        VStack(spacing: Theme.Space.md) {
            ProgressView().controlSize(.large).tint(Theme.accent)
            Text("Loading \(modelName)…")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading \(modelName)")
    }
}

/// The empty-conversation state with a few example prompts to tap (DESIGN §4 onboarding echo).
struct EmptyChatState: View {
    let modelName: String
    var onExample: (String) -> Void
    /// Open the model switcher. A NEW chat is the moment you decide who to talk to — the title is the
    /// picker, so the inherited last-used model is a visible, one-tap-changeable choice, never silent.
    var onSwitchModel: () -> Void = {}

    private let examples = [
        "Explain how sleep affects memory.",
        "Write a haiku about the ocean.",
        "Draft a polite reminder email.",
        "Give me a 20-minute dinner idea.",
    ]

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            Spacer()
            VStack(spacing: Theme.Space.sm) {
                Image(systemName: "sparkles")
                    .font(.largeTitle.weight(.light))   // semantic size → scales with Dynamic Type
                    .foregroundStyle(Theme.accent)
                Button(action: onSwitchModel) {
                    HStack(spacing: Theme.Space.xs) {
                        Text("Chat with \(modelName)")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Image(systemName: "chevron.down.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(Theme.accent)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Chat with \(modelName)")
                .accessibilityHint("Choose a different model")
                Text("Private, on-device, no account. Ask anything to get started.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: Theme.Space.sm) {
                ForEach(examples, id: \.self) { example in
                    Button { onExample(example) } label: {
                        HStack {
                            Text(example).font(.subheadline).foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(Theme.textTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .studioCard(Theme.Space.md)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Use this example prompt")
                }
            }
            .frame(maxWidth: 420)
            Spacer()
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

/// The warming shimmer that honestly owns prefill latency before the first token (DESIGN §4).
struct WarmingShimmer: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(Theme.surface2)
                    .frame(height: 12)
                    .frame(maxWidth: i == 2 ? 180 : .infinity)
                    .overlay(shimmerOverlay)
                    .clipShape(Capsule())
            }
        }
        .onAppear {
            guard !Motion.reduce else { return }
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { phase = 2 }
        }
        .accessibilityLabel("Warming up the model")
    }

    private var shimmerOverlay: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, Theme.accentSoft, .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width * 0.6)
                .offset(x: phase * geo.size.width)
        }
    }
}

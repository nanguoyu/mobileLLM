// SPDX-License-Identifier: MIT

import SwiftUI
import PhotosUI
import AppUI

/// The chat composer (DESIGN §4): multiline auto-grow field, one morphing Send↔Stop button (no
/// reflow), an inline 🧠 thinking toggle, a mic for dictation, an optional photo attach (vision models),
/// and a live context meter. When no model is loaded the input is replaced by a compact hint that routes
/// to the model picker — so a model-less thread is browsable but sending is clearly gated.
struct Composer: View {
    @Bindable var chat: ChatStore
    var thinkingCapable: Bool
    /// The active model can accept image input (a vision GGUF with its projector installed) — shows the
    /// photo attach affordance. Text-only / MLX models never see it.
    var canAttachImages: Bool = false
    /// True while a model is loading (cold start / switch) — shows a loading hint instead of the picker CTA.
    var isLoadingModel: Bool = false
    /// Route to the Models screen (the no-model CTA).
    var onOpenModels: () -> Void = {}

    @FocusState private var focused: Bool
    @State private var dictation = DictationService()
    /// The draft text captured when dictation started, so live partial results replace (not duplicate).
    @State private var dictationBase = ""
    /// Photo-library picks (loaded async into `chat.pendingImages`), and the flag that presents the picker.
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    /// Composer controls scale with Dynamic Type instead of a hard 44pt.
    @ScaledMetric(relativeTo: .body) private var controlSize: CGFloat = 44

    private var usage: (used: Int, cap: Int) { chat.contextUsage() }

    private var meterColor: Color {
        let ratio = usage.cap > 0 ? Double(usage.used) / Double(usage.cap) : 0
        if ratio >= 0.98 { return Theme.danger }
        if ratio >= 0.85 { return Theme.fitAmber }
        return Theme.textTertiary
    }

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            contextMeter
            if !chat.pendingImages.isEmpty { pendingImageChips }
            if chat.hasModel {
                HStack(alignment: .bottom, spacing: Theme.Space.sm) {
                    if thinkingCapable { thinkingToggle }
                    if canAttachImages { photoButton }
                    micButton
                    field
                    sendOrStop
                }
            } else {
                noModelBar
            }
        }
        .padding(Theme.Space.md)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().background(Theme.hairline) }
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItems,
                      maxSelectionCount: ChatStore.maxAttachments, matching: .images)
        .onChange(of: pickerItems) { _, items in loadPickedImages(items) }
        #if os(iOS)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in
                showCamera = false
                if let data, !chat.attach(imageData: data) {
                    chat.showToast(Toast("Couldn't add that photo.", kind: .warning, autoDismiss: 3))
                }
            }
            .ignoresSafeArea()
        }
        #endif
        .onChange(of: dictation.transcript) { _, transcript in
            guard dictation.isRecording else { return }
            chat.draft = merge(base: dictationBase, dictated: transcript)
        }
        .onChange(of: dictation.state) { _, state in
            switch state {
            case .denied:
                chat.showToast(Toast("Allow microphone and speech access in Settings to dictate.",
                                     kind: .warning, autoDismiss: 4))
            case .unavailable:
                chat.showToast(Toast("Dictation isn't available for this language.",
                                     kind: .warning, autoDismiss: 4))
            case .idle, .recording:
                break
            }
        }
        .onDisappear { dictation.stop() }   // never leave the audio session running behind us
    }

    private func merge(base: String, dictated: String) -> String {
        if base.isEmpty { return dictated }
        if dictated.isEmpty { return base }
        return base + " " + dictated
    }

    // MARK: No-model hint

    private var noModelBar: some View {
        HStack(spacing: Theme.Space.sm) {
            if isLoadingModel {
                ProgressView().controlSize(.small)
                Text("Loading model…")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            } else {
                Image(systemName: "cpu").foregroundStyle(Theme.accent)
                Text("Add a model to start chatting.")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Space.sm)
                Button("Choose a model") { onOpenModels() }
                    .buttonStyle(StudioButtonStyle(.primary))
            }
        }
        .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous).strokeBorder(Theme.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isLoadingModel ? "Loading model" : "No model loaded")
        .accessibilityHint(isLoadingModel ? "" : "Choose a model to start chatting")
    }

    // MARK: Context meter

    private var contextMeter: some View {
        HStack(spacing: Theme.Space.xs) {
            Spacer()
            if usage.used > 0 {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.caption2).foregroundStyle(meterColor)
                Text(Format.context(usage.used, usage.cap))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(meterColor)
                    .accessibilityLabel("Context used")
                    .accessibilityValue("\(usage.used) of \(usage.cap) tokens")
            }
        }
        .frame(height: 14)
    }

    // MARK: Field

    private var field: some View {
        TextField(placeholder, text: $chat.draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.body)
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1...6)
            .focused($focused)
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous).strokeBorder(Theme.hairline))
            #if os(macOS)
            .onSubmit { if chat.canSend { chat.send(); focused = false } }   // ⏎ sends on Mac; ⇧⏎ inserts a newline
            #endif
            .accessibilityLabel("Message")
    }

    private var placeholder: String {
        "Message \(chat.activeModel?.model.displayName ?? "the model")…"
    }

    // MARK: Dictation

    /// Dictation language choices: one `SFSpeechRecognizer` = one language, so a code-switching user
    /// picks explicitly. `nil` follows the system locale.
    private static let dictationLanguages: [(id: String?, label: String)] = [
        (nil, "System language"),
        ("zh-CN", "中文（普通话）"),
        ("en-US", "English"),
    ]

    private var micButton: some View {
        Button {
            if dictation.isRecording {
                dictation.stop()
            } else {
                dictationBase = chat.draft
                dictation.localeIdentifier = chat.dictationLocale
                dictation.start()
            }
        } label: {
            Image(systemName: dictation.isRecording ? "mic.fill" : "mic")
                .font(.body)
                .foregroundStyle(dictation.isRecording ? Theme.accent : Theme.textTertiary)
                .frame(width: controlSize, height: controlSize)
                .background(dictation.isRecording ? Theme.accentSoft : Theme.surface2,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                .overlay(alignment: .topTrailing) { if dictation.isRecording { RecordingDot() } }
        }
        .buttonStyle(.plain)
        // Long-press: pick the recognition language (persisted; applies from the next recording).
        .contextMenu {
            ForEach(Self.dictationLanguages, id: \.label) { lang in
                Button {
                    chat.dictationLocale = lang.id
                } label: {
                    if chat.dictationLocale == lang.id {
                        Label(lang.label, systemImage: "checkmark")
                    } else {
                        Text(lang.label)
                    }
                }
            }
        }
        .accessibilityLabel("Dictate")
        .accessibilityValue(dictation.isRecording ? "Recording" : "Off")
        .accessibilityHint("Long-press to choose the dictation language")
        .accessibilityAddTraits(dictation.isRecording ? [.isSelected] : [])
    }

    // MARK: Photo attach

    private var photoButton: some View {
        Menu {
            Button {
                showPhotoPicker = true
            } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
            #if os(iOS)
            if CameraPicker.isAvailable {
                Button {
                    ChatThreadView.dismissKeyboard()
                    showCamera = true
                } label: { Label("Take Photo", systemImage: "camera") }
            }
            #endif
            Button {
                pasteImage()
            } label: { Label("Paste", systemImage: "doc.on.clipboard") }
        } label: {
            Image(systemName: "photo")
                .font(.body)
                .foregroundStyle(chat.canAttachMoreImages ? Theme.textTertiary : Theme.fitGray)
                .frame(width: controlSize, height: controlSize)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
        }
        .menuIndicator(.hidden)
        .disabled(!chat.canAttachMoreImages)
        .accessibilityLabel("Attach image")
        .accessibilityHint(chat.canAttachMoreImages ? "Add a photo to your message"
                                                     : "Attachment limit reached")
    }

    /// Thumbnail chips for staged (not-yet-sent) images, each with a remove control.
    private var pendingImageChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.sm) {
                ForEach(chat.pendingImages) { image in
                    pendingChip(image)
                }
            }
            .padding(.horizontal, 2).padding(.vertical, 2)
        }
        .frame(height: 64)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pendingChip(_ image: PendingImage) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumb = Image(attachmentData: image.data) {
                    thumb.resizable().scaledToFill()
                } else {
                    Rectangle().fill(Theme.surface2)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous).strokeBorder(Theme.hairline))
            .accessibilityLabel("Attached image")

            Button {
                chat.removePendingImage(image.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Theme.onAccent, Theme.textSecondary)
                    .background(Circle().fill(Theme.surface))
            }
            .buttonStyle(.plain)
            .padding(2)
            .accessibilityLabel("Remove attached image")
        }
    }

    /// Load photo-library picks into the composer (downscaled by `chat.attach`), then clear the selection.
    private func loadPickedImages(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task { @MainActor in
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    _ = chat.attach(imageData: data)
                }
            }
            pickerItems = []
        }
    }

    /// Attach an image from the clipboard, or tell the user there isn't one.
    private func pasteImage() {
        guard let data = Clipboard.imageData() else {
            chat.showToast(Toast("No image on the clipboard.", kind: .warning, autoDismiss: 3))
            return
        }
        if !chat.attach(imageData: data) {
            chat.showToast(Toast("Couldn't add that image.", kind: .warning, autoDismiss: 3))
        }
    }

    // MARK: Thinking toggle

    private var thinkingToggle: some View {
        Button {
            withAnimation(Motion.select) { chat.thinkingEnabled.toggle() }
        } label: {
            Image(systemName: "brain")
                .font(.body)
                .foregroundStyle(chat.thinkingEnabled ? Theme.accent : Theme.textTertiary)
                .frame(width: controlSize, height: controlSize)
                .background(chat.thinkingEnabled ? Theme.accentSoft : Theme.surface2,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Thinking mode")
        .accessibilityValue(chat.thinkingEnabled ? "On" : "Off")
        .accessibilityAddTraits(chat.thinkingEnabled ? [.isSelected] : [])
    }

    // MARK: Send / Stop

    private var sendOrStop: some View {
        Button {
            if chat.isStreaming {
                chat.stop()
            } else {
                dictation.stop()
                chat.send()
                focused = false   // dismiss keyboard on send
            }
        } label: {
            Image(systemName: chat.isStreaming ? "stop.fill" : "arrow.up")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: controlSize, height: controlSize)
                .background(sendBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(!chat.isStreaming && !chat.canSend)
        .accessibilityLabel(chat.isStreaming ? "Stop" : "Send")
    }

    private var sendBackground: Color {
        if chat.isStreaming { return Theme.danger }
        return chat.canSend ? Theme.accent : Theme.fitGray
    }
}

/// The pulsing cinnabar seal dot that marks an active recording.
private struct RecordingDot: View {
    @State private var pulsing = false
    var body: some View {
        Circle()
            .fill(Theme.accent)
            .frame(width: 8, height: 8)
            .opacity(pulsing ? 1 : 0.3)
            .padding(4)
            .onAppear {
                guard !Motion.reduce else { pulsing = true; return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulsing = true }
            }
            .accessibilityHidden(true)
    }
}

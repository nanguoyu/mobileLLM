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
    /// Stop stays disarmed for a beat after send so the tail of a double-tap can't cancel the turn.
    @State private var stopArmed = false
    /// Presents the skill management sheet (composer's "Manage Skills…").
    @State private var showSkills = false
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
            if let skill = chat.activeSkill { activeSkillChip(skill) }
            if !chat.pendingImages.isEmpty { pendingImageChips }
            if chat.hasModel {
                HStack(alignment: .bottom, spacing: Theme.Space.sm) {
                    plusMenu
                    field
                    micButton
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
        .sheet(isPresented: $showSkills) {
            if let store = chat.skillStore {
                NavigationStack { SkillsView(store: store) }
                #if os(macOS)
                    .frame(minWidth: 520, minHeight: 560)
                #endif
            }
        }
        .onChange(of: pickerItems) { _, items in loadPickedImages(items) }
        // Belt and suspenders for EVERY attach path (incl. the field's own paste menu): a staged chip
        // appearing under an open keyboard grows the composer down behind it — drop focus so the next
        // tap re-measures the taller composer correctly.
        .onChange(of: chat.pendingImages.count) { old, new in
            if new > old { focused = false }
        }
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
            .accessibilityIdentifier("composer.field")   // XCUITest hook (keyboard-geometry regression)
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

    /// One [+] gathers every secondary control (thinking, tools, image sources) — four separate 44pt
    /// buttons squeezed the text field to a sliver on iPhone. The icon tints accent while thinking or
    /// tools is on, so state stays visible at a glance; menu rows carry the explicit checkmarks.
    private var plusMenu: some View {
        Menu {
            if thinkingCapable {
                Toggle(isOn: Binding(get: { chat.thinkingEnabled },
                                     set: { chat.thinkingEnabled = $0 })) {
                    Label("Thinking", systemImage: "brain")
                }
            }
            Toggle(isOn: Binding(get: { chat.toolsEnabled },
                                 set: { newValue in
                                     chat.toolsEnabled = newValue
                                     chat.showToast(Toast(newValue
                                         ? "Tools on — search, webpage reader, memory, calculator + your MCP servers."
                                         : "Tools off.", autoDismiss: 3))
                                 })) {
                Label("Tools", systemImage: "wrench.and.screwdriver")
            }
            if chat.skillStore != nil { skillMenu }
            if canAttachImages {
                Divider()
                // Every image entry point clears the FOCUS STATE, not just the first responder: a bare
                // resignFirstResponder leaves `focused == true`, so when the picker sheet closes SwiftUI
                // re-asserts focus and the keyboard returns over a now-taller composer — with the input
                // row buried beneath it. Clearing the binding keeps the keyboard down until the user
                // taps the field again, at which point the full (chips-included) height is measured.
                Button {
                    focused = false
                    showPhotoPicker = true
                } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                #if os(iOS)
                if CameraPicker.isAvailable {
                    Button {
                        focused = false
                        showCamera = true
                    } label: { Label("Take Photo", systemImage: "camera") }
                }
                #endif
                Button {
                    focused = false
                    pasteImage()
                } label: { Label("Paste Image", systemImage: "doc.on.clipboard") }
            }
        } label: {
            let active = chat.toolsEnabled || (thinkingCapable && chat.thinkingEnabled) || chat.activeSkill != nil
            Image(systemName: "plus")
                .font(.body.weight(.medium))
                .foregroundStyle(active ? Theme.accent : Theme.textTertiary)
                .frame(width: controlSize, height: controlSize)
                .background(active ? Theme.accentSoft : Theme.surface2,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("Chat options")
        .accessibilityHint("Thinking, tools and image attachments")
    }

    // MARK: Skill

    /// The Skill submenu inside the [+] menu: None + every skill (checkmark on the active one) + a route
    /// into the management sheet. Explicit per-conversation selection (Skills v1 — no auto-routing).
    private var skillMenu: some View {
        Menu {
            Button { chat.setActiveSkill(nil) } label: {
                if chat.activeSkill == nil { Label("None", systemImage: "checkmark") } else { Text("None") }
            }
            if !chat.availableSkills.isEmpty { Divider() }
            ForEach(chat.availableSkills) { skill in
                Button { chat.setActiveSkill(skill.id) } label: {
                    if chat.activeSkill?.id == skill.id {
                        Label("\(skill.emoji)  \(skill.name)", systemImage: "checkmark")
                    } else {
                        Text("\(skill.emoji)  \(skill.name)")
                    }
                }
            }
            Divider()
            Button {
                focused = false
                showSkills = true
            } label: { Label("Manage Skills…", systemImage: "slider.horizontal.3") }
        } label: {
            Label("Skill", systemImage: "sparkles")
        }
    }

    /// The active-skill chip above the input — same visual family as the pending-image chips, with an x to
    /// deactivate the skill for this thread.
    private func activeSkillChip(_ skill: Skill) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: Theme.Space.xs) {
                Text(skill.emoji).font(.caption).accessibilityHidden(true)
                Text(skill.name)
                    .font(.caption.weight(.medium)).foregroundStyle(Theme.accent)
                    .lineLimit(1)
                Button { chat.setActiveSkill(nil) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Theme.accent, Theme.accentSoft)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Deactivate skill")
            }
            .padding(.leading, Theme.Space.sm).padding(.trailing, Theme.Space.xs)
            .padding(.vertical, Theme.Space.xs)
            .background(Theme.accentSoft, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.25)))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Active skill: \(skill.name)")
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
        // The button morphs Send→Stop under the finger while the keyboard collapse shifts the layout —
        // the tail of a double-tap on Send used to land on Stop and kill the turn instantly ("Stopped ·
        // Retry" on device). Arm Stop only after a short beat; ⌘. and deliberate stops still work.
        .disabled(chat.isStreaming ? !stopArmed : !chat.canSend)
        .onChange(of: chat.isStreaming) { _, streaming in
            stopArmed = false
            guard streaming else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                if chat.isStreaming { stopArmed = true }
            }
        }
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

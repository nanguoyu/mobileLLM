// SPDX-License-Identifier: MIT

#if DEBUG
import Foundation
import AppRuntime
import LLMCore

// Preview-only seeding so `#Preview` blocks render populated, MockLLMEngine-driven surfaces without
// touching disk or the network.

extension ChatStore {
    /// Inject in-memory conversations + an active model for previews.
    func previewSeed(_ conversations: [Conversation], active: LoadedModel?) {
        self.conversations = conversations.sorted(by: ChatStore.recencyPreview)
        self.activeID = self.conversations.first?.id
        self.activeModel = active
    }

    private static func recencyPreview(_ a: Conversation, _ b: Conversation) -> Bool {
        if a.pinned != b.pinned { return a.pinned }
        return a.updatedAt > b.updatedAt
    }
}

extension SkillStore {
    /// Seed the built-in skills in memory (previews render the Skill menu + management list without disk I/O).
    func previewSeed() { skills = Skill.builtIns }
}

/// An in-memory `MemoryStoring` for previews: the memory screen renders saved facts — both provenance
/// labels, both relative dates — without touching disk. A real store would need the seed written through
/// an async save, and `MemoryBook.refresh()` would read the empty file back before the first frame.
actor PreviewMemoryStore: MemoryStoring {
    private var facts: [MemoryFact]

    init(_ seed: [MemoryFact] = [
        MemoryFact(text: "The user's dog is named Momo",
                   createdAt: Date().addingTimeInterval(-90 * 60), source: .model),
        MemoryFact(text: "Prefers short answers, no preamble",
                   createdAt: Date().addingTimeInterval(-3 * 24 * 60 * 60), source: .user),
    ]) {
        facts = seed
    }

    @discardableResult func save(_ text: String, source: MemoryFact.Source) -> MemoryFact {
        let fact = MemoryFact(text: text, source: source)
        facts.append(fact)
        return fact
    }
    func list() -> [MemoryFact] { facts }
    func update(id: String, text: String) {
        guard let i = facts.firstIndex(where: { $0.id == id }) else { return }
        let old = facts[i]
        facts[i] = MemoryFact(id: old.id, text: text, createdAt: old.createdAt, source: old.source)
    }
    func delete(id: String) { facts.removeAll { $0.id == id } }
    func deleteAll() { facts.removeAll() }
}

extension ModelManager {
    /// Mark every catalog variant as installed (previews show a working library).
    func previewInstallAll() {
        installed = Set(catalog.flatMap { $0.variants }.map(\.id))
    }
    /// Set the resident model directly (previews skip the engine load).
    func previewSetActive(_ loaded: LoadedModel?) { active = loaded }
}

extension AppContainer {
    /// A fully-seeded preview container: MockLLMEngine, everything installed, a couple of chats.
    public static func preview(seeded: Bool = true) -> AppContainer {
        let device = DeviceTier.current
        let container = AppContainer(
            engine: MockLLMEngine(script: .init(chunkSize: 2, chunkDelayNanos: 12_000_000)),
            downloadBase: FileManager.default.temporaryDirectory.appending(component: "mobilellm-preview"),
            downloader: { _, _, progress in
                for i in 1...20 { progress(Double(i) / 20); try? await Task.sleep(nanoseconds: 40_000_000) }
            },
            device: device,
            settings: AppSettings(defaults: UserDefaults(suiteName: "mobilellm-preview")!),
            conversationStore: ConversationStore(
                directory: FileManager.default.temporaryDirectory.appending(component: "mobilellm-preview-convos")),
            memoryStore: PreviewMemoryStore(),
            installProbe: { _, _ in true },
            availableMemory: { .max })

        container.models.previewInstallAll()
        container.skills.previewSeed()
        let model = LLMCatalog.bonsai8b
        let loaded = LoadedModel(model: model, variant: model.defaultVariantValue)
        container.models.previewSetActive(loaded)
        container.syncActive()

        if seeded {
            let now = Date()
            let convo1 = Conversation(
                title: "Haiku about the ocean", createdAt: now, updatedAt: now,
                modelID: model.id, variantID: model.defaultVariantValue.id,
                messages: [
                    Message(role: .user, answer: "Write a haiku about the ocean."),
                    Message(role: .assistant,
                            answer: "Endless blue expanse\nWaves whisper to silent shores\nMoon pulls the deep home",
                            reasoning: "A haiku is 5-7-5 syllables. Ocean imagery: waves, blue, moon, tide.",
                            stats: Stats(promptTokens: 12, genTokens: 21, promptTPS: 240,
                                         tokensPerSecond: 28, peakMemoryBytes: 2_300_000_000, stopReason: .eos)),
                ])
            let convo2 = Conversation(
                title: "Dinner ideas", createdAt: now.addingTimeInterval(-90_000),
                updatedAt: now.addingTimeInterval(-90_000), modelID: model.id,
                variantID: model.defaultVariantValue.id, pinned: true)
            container.chat.previewSeed([convo1, convo2], active: loaded)
        }
        return container
    }
}
#endif

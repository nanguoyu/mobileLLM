// SPDX-License-Identifier: MIT

import Foundation
import Observation
import AppRuntime

/// The @MainActor state owner for Skills (Skills v1). Holds the observable `skills` list the composer
/// menu, the chip, and the management UI all read, and persists it through `DurableStore<Skill>` — the
/// same crash-safe, back-up-not-wipe record store that backs conversations and tool memory (a user's
/// custom skills are worth the same defensive posture). The JSON lives at `<conversation dir>/skills.json`,
/// beside `memory.json`; `AppContainer` wires the location.
///
/// Seeded ON FIRST LOAD with `Skill.builtIns`: an empty store gets the five starters written to disk once.
/// Because built-ins can't be deleted, a subsequent load reads a non-empty file and never re-seeds — so
/// relaunching never duplicates them. Built-ins are immutable here (the UI offers "Duplicate to edit");
/// custom skills are full CRUD.
@MainActor
@Observable
public final class SkillStore {

    /// Every skill, built-ins first (seed order) then custom (creation order). The single source the UI
    /// observes. `internal(set)` so preview seeding (Previews.swift) can populate it without disk I/O; the
    /// app target only reads it and mutates through the CRUD methods.
    public internal(set) var skills: [Skill] = []

    private let store: DurableStore<Skill>
    /// Guards against a redundant re-read (and, defensively, a re-seed) if `load()` is awaited twice.
    private var hasLoaded = false

    /// Persist at an explicit file URL (the app passes `<conversation dir>/skills.json`; tests a temp path).
    public init(fileURL: URL) {
        store = DurableStore<Skill>(fileURL: fileURL)
    }

    /// Hydrate `skills` from disk, seeding the built-in starters on a genuinely empty store. Idempotent:
    /// a second call is a no-op, and because built-ins persist + can't be deleted, a fresh instance at the
    /// same URL reads them back instead of seeding again (no duplicates across relaunches).
    public func load() async {
        guard !hasLoaded else { return }
        let loaded = await store.load()
        if loaded.isEmpty {
            skills = Skill.builtIns
            try? await store.save(skills)
        } else {
            skills = loaded
        }
        hasLoaded = true
    }

    /// The skill with this id, or nil (nil-safe lookup for a conversation whose skill was deleted).
    public func skill(id: UUID) -> Skill? { skills.first { $0.id == id } }

    /// The built-in / custom split for the two-section management list.
    public var builtInSkills: [Skill] { skills.filter(\.isBuiltIn) }
    public var customSkills: [Skill] { skills.filter { !$0.isBuiltIn } }

    // MARK: - CRUD (custom skills; built-ins are immutable)

    /// Add a custom skill (appended after existing ones). `isBuiltIn` is forced false — only the seed makes
    /// built-ins.
    @discardableResult
    public func create(name: String, emoji: String, summary: String, instructions: String) -> Skill {
        let skill = Skill(name: Self.clean(name), emoji: Self.oneEmoji(emoji),
                          summary: Self.clean(summary), instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines),
                          isBuiltIn: false)
        skills.append(skill)
        persist()
        return skill
    }

    /// Replace a custom skill in place (no-op for a built-in or an unknown id). Keeps its id + position.
    public func update(_ skill: Skill) {
        guard let i = skills.firstIndex(where: { $0.id == skill.id }), !skills[i].isBuiltIn else { return }
        var normalized = skill
        normalized.name = Self.clean(skill.name)
        normalized.emoji = Self.oneEmoji(skill.emoji)
        normalized.summary = Self.clean(skill.summary)
        normalized.instructions = skill.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        skills[i] = normalized
        persist()
    }

    /// Delete a custom skill (no-op for a built-in or an unknown id).
    public func delete(id: UUID) {
        guard let i = skills.firstIndex(where: { $0.id == id }), !skills[i].isBuiltIn else { return }
        skills.remove(at: i)
        persist()
    }

    /// Make an editable custom copy of any skill (the built-ins' "Duplicate to edit" path). The copy is a
    /// fresh custom skill with a new id and a "· Copy" name so the original stays put.
    @discardableResult
    public func duplicate(_ skill: Skill) -> Skill {
        create(name: skill.name + " Copy", emoji: skill.emoji,
               summary: skill.summary, instructions: skill.instructions)
    }

    // MARK: - Helpers

    private func persist() {
        let snapshot = skills
        Task { try? await store.save(snapshot) }
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A skill glyph is one emoji — take the first character so a paste of several doesn't smear the row.
    /// Falls back to a neutral sparkle when the field is blank.
    static func oneEmoji(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "✨" }
        return String(first)
    }
}

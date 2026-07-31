// SPDX-License-Identifier: MIT

import Foundation

/// Best-effort full-app erasure reports every scope that failed instead of stopping at the first one and
/// falsely claiming success. Successful scopes stay erased; retrying is safe and attempts only empty/no-op
/// work plus any data that remained.
public struct AppDataEraseError: LocalizedError, Sendable {
    public let failures: [String]

    public var errorDescription: String? {
        "Some app data could not be erased:\n" + failures.map { "• \($0)" }.joined(separator: "\n")
    }
}

public extension AppContainer {
    /// Coordinated chat-only erase used by Settings. Generation and every autosave that predates the
    /// request are drained before ConversationStore removes files; new snapshots are gated until the
    /// result is known, so a success cannot be undone by a late fire-and-forget save.
    func deleteAllChats() async throws {
        await chat.quiesceForConversationErase()
        do {
            try await conversationStore.deleteAll()
            chat.finishConversationErase(succeeded: true, resetSessionState: false)
        } catch {
            chat.finishConversationErase(succeeded: false, resetSessionState: false)
            throw error
        }
    }

    /// Return the running container to a fresh-install data state. Generation is stopped first, active
    /// weights and downloads are drained before their exact app-owned directory is removed, and every
    /// independent store is attempted so one filesystem error cannot strand unrelated private data.
    func eraseAllAppData() async throws {
        await chat.quiesceForConversationErase()
        var failures: [String] = []
        var conversationsErased = false

        do {
            try await models.eraseDownloadedData()
        } catch {
            failures.append("Models: \(error.localizedDescription)")
        }
        syncActive()

        do {
            try await conversationStore.deleteAll()
            conversationsErased = true
        } catch {
            failures.append("Chats and attachments: \(error.localizedDescription)")
        }

        do {
            try await memory.deleteAll()
        } catch {
            failures.append("Memory: \(error.localizedDescription)")
        }

        do {
            try await skills.resetForDataErase()
        } catch {
            failures.append("Custom skills: \(error.localizedDescription)")
        }

        do {
            try settings.resetForDataErase()
        } catch {
            failures.append("Settings or MCP credentials: \(error.localizedDescription)")
        }

        chat.finishConversationErase(succeeded: conversationsErased, resetSessionState: true)
        if !failures.isEmpty { throw AppDataEraseError(failures: failures) }
    }
}

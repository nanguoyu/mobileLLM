// SPDX-License-Identifier: MIT

import AgentRuntime
import Foundation

/// Main-actor settings update this box; background tool execution resolves only the exact frozen identity.
final class OpenSandboxConfigurationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: OpenSandboxCredentials?
    func update(connection: OpenSandboxConnection?, key: String?) {
        lock.withLock {
            value = connection.flatMap { connection in
                key.flatMap { $0.isEmpty ? nil : OpenSandboxCredentials(connection: connection, apiKey: $0) }
            }
        }
    }
    func credentials(for fingerprint: String) -> OpenSandboxCredentials? {
        lock.withLock { value?.connection.fingerprint.rawValue == fingerprint ? value : nil }
    }
}

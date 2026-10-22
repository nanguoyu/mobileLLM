// SPDX-License-Identifier: MIT

import Foundation

/// Isolated on-disk stores for opt-in online UI cases. Uses the production stores and Keychain.
struct UITestStorageScope {
    let root: URL
    let defaultsDomain: String
    var defaults: UserDefaults { UserDefaults(suiteName: defaultsDomain)! }
    var credentialService: String { defaultsDomain + ".openai" }

    static func current(relativeTo base: URL) -> Self? {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard env["MOBILELLM_DEVICE_E2E"] == "1",
              let raw = env["MOBILELLM_E2E_STORAGE_NAMESPACE"], let id = UUID(uuidString: raw) else { return nil }
        return Self(root: base.appending(path: "UITestSessions/" + id.uuidString),
                    defaultsDomain: "mobileLLM.ui-tests." + id.uuidString)
        #else
        return nil
        #endif
    }
}

// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

/// Shared reversible tool aliases for local and online model transports.
enum ModelToolNames {
    static func bindings(
        for descriptors: [AgentToolDescriptor]
    ) -> [LocalModelToolBinding] {
        let nameCounts = Dictionary(grouping: descriptors, by: { $0.id.logicalID.name })
            .mapValues(\.count)
        return descriptors.enumerated().map { index, descriptor in
            let name = descriptor.id.logicalID.name
            if nameCounts[name] == 1, isSafeWireName(name) {
                return LocalModelToolBinding(wireName: name, descriptor: descriptor)
            }
            let digest = StableDigest.fingerprint(
                domain: "local-model-tool-alias.v1",
                components: [Data(descriptor.id.logicalID.description.utf8)]
            ).rawValue.prefix(10)
            let stem = sanitizedStem(name)
            return LocalModelToolBinding(
                wireName: "tool_\(index + 1)_\(stem)_\(digest)",
                descriptor: descriptor
            )
        }
    }

    private static func isSafeWireName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 64,
              let first = name.unicodeScalars.first,
              isASCIIAlpha(first) || first == "_"
        else { return false }
        return name.unicodeScalars.dropFirst().allSatisfy {
            isASCIIAlpha($0) || (0x30 ... 0x39).contains($0.value)
                || $0 == "_" || $0 == "-" || $0 == "."
        }
    }

    private static func sanitizedStem(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            if isASCIIAlpha(scalar) || (0x30 ... 0x39).contains(scalar.value) || scalar == "_" {
                result.unicodeScalars.append(scalar)
            } else if result.last != "_" {
                result.append("_")
            }
            if result.utf8.count >= 24 { break }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? "call" : trimmed
    }

    private static func isASCIIAlpha(_ scalar: Unicode.Scalar) -> Bool {
        (0x41 ... 0x5A).contains(scalar.value) || (0x61 ... 0x7A).contains(scalar.value)
    }
}

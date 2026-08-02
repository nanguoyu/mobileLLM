// SPDX-License-Identifier: MIT

import Foundation

/// The only accepted durable representation for Memory shown to a model.
///
/// The English meaning is established by the remember-tool schema. This value supplies the deterministic,
/// offline boundary around that contract: one canonical prefix, one line, an English/Latin scaffold, and a
/// deliberately narrow exception for a terminal CJK personal name. It never consults the device locale,
/// performs network I/O, or starts a model.
public struct CanonicalMemoryText: Hashable, Codable, Sendable, CustomStringConvertible {
    public static let policyRevision: UInt32 = 1
    public static let canonicalPrefix = "The user "

    public let value: String
    public var description: String { value }

    public init(_ candidate: String) throws {
        let note = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { throw CanonicalMemoryValidationError.empty }
        guard !note.contains(where: \.isNewline) else {
            throw CanonicalMemoryValidationError.multiline
        }

        let canonical: String
        if note.hasPrefix(Self.canonicalPrefix) {
            canonical = note
        } else if note.hasPrefix("The user's ") {
            let fact = String(note.dropFirst("The user's ".count))
            guard !fact.isEmpty else { throw CanonicalMemoryValidationError.emptyBody }
            canonical = "The user says their \(fact)"
        } else if note.hasPrefix("The user’s ") {
            let fact = String(note.dropFirst("The user’s ".count))
            guard !fact.isEmpty else { throw CanonicalMemoryValidationError.emptyBody }
            canonical = "The user says their \(fact)"
        } else {
            throw CanonicalMemoryValidationError.missingCanonicalPrefix
        }

        let body = String(canonical.dropFirst(Self.canonicalPrefix.count))
        guard let first = body.unicodeScalars.first,
              Self.isLatinOrASCII(first),
              body.unicodeScalars.contains(where: Self.isASCIILetter)
        else { throw CanonicalMemoryValidationError.invalidEnglishScaffold }

        let scalars = Array(body.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if Self.isCJK(scalar) {
                let prefix = String(decoding: scalars[..<index].map(\.value), as: UTF32.self)
                guard Self.cjkMayBeProperName(after: prefix) else {
                    throw CanonicalMemoryValidationError.nonEnglishProse
                }

                let nameStart = index
                while index < scalars.count, Self.isCJK(scalars[index]) { index += 1 }
                let nameLength = index - nameStart
                guard (1 ... 4).contains(nameLength),
                      scalars[index...].allSatisfy(Self.isAllowedAfterCJKName)
                else { throw CanonicalMemoryValidationError.nonEnglishProse }
                self.value = canonical
                return
            }
            if scalar.properties.isAlphabetic, !Self.isLatinOrASCII(scalar) {
                throw CanonicalMemoryValidationError.nonEnglishProse
            }
            index += 1
        }
        value = canonical
    }

    /// Certifies an already-persisted value without rewriting it. Legacy natural-possessive or padded
    /// records remain readable but unverified until the user explicitly saves a canonical edit.
    public static func certifiesStoredText(_ text: String) -> Bool {
        let stored = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard stored == text else { return false }
        guard let canonical = try? Self(stored) else { return false }
        return canonical.value == stored
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(container.decode(String.self))
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: String(describing: error)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    private static func isLatinOrASCII(_ scalar: UnicodeScalar) -> Bool {
        scalar.isASCII || (0x00C0 ... 0x024F).contains(scalar.value)
    }

    private static func isASCIILetter(_ scalar: UnicodeScalar) -> Bool {
        (0x41 ... 0x5A).contains(scalar.value) || (0x61 ... 0x7A).contains(scalar.value)
    }

    private static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xF900 ... 0xFAFF,
             0x20000 ... 0x2FA1F, 0x3040 ... 0x30FF, 0xAC00 ... 0xD7AF:
            return true
        default:
            return false
        }
    }

    private static func isAllowedAfterCJKName(_ scalar: UnicodeScalar) -> Bool {
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return true }
        switch scalar.value {
        case 0x0021, 0x0022, 0x0027, 0x0029, 0x002E, 0x003F, 0x005D,
             0x3002, 0x300D, 0x300F, 0x3011, 0xFF01, 0xFF09, 0xFF1F,
             0x2019, 0x201D:
            return true
        default:
            return false
        }
    }

    private static func cjkMayBeProperName(after prefix: String) -> Bool {
        let normalized = prefix.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return ["named", "called", "name is", "goes by", "known as"].contains {
            normalized.hasSuffix($0)
        }
    }
}

public enum CanonicalMemoryValidationError: LocalizedError, Hashable, Sendable {
    case empty
    case multiline
    case missingCanonicalPrefix
    case emptyBody
    case invalidEnglishScaffold
    case nonEnglishProse

    public var errorDescription: String? {
        switch self {
        case .empty:
            "Memory cannot be empty."
        case .multiline:
            "Memory must be one concise sentence."
        case .missingCanonicalPrefix:
            "Write the memory in English, beginning with \"The user \"."
        case .emptyBody, .invalidEnglishScaffold:
            "Add an English fact after \"The user \"."
        case .nonEnglishProse:
            "Translate the full fact into English. Proper names may stay unchanged."
        }
    }
}

/// Certification attached to every durable record. Unverified legacy records remain user-manageable but
/// are never eligible for model context or recall.
public enum MemoryCanonicalizationStatus: String, Codable, Sendable, Hashable {
    case canonicalEnglishV1
    case legacyUnverified
}

/// An immutable, already-ranked view of the canonical records eligible for a model run.
public struct CanonicalMemorySnapshot: Codable, Sendable, Hashable {
    public static let formatVersion: UInt16 = 1

    public let version: UInt16
    public let canonicalizationPolicyRevision: UInt32
    public let rankingPolicyRevision: UInt32
    public let facts: [MemoryFact]

    public init(facts: [MemoryFact]) {
        version = Self.formatVersion
        canonicalizationPolicyRevision = CanonicalMemoryText.policyRevision
        rankingPolicyRevision = MemoryRanking.policyRevision
        self.facts = facts.filter(\.isCanonicalEnglish)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodedVersion = try container.decode(UInt16.self, forKey: .version)
        let canonicalizationRevision = try container.decode(
            UInt32.self,
            forKey: .canonicalizationPolicyRevision
        )
        let rankingRevision = try container.decode(UInt32.self, forKey: .rankingPolicyRevision)
        let facts = try container.decode([MemoryFact].self, forKey: .facts)
        guard encodedVersion == Self.formatVersion,
              canonicalizationRevision == CanonicalMemoryText.policyRevision,
              rankingRevision == MemoryRanking.policyRevision,
              facts.allSatisfy(\.isCanonicalEnglish),
              Set(facts.map(\.id)).count == facts.count
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid canonical Memory snapshot")
            )
        }
        self.init(facts: facts)
    }

    private enum CodingKeys: String, CodingKey {
        case version, canonicalizationPolicyRevision, rankingPolicyRevision, facts
    }
}

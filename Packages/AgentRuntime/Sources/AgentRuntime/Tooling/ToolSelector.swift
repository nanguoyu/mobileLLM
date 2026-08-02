// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

/// Complete frozen input to deterministic per-pass tool selection.
public struct ToolSelectionInput: Hashable, Codable, Sendable {
    public let policy: ConversationToolPolicy
    public let catalog: ToolCatalogSnapshot
    public let availableCapabilities: AgentCapabilitySet
    public let latestUserRequest: String
    public let attachmentMIMETypes: [String]
    public let activeSkillToolHints: [AgentToolLogicalID]
    public let recentSuccessfulToolChain: [AgentToolLogicalID]
    public let explicitlyRequestedToolIDs: [AgentToolLogicalID]
    public let maximumAdvertisedTools: UInt16

    public init(
        policy: ConversationToolPolicy,
        catalog: ToolCatalogSnapshot,
        availableCapabilities: AgentCapabilitySet,
        latestUserRequest: String,
        attachmentMIMETypes: some Sequence<String> = [],
        activeSkillToolHints: some Sequence<AgentToolLogicalID> = [],
        recentSuccessfulToolChain: [AgentToolLogicalID] = [],
        explicitlyRequestedToolIDs: some Sequence<AgentToolLogicalID> = [],
        maximumAdvertisedTools: UInt16 = 5
    ) throws {
        let attachments = Array(Set(attachmentMIMETypes)).sorted()
        let skillHints = Array(Set(activeSkillToolHints)).sorted()
        let explicit = Array(Set(explicitlyRequestedToolIDs)).sorted()
        guard latestUserRequest.utf8.count <= 1_048_576,
              (1 ... 64).contains(maximumAdvertisedTools),
              attachments.allSatisfy(Self.isMIMEType),
              recentSuccessfulToolChain.count <= 64
        else { throw ToolSelectionError.invalidInput }
        self.policy = policy
        self.catalog = catalog
        self.availableCapabilities = availableCapabilities
        self.latestUserRequest = latestUserRequest
        self.attachmentMIMETypes = attachments
        self.activeSkillToolHints = skillHints
        self.recentSuccessfulToolChain = recentSuccessfulToolChain
        self.explicitlyRequestedToolIDs = explicit
        self.maximumAdvertisedTools = maximumAdvertisedTools
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let attachments = try container.decode([String].self, forKey: .attachmentMIMETypes)
        let skillHints = try container.decode([AgentToolLogicalID].self, forKey: .activeSkillToolHints)
        let recent = try container.decode([AgentToolLogicalID].self, forKey: .recentSuccessfulToolChain)
        let explicit = try container.decode([AgentToolLogicalID].self, forKey: .explicitlyRequestedToolIDs)
        do {
            try self.init(
                policy: container.decode(ConversationToolPolicy.self, forKey: .policy),
                catalog: container.decode(ToolCatalogSnapshot.self, forKey: .catalog),
                availableCapabilities: container.decode(AgentCapabilitySet.self, forKey: .availableCapabilities),
                latestUserRequest: container.decode(String.self, forKey: .latestUserRequest),
                attachmentMIMETypes: attachments,
                activeSkillToolHints: skillHints,
                recentSuccessfulToolChain: recent,
                explicitlyRequestedToolIDs: explicit,
                maximumAdvertisedTools: container.decode(UInt16.self, forKey: .maximumAdvertisedTools)
            )
            guard attachmentMIMETypes == attachments,
                  activeSkillToolHints == skillHints,
                  explicitlyRequestedToolIDs == explicit
            else { throw ToolSelectionError.invalidInput }
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    fileprivate var digest: StableDigest {
        var components: [Data] = [
            Data(String(policy.masterEnabled).utf8),
            Data(String(policy.selectionPolicyVersion).utf8),
            Data(String(policy.materializedFromGlobalTemplate).utf8),
            Data(String(catalog.revision).utf8),
            Data(latestUserRequest.utf8),
            Data(String(maximumAdvertisedTools).utf8),
            Data(availableCapabilities.fingerprint.rawValue.utf8),
        ]
        components += policy.allowedToolIDs.map { Data("allowed:\($0.description)".utf8) }
        components += policy.pinnedToolIDs.map { Data("pinned:\($0.description)".utf8) }
        components += catalog.descriptors.map { Data("descriptor:\($0.id.description)".utf8) }
        components += catalog.unavailable.map {
            Data("unavailable:\($0.logicalID.description):\($0.reason.rawValue)".utf8)
        }
        components += attachmentMIMETypes.map { Data("attachment:\($0)".utf8) }
        components += activeSkillToolHints.map { Data("skill:\($0.description)".utf8) }
        components += recentSuccessfulToolChain.map { Data("recent:\($0.description)".utf8) }
        components += explicitlyRequestedToolIDs.map { Data("explicit:\($0.description)".utf8) }
        return StableDigest.fingerprint(domain: "tool-selector-input.v1", components: components)
    }

    private static func isMIMEType(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return value == value.lowercased()
            && value.utf8.count <= 127
            && parts.count == 2
            && parts.allSatisfy {
                !$0.isEmpty && $0.allSatisfy { $0.isASCII && !$0.isWhitespace }
            }
    }

    private enum CodingKeys: String, CodingKey {
        case policy, catalog, availableCapabilities, latestUserRequest, attachmentMIMETypes
        case activeSkillToolHints, recentSuccessfulToolChain, explicitlyRequestedToolIDs
        case maximumAdvertisedTools
    }
}

/// Exact selected descriptors plus unavailable allowed tools retained for UI inspection.
public struct ToolSelectionResult: Hashable, Codable, Sendable {
    public let snapshot: AgentToolSelectionSnapshot
    public let descriptors: [AgentToolDescriptor]
    public let unavailable: [UnavailableTool]

    public init(
        snapshot: AgentToolSelectionSnapshot,
        descriptors: [AgentToolDescriptor],
        unavailable: [UnavailableTool]
    ) throws {
        guard snapshot.decisions.map(\.descriptorID) == descriptors.map(\.id),
              unavailable == Array(Set(unavailable)).sorted()
        else { throw ToolSelectionError.invalidInput }
        self.snapshot = snapshot
        self.descriptors = descriptors
        self.unavailable = unavailable
    }
}

/// Pure deterministic selector. It can narrow user authority but has no API capable of expanding it
/// or performing model inference/tool execution.
public struct DeterministicToolSelector: Sendable {
    public static let selectorID = "mobilellm.selector-v1"

    public init() {}

    public func select(_ input: ToolSelectionInput) throws -> ToolSelectionResult {
        let allowed = Set(input.policy.allowedToolIDs)
        let pinned = Set(input.policy.pinnedToolIDs)
        let skillHints = Set(input.activeSkillToolHints)
        let explicit = Set(input.explicitlyRequestedToolIDs)
        let recentRanks = Dictionary(
            input.recentSuccessfulToolChain.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: min
        )
        let catalogByLogicalID = Dictionary(
            uniqueKeysWithValues: input.catalog.descriptors.map { ($0.id.logicalID, $0) }
        )
        let unavailableByLogicalID = Dictionary(
            uniqueKeysWithValues: input.catalog.unavailable.map { ($0.logicalID, $0.reason) }
        )

        var unavailable: [UnavailableTool] = []
        for logicalID in input.policy.allowedToolIDs {
            if let reason = unavailableByLogicalID[logicalID] {
                unavailable.append(UnavailableTool(logicalID: logicalID, reason: reason))
            } else if let descriptor = catalogByLogicalID[logicalID] {
                if !descriptor.requiredCapabilities.isSubset(of: input.availableCapabilities) {
                    unavailable.append(
                        UnavailableTool(logicalID: logicalID, reason: .capabilityUnavailable)
                    )
                }
            } else {
                unavailable.append(UnavailableTool(logicalID: logicalID, reason: .descriptorMissing))
            }
        }

        guard input.policy.masterEnabled else {
            let snapshot = try AgentToolSelectionSnapshot(
                selectorID: Self.selectorID,
                policyVersion: input.policy.selectionPolicyVersion,
                inputDigest: input.digest,
                decisions: []
            )
            return try ToolSelectionResult(
                snapshot: snapshot,
                descriptors: [],
                unavailable: unavailable.sorted()
            )
        }

        let unavailableIDs = Set(unavailable.map(\.logicalID))
        let requestTokens = Self.tokens(in: input.latestUserRequest)
        var candidates: [Candidate] = []
        for descriptor in input.catalog.descriptors {
            let logicalID = descriptor.id.logicalID
            guard allowed.contains(logicalID), !unavailableIDs.contains(logicalID) else { continue }
            var reasons: Set<String> = []
            var score = 0
            if pinned.contains(logicalID) {
                score += 10_000
                reasons.insert("user.pinned")
            }
            if explicit.contains(logicalID) || Self.isExplicitlyNamed(descriptor, in: input.latestUserRequest) {
                score += 8_000
                reasons.insert("request.explicit")
            }
            if skillHints.contains(logicalID) {
                score += 4_000
                reasons.insert("skill.hint")
            }
            if let rank = recentRanks[logicalID] {
                score += max(1, 1_000 - rank)
                reasons.insert("chain.recent")
            }
            let lexicalMatches = Self.lexicalScore(descriptor: descriptor, requestTokens: requestTokens)
            if lexicalMatches > 0 {
                score += lexicalMatches
                reasons.insert("request.semantic")
            }

            // Images are model input, not a reason to browse. Network tools require a positive,
            // request-derived signal; an attachment or generic phrase such as “what's this?” never
            // selects Web Search by itself.
            let isNetworkTool = descriptor.effects.contains(.networkRead)
                || descriptor.effects.contains(.unknownExternal)
            let hasStrongNetworkSignal = reasons.contains("request.explicit")
                || (reasons.contains("request.semantic") && Self.hasNetworkIntent(requestTokens))
                || reasons.contains("user.pinned")
                || reasons.contains("skill.hint")
            if isNetworkTool, !hasStrongNetworkSignal { continue }
            guard score > 0 else { continue }
            candidates.append(
                Candidate(descriptor: descriptor, score: score, reasons: reasons.sorted())
            )
        }

        candidates.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.descriptor.id < $1.descriptor.id
        }
        let selected = Array(candidates.prefix(Int(input.maximumAdvertisedTools)))
        let decisions = try selected.map {
            try AgentToolSelectionDecision(
                descriptorID: $0.descriptor.id,
                rationaleCodes: $0.reasons
            )
        }
        let snapshot = try AgentToolSelectionSnapshot(
            selectorID: Self.selectorID,
            policyVersion: input.policy.selectionPolicyVersion,
            inputDigest: input.digest,
            decisions: decisions
        )
        return try ToolSelectionResult(
            snapshot: snapshot,
            descriptors: selected.map(\.descriptor),
            unavailable: unavailable.sorted()
        )
    }

    private struct Candidate {
        let descriptor: AgentToolDescriptor
        let score: Int
        let reasons: [String]
    }

    private static func isExplicitlyNamed(
        _ descriptor: AgentToolDescriptor,
        in request: String
    ) -> Bool {
        let request = asciiLowercased(request)
        let names = [descriptor.id.logicalID.name, descriptor.title]
            .map(asciiLowercased)
            .filter { $0.utf8.count >= 3 }
        return names.contains { request.contains($0) }
    }

    private static func lexicalScore(
        descriptor: AgentToolDescriptor,
        requestTokens: Set<String>
    ) -> Int {
        guard !requestTokens.isEmpty else { return 0 }
        let descriptorTokens = tokens(
            in: descriptor.id.logicalID.name + " " + descriptor.title + " " + descriptor.summary
        ).subtracting(stopWords)
        return requestTokens.subtracting(stopWords).intersection(descriptorTokens).count * 20
    }

    private static func hasNetworkIntent(_ tokens: Set<String>) -> Bool {
        !tokens.isDisjoint(with: networkIntentTokens)
    }

    private static func tokens(in value: String) -> Set<String> {
        let normalized = asciiLowercased(value)
        return Set(normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    private static func asciiLowercased(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar in
            if (65 ... 90).contains(scalar.value),
               let lowered = UnicodeScalar(scalar.value + 32)
            {
                return Character(lowered)
            }
            return Character(scalar)
        })
    }

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "can", "do", "for", "from", "how", "i", "in", "is",
        "it", "me", "my", "of", "on", "please", "the", "this", "to", "tool", "what",
        "with", "you",
    ]

    private static let networkIntentTokens: Set<String> = [
        "browse", "current", "internet", "latest", "lookup", "news", "online", "search",
        "source", "sources", "today", "web", "website",
    ]
}

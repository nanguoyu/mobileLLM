// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

/// Durable user intent for which tools a conversation may expose to its model.
///
/// Logical identifiers intentionally survive compatible descriptor upgrades. Exact descriptor
/// identifiers are resolved and frozen separately for every run.
public struct ConversationToolPolicy: Hashable, Codable, Sendable {
    public let masterEnabled: Bool
    public let allowedToolIDs: [AgentToolLogicalID]
    public let pinnedToolIDs: [AgentToolLogicalID]
    public let selectionPolicyVersion: UInt32
    public let materializedFromGlobalTemplate: Bool

    public init(
        masterEnabled: Bool,
        allowedToolIDs: some Sequence<AgentToolLogicalID>,
        pinnedToolIDs: some Sequence<AgentToolLogicalID> = [],
        selectionPolicyVersion: UInt32,
        materializedFromGlobalTemplate: Bool
    ) throws {
        let allowed = Array(Set(allowedToolIDs)).sorted()
        let pinned = Array(Set(pinnedToolIDs)).sorted()
        guard selectionPolicyVersion > 0,
              Set(pinned).isSubset(of: Set(allowed))
        else { throw ToolSelectionError.invalidConversationPolicy }
        self.masterEnabled = masterEnabled
        self.allowedToolIDs = allowed
        self.pinnedToolIDs = pinned
        self.selectionPolicyVersion = selectionPolicyVersion
        self.materializedFromGlobalTemplate = materializedFromGlobalTemplate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodedAllowed = try container.decode([AgentToolLogicalID].self, forKey: .allowedToolIDs)
        let encodedPinned = try container.decode([AgentToolLogicalID].self, forKey: .pinnedToolIDs)
        do {
            try self.init(
                masterEnabled: container.decode(Bool.self, forKey: .masterEnabled),
                allowedToolIDs: encodedAllowed,
                pinnedToolIDs: encodedPinned,
                selectionPolicyVersion: container.decode(UInt32.self, forKey: .selectionPolicyVersion),
                materializedFromGlobalTemplate: container.decode(
                    Bool.self,
                    forKey: .materializedFromGlobalTemplate
                )
            )
            guard allowedToolIDs == encodedAllowed, pinnedToolIDs == encodedPinned else {
                throw ToolSelectionError.invalidConversationPolicy
            }
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case masterEnabled, allowedToolIDs, pinnedToolIDs, selectionPolicyVersion
        case materializedFromGlobalTemplate
    }
}

/// A locally trusted reason why one allowed logical tool is unavailable for a pass.
public enum ToolUnavailabilityReason: String, CaseIterable, Hashable, Codable, Sendable {
    case descriptorMissing
    case providerUnavailable
    case capabilityUnavailable
    case schemaIncompatible
    case trustRevisionChanged
    case sandboxProviderAbsent
}

/// One unavailable logical tool retained for inspection instead of silently disappearing.
public struct UnavailableTool: Hashable, Codable, Sendable, Comparable {
    public let logicalID: AgentToolLogicalID
    public let reason: ToolUnavailabilityReason

    public init(logicalID: AgentToolLogicalID, reason: ToolUnavailabilityReason) {
        self.logicalID = logicalID
        self.reason = reason
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.logicalID != rhs.logicalID { return lhs.logicalID < rhs.logicalID }
        return lhs.reason.rawValue < rhs.reason.rawValue
    }
}

/// An immutable exact-descriptor catalog snapshot. A logical tool has exactly one active revision.
public struct ToolCatalogSnapshot: Hashable, Codable, Sendable {
    public let revision: UInt64
    public let descriptors: [AgentToolDescriptor]
    public let unavailable: [UnavailableTool]

    public init(
        revision: UInt64,
        descriptors: [AgentToolDescriptor],
        unavailable: some Sequence<UnavailableTool> = []
    ) throws {
        let sortedDescriptors = descriptors.sorted { $0.id < $1.id }
        let sortedUnavailable = Array(Set(unavailable)).sorted()
        let descriptorLogicalIDs = sortedDescriptors.map(\.id.logicalID)
        let unavailableLogicalIDs = sortedUnavailable.map(\.logicalID)
        guard revision > 0,
              Set(descriptorLogicalIDs).count == descriptorLogicalIDs.count,
              Set(unavailableLogicalIDs).count == unavailableLogicalIDs.count,
              Set(descriptorLogicalIDs).isDisjoint(with: Set(unavailableLogicalIDs))
        else { throw ToolSelectionError.invalidCatalog }
        self.revision = revision
        self.descriptors = sortedDescriptors
        self.unavailable = sortedUnavailable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodedDescriptors = try container.decode([AgentToolDescriptor].self, forKey: .descriptors)
        let encodedUnavailable = try container.decode([UnavailableTool].self, forKey: .unavailable)
        do {
            try self.init(
                revision: container.decode(UInt64.self, forKey: .revision),
                descriptors: encodedDescriptors,
                unavailable: encodedUnavailable
            )
            guard descriptors == encodedDescriptors, unavailable == encodedUnavailable else {
                throw ToolSelectionError.invalidCatalog
            }
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    public func descriptor(for logicalID: AgentToolLogicalID) -> AgentToolDescriptor? {
        descriptors.first { $0.id.logicalID == logicalID }
    }

    private enum CodingKeys: String, CodingKey { case revision, descriptors, unavailable }
}

/// Catalog adapters expose only an already materialized local snapshot. Implementations must not
/// perform discovery or external I/O from this method.
public protocol ToolCatalog: Sendable {
    func localSnapshot() async throws -> ToolCatalogSnapshot
}

/// Immutable catalog useful for built-in tools and deterministic tests.
public struct StaticToolCatalog: ToolCatalog, Sendable {
    public let snapshot: ToolCatalogSnapshot

    public init(snapshot: ToolCatalogSnapshot) { self.snapshot = snapshot }

    public func localSnapshot() async throws -> ToolCatalogSnapshot { snapshot }
}

public enum ToolSelectionError: Error, Hashable, Sendable {
    case invalidConversationPolicy
    case invalidCatalog
    case invalidInput
}

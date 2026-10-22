// SPDX-License-Identifier: MIT

import Foundation

/// Provider state needed to return a tool result to the exact model selection that requested it.
/// Persisted with the proposed call and included in context budgeting and authorization digests.
public struct NativeToolCallContext: Hashable, Codable, Sendable {
    public let selectionDigest: StableDigest
    public let callID: String
    public let name: String
    public let arguments: CanonicalJSON
    public let reasoningItems: [JSONValue]
    public let reasoningText: String?

    public init(selectionDigest: StableDigest, callID: String, name: String,
                arguments: CanonicalJSON, reasoningItems: [JSONValue] = [], reasoningText: String? = nil) throws {
        guard !callID.isEmpty, callID.utf8.count <= 256, !name.isEmpty, name.utf8.count <= 64,
              reasoningItems.count <= 32,
              reasoningItems.allSatisfy({ item in
                  guard case .object(let object) = item else { return false }
                  return object["type"] == .string("reasoning")
              }),
              (reasoningText?.utf8.count ?? 0) <= 1_048_576,
              try JSONValue.array(reasoningItems).canonicalData().count <= 1_048_576
        else { throw AgentContractError.invalidName("invalid native tool continuation") }
        self.selectionDigest = selectionDigest
        self.callID = callID
        self.name = name
        self.arguments = arguments
        self.reasoningItems = reasoningItems
        self.reasoningText = reasoningText
    }

    public static func digest(for selection: AgentModelSelection) throws -> StableDigest {
        let value = try AgentWireDecoder.decode(JSONValue.self, from: JSONEncoder().encode(selection), limits: .inlineValue)
        return try CanonicalJSON(value).fingerprint
    }

    public func matches(_ selection: AgentModelSelection) -> Bool {
        (try? Self.digest(for: selection)) == selectionDigest
    }

    public var authorizationValue: JSONValue {
        .object([
            "selectionDigest": .string(selectionDigest.rawValue), "callID": .string(callID),
            "name": .string(name), "arguments": .string(arguments.string),
            "reasoningItems": .array(reasoningItems), "reasoningText": reasoningText.map(JSONValue.string) ?? .null,
        ])
    }

    public var functionCallItem: JSONValue {
        .object(["type": .string("function_call"), "call_id": .string(callID),
                 "name": .string(name), "arguments": .string(arguments.string)])
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(selectionDigest: c.decode(StableDigest.self, forKey: .selectionDigest),
                      callID: c.decode(String.self, forKey: .callID), name: c.decode(String.self, forKey: .name),
                      arguments: c.decode(CanonicalJSON.self, forKey: .arguments),
                      reasoningItems: c.decodeIfPresent([JSONValue].self, forKey: .reasoningItems) ?? [],
                      reasoningText: c.decodeIfPresent(String.self, forKey: .reasoningText))
    }
    private enum CodingKeys: String, CodingKey { case selectionDigest, callID, name, arguments, reasoningItems, reasoningText }
}

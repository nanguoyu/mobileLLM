// SPDX-License-Identifier: MIT

import Foundation
import AgentContracts

/// Versioned outbox content. The non-UTF8 prefix cannot collide with legacy plain-text messages.
public struct AcceptedUserMessagePayload: Codable, Sendable {
    public let text: String
    public let attachments: [ArtifactReference]
    private static let marker = Data([0xff, 0x4d, 0x55, 0x32])

    public init(text: String, attachments: [ArtifactReference] = []) throws {
        guard text.utf8.count <= 8 * 1_024 * 1_024, attachments.count <= 64,
              Set(attachments.map(\.id)).count == attachments.count else {
            throw AgentExecutionError.internalInvariant("invalid accepted user message")
        }
        self.text = text
        self.attachments = attachments
    }
    public func encoded() throws -> Data { Self.marker + (try ExecutionEncoding.encode(self)) }
    public static func decode(_ data: Data) throws -> Self {
        if data.starts(with: marker) {
            return try AgentWireDecoder.decode(Self.self, from: Data(data.dropFirst(marker.count)), limits: .inlineValue)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw AgentExecutionError.internalInvariant("invalid legacy user message")
        }
        return try Self(text: text)
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(text: c.decode(String.self, forKey: .text),
                      attachments: c.decode([ArtifactReference].self, forKey: .attachments))
    }
    private enum CodingKeys: String, CodingKey { case text, attachments }
}

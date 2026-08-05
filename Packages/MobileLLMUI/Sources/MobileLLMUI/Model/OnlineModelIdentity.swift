// SPDX-License-Identifier: MIT

import Foundation

/// Stable identity for the OpenAI-compatible online model selection. The app keeps ONE online service
/// (base URL + key + model id) and treats it as a first-class model choice: no local weights are ever
/// loaded, but conversations still remember which service/model answered so reopening a thread restores
/// the same selection. Must stay in lockstep with `AppFrozenInputBuilder.onlineProviderID` /
/// `ResponsesAPIModelProvider.providerID`.
public enum OnlineModelIdentity {
    /// Stable provider id used by the agent runtime's Responses provider.
    public static let providerID = "openai.responses"
    /// Stable variant id pinned for every online selection (the service model id is the real identity).
    public static let variantID = "responses.default"
    /// Conversation-level model-id prefix; service id and model follow the colons.
    public static let conversationModelIDPrefix = "online.responses:"

    /// The durable conversation model id for one service + model pair.
    public static func conversationModelID(_ serviceID: String, model: String) -> String {
        "\(conversationModelIDPrefix)\(serviceID):\(model)"
    }

    /// Splits an online conversation identity into (serviceID, model); nil for non-online ids.
    public static func serviceParts(fromConversationModelID modelID: String)
        -> (serviceID: String, model: String)?
    {
        guard modelID.hasPrefix(conversationModelIDPrefix) else { return nil }
        let tail = String(modelID.dropFirst(conversationModelIDPrefix.count))
        guard let colon = tail.firstIndex(of: ":") else { return nil }
        let serviceID = String(tail[..<colon])
        let model = String(tail[tail.index(after: colon)...])
        guard !serviceID.isEmpty, !model.isEmpty else { return nil }
        return (serviceID, model)
    }

    /// Human-facing label shown in the header, switcher, and stats footer.
    public static func displayLabel(_ serviceModel: String) -> String {
        "Online · \(serviceModel)"
    }
}

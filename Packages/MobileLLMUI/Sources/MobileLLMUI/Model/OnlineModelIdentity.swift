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
    /// Conversation-level model-id prefix; the service model id follows the colon.
    public static let conversationModelIDPrefix = "online.responses:"

    /// The durable conversation model id for one service model.
    public static func conversationModelID(_ serviceModel: String) -> String {
        conversationModelIDPrefix + serviceModel
    }

    /// The service model id when a conversation model id is an online selection, else nil.
    public static func serviceModel(fromConversationModelID modelID: String) -> String? {
        guard modelID.hasPrefix(conversationModelIDPrefix) else { return nil }
        let value = String(modelID.dropFirst(conversationModelIDPrefix.count))
        return value.isEmpty ? nil : value
    }

    /// Human-facing label shown in the header, switcher, and stats footer.
    public static func displayLabel(_ serviceModel: String) -> String {
        "Online · \(serviceModel)"
    }
}

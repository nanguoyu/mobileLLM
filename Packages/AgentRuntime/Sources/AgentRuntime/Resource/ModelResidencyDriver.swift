// SPDX-License-Identifier: MIT

import AgentContracts

/// The narrow, provider-neutral seam used to manage one local model residency.
///
/// Implementations must serialize their own engine internals and make all three operations
/// idempotent. In particular, `cancelAndDrain` and `unload` must succeed when the selection is
/// already quiescent or absent. `ResourceArbiter` deliberately owns policy, ordering, and lease
/// validity; a driver only performs the requested engine lifecycle operation.
public protocol ModelResidencyDriver: Sendable {
    /// Loads one exact model selection and returns only after it is ready for decoding.
    func load(selection: AgentModelSelection) async throws

    /// Requests cancellation and returns only after all decode work has reached a stable boundary.
    func cancelAndDrain(selection: AgentModelSelection) async throws

    /// Unloads a quiescent selection and returns only after its residency has ended.
    func unload(selection: AgentModelSelection) async throws
}

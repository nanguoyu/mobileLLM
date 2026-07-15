// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import MLXLLM
import MLXLMCommon
import LLMCore

/// Smoke seam: forces the MLXLLM + PrismML-fork mlx-swift graph to compile & link (Metal included).
/// The real `MLXLLMEngine: LLMCore.LLMEngine` lands once this graph is proven to build on-device.
public enum ForkLink {
    /// Touches the model factory so the linker keeps MLXLLM (and the fork's MLX core).
    public static func factoryReady() -> String {
        _ = LLMModelFactory.shared
        return "MLXLLM linked; LLMModelFactory ready. Catalog has \(LLMCatalog.all.count) models."
    }
}

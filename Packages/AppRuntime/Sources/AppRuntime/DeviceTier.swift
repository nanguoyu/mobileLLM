// SPDX-License-Identifier: MIT

import Foundation

/// Detected hardware class → memory budget. The budget here is a conservative static estimate; the
/// live decision uses `MemoryProbe.availableBytes()`. Quantization is per-variant, so there is no
/// default-precision field.
public struct DeviceTier: Sendable {
    public let physicalMemoryBytes: Int64
    public let isPhone: Bool

    public init(physicalMemoryBytes: Int64, isPhone: Bool) {
        self.physicalMemoryBytes = physicalMemoryBytes
        self.isPhone = isPhone
    }

    /// Conservative per-app working-set budget. iPhone ≈ jetsam half-RAM; Mac leaves room for
    /// the OS and other apps.
    public var memoryBudgetBytes: Int64 {
        if isPhone {
            return Int64(Double(physicalMemoryBytes) * 0.50)
        } else {
            return max(physicalMemoryBytes - 4_000_000_000, Int64(Double(physicalMemoryBytes) * 0.80))
        }
    }

    public static var current: DeviceTier {
        let mem = Int64(ProcessInfo.processInfo.physicalMemory)
        #if os(iOS)
        let phone = true
        #else
        let phone = false
        #endif
        return DeviceTier(physicalMemoryBytes: mem, isPhone: phone)
    }
}

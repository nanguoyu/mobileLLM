// SPDX-License-Identifier: MIT

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Jetsam-accurate memory introspection. `phys_footprint` is the value the OS compares
/// against the per-app limit; `os_proc_available_memory` is the real remaining budget.
/// (Pure Swift, no platform-specific UI.)
public enum MemoryProbe {

    /// Resident memory billed against the jetsam limit (bytes).
    public static func residentBytes() -> UInt64 {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
        #else
        return 0
        #endif
    }

    /// Bytes the app may still allocate before hitting its limit. Returns `.max` where the
    /// jetsam-style probe doesn't apply (e.g. macOS).
    public static func availableBytes() -> UInt64 {
        #if os(iOS) || os(visionOS) || targetEnvironment(macCatalyst)
        return UInt64(os_proc_available_memory())
        #else
        return .max
        #endif
    }

    public static func residentMB() -> Double { Double(residentBytes()) / 1_048_576 }
    public static func availableMB() -> Double {
        let b = availableBytes()
        return b == .max ? .infinity : Double(b) / 1_048_576
    }
}

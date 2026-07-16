// SPDX-License-Identifier: MIT

import Foundation
import LLMCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Asks the OS whether its own model can be used right now.
///
/// This is the app's only window onto `SystemLanguageModel.availability`, and it exists because that type
/// cannot be named below iOS 26 / macOS 26. App assembly injects `status` into the model layer, which
/// treats it as the install state of the `.appleSystem` backend: a system model is "installed" exactly
/// when the OS says it's available — never because something is on disk, because nothing ever is.
public enum AppleSystemModel {

    /// The live status. Safe to call on ANY OS: below iOS 26 / macOS 26 — or in a build whose SDK has no
    /// FoundationModels at all — it answers `.unavailable(.unsupportedOS)` instead of trapping. Nothing
    /// here touches the weak-linked framework outside the availability check, so the process still
    /// launches (and this still answers) on an OS that has never heard of it.
    public static func status() -> SystemModelStatus {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            return status(of: SystemLanguageModel.default.availability)
        }
        return .unavailable(.unsupportedOS)
        #else
        return .unavailable(.unsupportedOS)
        #endif
    }

    #if canImport(FoundationModels)
    /// Map the framework's availability onto our framework-free vocabulary.
    ///
    /// `UnavailableReason` is not a frozen enum, so a later OS may add a reason this build has never heard
    /// of. That becomes `.unknown` — an honest "can't use it, and I won't pretend to know why" — rather
    /// than being mislabelled as one of the three we do know, which would send the user to a Settings
    /// toggle that isn't the problem.
    @available(iOS 26, macOS 26, *)
    static func status(of availability: SystemLanguageModel.Availability) -> SystemModelStatus {
        switch availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unavailable(.deviceNotEligible)
            case .appleIntelligenceNotEnabled: return .unavailable(.notEnabled)
            case .modelNotReady: return .unavailable(.modelNotReady)
            @unknown default: return .unavailable(.unknown)
            }
        }
    }
    #endif
}

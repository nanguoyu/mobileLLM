// SPDX-License-Identifier: MIT

import Foundation

/// A one-shot location fix (framework-free, so the tool + tests never touch CoreLocation).
public struct LocationFix: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var accuracy: Double        // horizontal accuracy in meters
    public var locality: String?       // reverse-geocoded place name, when available
    public init(latitude: Double, longitude: Double, accuracy: Double, locality: String? = nil) {
        self.latitude = latitude; self.longitude = longitude; self.accuracy = accuracy; self.locality = locality
    }
}

/// Errors the location seam raises; the tool maps them to instructive strings.
public enum LocationError: Error, Sendable, Equatable {
    case denied
    case unavailable(String)
    case timeout
}

/// The authorization state of a privacy-gated tool's system permission — drives the Tools settings
/// screen's flip-the-toggle-and-ask flow (and the "it's off in system Settings" guidance).
public enum ToolPermission: Sendable, Equatable {
    case notDetermined
    case granted
    case denied
}

/// The CoreLocation seam. A real `CLLocationManager`-backed adapter conforms on-device; tests inject a fake.
public protocol LocationProviding: Sendable {
    func currentLocation() async throws -> LocationFix
    /// Current system authorization, without prompting.
    func permissionState() async -> ToolPermission
    /// Prompt the user if undetermined; resolves immediately when already decided.
    func requestPermission() async -> ToolPermission
}

/// Defaults keep test fakes and simple providers to the single fetch method.
public extension LocationProviding {
    func permissionState() async -> ToolPermission { .granted }
    func requestPermission() async -> ToolPermission { .granted }
}

/// Report the user's approximate current location. One-shot, ~100 m accuracy, short timeout — enough for
/// "what's near me" / weather / local-time questions without a precise-location prompt.
public struct CurrentLocationTool: Tool {
    private let provider: any LocationProviding
    public init(provider: any LocationProviding) { self.provider = provider }

    public var schema: ToolSchema {
        ToolSchema(name: "current_location",
                   description: "Get the user's approximate current location (city-level). Use for "
                              + "\"near me\", local weather, or where-am-I questions.",
                   parameters: [])
    }

    public func execute(argumentsJSON: String) async -> String {
        do {
            return Self.format(try await provider.currentLocation())
        } catch LocationError.denied {
            return "Location access is off — enable it in Settings to use your location."
        } catch LocationError.timeout {
            return "Couldn't get your location in time — please try again in a moment."
        } catch LocationError.unavailable(let why) {
            return "Location is unavailable right now (\(why))."
        } catch {
            return "Location is unavailable right now."
        }
    }

    /// "Locality — lat, lon (±Xm)", or just the coordinates when no place name resolved.
    static func format(_ fix: LocationFix) -> String {
        let coords = String(format: "%.5f, %.5f (±%dm)",
                            fix.latitude, fix.longitude, max(0, Int(fix.accuracy.rounded())))
        if let loc = fix.locality, !loc.isEmpty { return "\(loc) — \(coords)" }
        return coords
    }
}

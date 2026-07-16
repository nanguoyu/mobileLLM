// SPDX-License-Identifier: MIT

#if canImport(CoreLocation)
import Foundation
import CoreLocation

/// The real, on-device `LocationProviding` backed by `CLLocationManager`. A one-shot request at ~100 m
/// accuracy, with a hard timeout, plus a best-effort reverse-geocode for a place name. Not unit-tested —
/// device behavior only; LLMCore's tests drive `CurrentLocationTool` through a fake `LocationProviding`.
///
/// `@unchecked Sendable`: the manager work is marshaled onto the main queue and each call uses its own
/// one-shot delegate, so there is no shared mutable state across concurrent calls.
public final class CoreLocationProvider: LocationProviding, @unchecked Sendable {
    private let timeout: TimeInterval
    public init(timeout: TimeInterval = 8) { self.timeout = timeout }

    public func currentLocation() async throws -> LocationFix {
        let location: CLLocation = try await withCheckedThrowingContinuation { cont in
            OneShotLocationDelegate(continuation: cont, timeout: timeout).start()
        }
        let locality = (try? await CLGeocoder().reverseGeocodeLocation(location))?.first?.locality
        return LocationFix(latitude: location.coordinate.latitude,
                           longitude: location.coordinate.longitude,
                           accuracy: location.horizontalAccuracy,
                           locality: locality)
    }
}

/// One request → one resume. Retains itself until it resumes (so ARC doesn't drop it mid-request), enforces
/// its own timeout, and drives all `CLLocationManager` interaction on the main queue.
private final class OneShotLocationDelegate: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var selfRef: OneShotLocationDelegate?

    init(continuation: CheckedContinuation<CLLocation, Error>, timeout: TimeInterval) {
        self.continuation = continuation
        self.timeout = timeout
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func start() {
        selfRef = self   // stay alive until we resume the continuation
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(LocationError.timeout))
        }
        DispatchQueue.main.async { [self] in
            switch manager.authorizationStatus {
            case .denied, .restricted:
                finish(.failure(LocationError.denied))
            case .notDetermined:
                #if os(iOS)
                manager.requestWhenInUseAuthorization()
                #else
                manager.requestAlwaysAuthorization()
                #endif
            default:
                manager.requestLocation()
            }
        }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        guard let cont = continuation else { return }   // first resolution wins
        continuation = nil
        manager.delegate = nil
        cont.resume(with: result)
        selfRef = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .denied, .restricted: finish(.failure(LocationError.denied))
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        default: break   // still notDetermined — wait
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last { finish(.success(loc)) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(LocationError.unavailable(error.localizedDescription)))
    }
}
#endif

// SPDX-License-Identifier: MIT

#if canImport(CoreLocation)
import Foundation
import CoreLocation

/// The real, on-device `LocationProviding` backed by `CLLocationManager`. A one-shot request at ~100 m
/// accuracy, plus a best-effort reverse-geocode for a place name. Not unit-tested — device behavior only;
/// LLMCore's tests drive `CurrentLocationTool` through a fake `LocationProviding`.
///
/// Timeout discipline (learned on device): the fix timeout must NOT run while the system permission
/// dialog is up — the user's dialog-reading time was burning the whole budget, so the very first
/// grant-then-locate always "timed out". Authorization gets its own generous window; the fix clock
/// starts only when `requestLocation()` actually begins.
///
/// `@unchecked Sendable`: the manager work is marshaled onto the main queue and each call uses its own
/// one-shot delegate, so there is no shared mutable state across concurrent calls.
public final class CoreLocationProvider: LocationProviding, @unchecked Sendable {
    private let fixTimeout: TimeInterval
    public init(timeout: TimeInterval = 12) { self.fixTimeout = timeout }

    public func currentLocation() async throws -> LocationFix {
        let location: CLLocation = try await withCheckedThrowingContinuation { cont in
            // CLLocationManager MUST be created on a thread with an active run loop — it delivers its
            // delegate callbacks there. The tool runs inside the agent loop's Task (a cooperative-pool
            // thread with NO run loop), so constructing it inline meant didUpdateLocations never arrived
            // and every request died on the timeout: "permission granted, still no fix". Hop to main.
            let timeout = fixTimeout
            DispatchQueue.main.async {
                OneShotLocationDelegate(continuation: cont, fixTimeout: timeout).start()
            }
        }
        let locality = (try? await CLGeocoder().reverseGeocodeLocation(location))?.first?.locality
        return LocationFix(latitude: location.coordinate.latitude,
                           longitude: location.coordinate.longitude,
                           accuracy: location.horizontalAccuracy,
                           locality: locality)
    }

    public func permissionState() async -> ToolPermission {
        await MainActor.run {   // same run-loop rule as above
            switch CLLocationManager().authorizationStatus {
            case .notDetermined: .notDetermined
            case .denied, .restricted: .denied
            default: .granted
            }
        }
    }

    /// Prompt for While-Using authorization (resolves immediately if already decided). Used by the Tools
    /// settings screen so flipping the toggle asks the user right away, not at the first model call.
    public func requestPermission() async -> ToolPermission {
        await withCheckedContinuation { cont in
            DispatchQueue.main.async {
                AuthorizationOnlyDelegate(continuation: cont).start()
            }
        }
    }
}

/// One request → one resume. Retains itself until it resumes (so ARC doesn't drop it mid-request), and
/// drives all `CLLocationManager` interaction on the main queue.
private final class OneShotLocationDelegate: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    private let fixTimeout: TimeInterval
    /// The permission dialog can sit unanswered for a long time — this guard only prevents a leak.
    private let authTimeout: TimeInterval = 120
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var selfRef: OneShotLocationDelegate?
    private var fixStarted = false
    /// `requestLocation` can fail transiently with `locationUnknown` before the first real fix — retry
    /// within the budget instead of surfacing a bogus failure.
    private var retriesLeft = 2

    init(continuation: CheckedContinuation<CLLocation, Error>, fixTimeout: TimeInterval) {
        self.continuation = continuation
        self.fixTimeout = fixTimeout
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func start() {
        selfRef = self   // stay alive until we resume the continuation
        DispatchQueue.main.asyncAfter(deadline: .now() + authTimeout) { [weak self] in
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
                // The fix clock starts in locationManagerDidChangeAuthorization, AFTER the user answers.
            default:
                beginFix()
            }
        }
    }

    /// Start the actual location request — only now does the fix timeout begin counting.
    private func beginFix() {
        guard !fixStarted else { return }
        fixStarted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + fixTimeout) { [weak self] in
            self?.finish(.failure(LocationError.timeout))
        }
        manager.requestLocation()
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
        case .authorizedAlways, .authorizedWhenInUse: beginFix()
        default: break   // still notDetermined — the dialog is up, keep waiting
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last { finish(.success(loc)) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient "don't know yet" — retry inside the budget rather than failing the tool call.
        if let clError = error as? CLError, clError.code == .locationUnknown, retriesLeft > 0 {
            retriesLeft -= 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.manager.requestLocation()
            }
            return
        }
        finish(.failure(LocationError.unavailable(error.localizedDescription)))
    }
}

/// Requests authorization and resumes with the outcome — no location fetch. Retains itself like the
/// one-shot delegate; a dialog left unanswered resolves via the guard timeout as "still undetermined".
private final class AuthorizationOnlyDelegate: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<ToolPermission, Never>?
    private var selfRef: AuthorizationOnlyDelegate?

    init(continuation: CheckedContinuation<ToolPermission, Never>) {
        self.continuation = continuation
        super.init()
        manager.delegate = self
    }

    func start() {
        selfRef = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            self?.finish(.notDetermined)
        }
        DispatchQueue.main.async { [self] in
            switch manager.authorizationStatus {
            case .notDetermined:
                #if os(iOS)
                manager.requestWhenInUseAuthorization()
                #else
                manager.requestAlwaysAuthorization()
                #endif
            case .denied, .restricted:
                finish(.denied)
            default:
                finish(.granted)
            }
        }
    }

    private func finish(_ state: ToolPermission) {
        guard let cont = continuation else { return }
        continuation = nil
        manager.delegate = nil
        cont.resume(returning: state)
        selfRef = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .notDetermined: break   // dialog still up
        case .denied, .restricted: finish(.denied)
        default: finish(.granted)
        }
    }
}
#endif

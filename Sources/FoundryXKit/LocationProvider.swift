// LocationProvider — opportunistic one-shot location at conversation boundaries
// (Phase A, F5). Requests **When-In-Use** authorization (NOT "Always") and, when a
// fix is available, returns the coordinate + a reverse-geocoded place label.
//
// Honest degradation is the contract: a background-started conversation, denied
// permission, or no fix in time → returns `nil`. The caller (CaptureManager) treats
// nil as "no location" — the capture is unaffected and the card shows time only. We
// deliberately do NOT request "Always" / background-location: a When-In-Use app only
// gets fixes while foregrounded, and that's an accepted limit here (see the spec's
// Decision 1 / F5), not a bug to work around with a more invasive entitlement.

import Foundation
#if canImport(CoreLocation)
import CoreLocation
#endif

/// Format a conversation's place label as "City, State, Country" from reverse-geocoded
/// components, gracefully omitting any missing/empty parts (so a partial fix reads
/// "City, Country" or "State, Country", and an empty one → nil → the card shows time
/// only). Pure + CoreLocation-free so it's unit-testable on the macOS test host.
public func foundryxPlaceLabel(city: String?, state: String?, country: String?) -> String? {
    let parts = [city, state, country]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: ", ")
}

/// One-shot location lookup. Injectable behind a protocol so door-free tests can
/// drive the degradation path without CoreLocation.
public protocol ConversationLocationProviding: Sendable {
    /// Request a single fix opportunistically. Returns `nil` on any of: permission
    /// denied/undetermined, location services off, backgrounded with no fix, or
    /// timeout. Never throws — location is best-effort and must never fail capture.
    func currentLocation() async -> ConversationLocation?
}

#if canImport(CoreLocation)
/// CoreLocation-backed provider. Requests When-In-Use authorization on first use,
/// requests a single location, and reverse-geocodes it to a place label.
public final class LocationProvider: NSObject, ConversationLocationProviding, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private let timeout: TimeInterval
    private var pending: CheckedContinuation<CLLocation?, Never>?
    private let lock = NSLock()

    public init(timeout: TimeInterval = 8) {
        self.timeout = timeout
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    public func currentLocation() async -> ConversationLocation? {
        // Request When-In-Use authorization (no-op if already decided). A denied or
        // restricted state → no location (degrade).
        let status = authorizationStatus()
        switch status {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            // Don't block on the auth prompt for a one-shot — if undecided, degrade
            // gracefully this time; the next conversation gets a fix once granted.
            return nil
        case .denied, .restricted:
            return nil
        default:
            break
        }

        guard let fix = await requestOneShot() else { return nil }
        let label = await reverseGeocode(fix)
        return ConversationLocation(
            lat: fix.coordinate.latitude,
            long: fix.coordinate.longitude,
            label: label
        )
    }

    private func authorizationStatus() -> CLAuthorizationStatus {
        manager.authorizationStatus
    }

    /// A single `requestLocation()` bridged to async, with a timeout so a stalled
    /// GPS never hangs the finalize path.
    private func requestOneShot() async -> CLLocation? {
        await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask { [weak self] in
                guard let self else { return nil }
                return await withCheckedContinuation { (cont: CheckedContinuation<CLLocation?, Never>) in
                    self.lock.lock()
                    self.pending = cont
                    self.lock.unlock()
                    self.manager.requestLocation()
                }
            }
            group.addTask { [timeout] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            // If the timeout won, release any still-pending continuation.
            self.resume(with: first == nil ? nil : first, onlyIfPending: true)
            return first
        }
    }

    private func resume(with location: CLLocation?, onlyIfPending: Bool) {
        lock.lock()
        let cont = pending
        pending = nil
        lock.unlock()
        if let cont { cont.resume(returning: location) }
        else if !onlyIfPending { /* nothing pending */ }
    }

    private func reverseGeocode(_ location: CLLocation) async -> String? {
        let placemarks = try? await geocoder.reverseGeocodeLocation(location)
        guard let p = placemarks?.first else { return nil }
        // "City, State, Country" — the where-it-happened label the card + Lore want.
        // Fall back through subLocality when locality is absent (some regions).
        return foundryxPlaceLabel(
            city: p.locality ?? p.subLocality,
            state: p.administrativeArea,
            country: p.country
        )
    }

    // MARK: CLLocationManagerDelegate
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        resume(with: locations.last, onlyIfPending: false)
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        resume(with: nil, onlyIfPending: false)
    }
}
#endif

/// A provider that always degrades to "no location" — the default when CoreLocation
/// is unavailable (e.g. the macOS test host) and the injected stub for door-free
/// tests asserting the time-only / degradation path.
public struct NoLocationProvider: ConversationLocationProviding {
    public init() {}
    public func currentLocation() async -> ConversationLocation? { nil }
}

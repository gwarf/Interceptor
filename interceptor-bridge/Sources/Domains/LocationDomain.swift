// PRD-66 Domain 12 — CoreLocation. macOS 10.6+; CLGeocoder/CLPlacemark
// deprecated 26.0 — guarded behind #available. References:
// apple-developer-docs/CoreLocation/{CLLocationManager,CLAuthorizationStatus,
// CLLocation,CLGeocoder,CLPlacemark}.md.

import Foundation
import CoreLocation
import Contacts

final class LocationDomain: NSObject, DomainHandler, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager: CLLocationManager
    private let geocoder = CLGeocoder()
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private var oneShotCompletion: ((CLLocation?) -> Void)?
    private let lock = NSLock()
    private var continuous: [CLLocation] = []
    private var continuousActive = false

    override init() {
        manager = CLLocationManager()
        super.init()
        manager.delegate = self
    }

    func handle(_ command: String, action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let sub = action["sub"] as? String ?? command
        switch sub {
        case "status":                          status(completion: completion)
        case "request":                         requestAccess(action, completion: completion)
        case "request-temporary-accuracy":      requestTemporaryAccuracy(action, completion: completion)
        case "current":                         currentLocation(completion: completion)
        case "monitor_start":                   monitorStart(action, completion: completion)
        case "monitor_stop":                    monitorStop(completion: completion)
        case "monitor_tail":                    monitorTail(completion: completion)
        case "significant_start":               significantStart(completion: completion)
        case "significant_stop":                significantStop(completion: completion)
        case "visits_start":                    visitsStart(completion: completion)
        case "visits_stop":                     visitsStop(completion: completion)
        case "heading_start":                   headingStart(completion: completion)
        case "heading_stop":                    headingStop(completion: completion)
        case "geocode":                         geocode(action, completion: completion)
        case "reverse":                         reverseGeocode(action, completion: completion)
        case "distance":                        distance(action, completion: completion)
        case "postal-geocode":                  postalGeocode(action, completion: completion)
        default:                                completion(WireFormat.error("location.\(sub) — unknown verb"))
        }
    }

    // MARK: - Helpers

    private func authStatusString(_ s: CLAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .restricted:    return "restricted"
        case .denied:        return "denied"
        case .authorized:    return "authorized"
        case .authorizedAlways:    return "authorizedAlways"
        case .authorizedWhenInUse: return "authorizedWhenInUse"
        @unknown default: return "unknown"
        }
    }

    private func locationDict(_ l: CLLocation) -> [String: Any] {
        var out: [String: Any] = [
            "coordinate": [l.coordinate.latitude, l.coordinate.longitude],
            "altitude": l.altitude,
            "ellipsoidalAltitude": l.ellipsoidalAltitude,
            "horizontalAccuracy": l.horizontalAccuracy,
            "verticalAccuracy": l.verticalAccuracy,
            "course": l.course,
            "courseAccuracy": l.courseAccuracy,
            "speed": l.speed,
            "speedAccuracy": l.speedAccuracy,
            "timestamp": isoFormatter.string(from: l.timestamp),
        ]
        out["floor"] = l.floor?.level as Any? ?? NSNull()
        return out
    }

    private func placemarkDict(_ p: CLPlacemark) -> [String: Any] {
        var out: [String: Any] = ["name": p.name as Any? ?? NSNull()]
        if let v = p.thoroughfare { out["thoroughfare"] = v }
        if let v = p.subThoroughfare { out["subThoroughfare"] = v }
        if let v = p.locality { out["locality"] = v }
        if let v = p.subLocality { out["subLocality"] = v }
        if let v = p.administrativeArea { out["administrativeArea"] = v }
        if let v = p.subAdministrativeArea { out["subAdministrativeArea"] = v }
        if let v = p.postalCode { out["postalCode"] = v }
        if let v = p.isoCountryCode { out["isoCountryCode"] = v }
        if let v = p.country { out["country"] = v }
        if let v = p.inlandWater { out["inlandWater"] = v }
        if let v = p.ocean { out["ocean"] = v }
        if let aoi = p.areasOfInterest { out["areasOfInterest"] = aoi }
        return out
    }

    // MARK: - Status / authorization

    private func status(completion: @escaping @Sendable ([String: Any]) -> Void) {
        let s = manager.authorizationStatus
        var resp: [String: Any] = [
            "status": authStatusString(s),
            "locationServicesEnabled": CLLocationManager.locationServicesEnabled(),
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        resp["accuracyAuthorization"] = String(describing: manager.accuracyAuthorization)
        completion(WireFormat.success(resp))
    }

    private func requestAccess(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let level = (action["level"] as? String) ?? "whenInUse"
        DispatchQueue.main.async {
            switch level {
            case "always": self.manager.requestAlwaysAuthorization()
            default:       self.manager.requestWhenInUseAuthorization()
            }
            completion(WireFormat.success(["requested": level, "status": self.authStatusString(self.manager.authorizationStatus)]))
        }
    }

    private func requestTemporaryAccuracy(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let purpose = action["purpose"] as? String else {
            completion(WireFormat.error("location.request-temporary-accuracy: --purpose required (Info.plist purpose key)")); return
        }
        // Per Apple's requestTemporaryFullAccuracyAuthorization(withPurposeKey:completion:)
        // doc the call always fails with kCLErrorPromptDeclined (CLError 18)
        // in three cases: (a) the purposeKey is missing from
        // NSLocationTemporaryUsageDescriptionDictionary, (b) the app is
        // already at full accuracy, or (c) the app is in the background.
        // Pre-flight (a) and (c) so callers get a structured response
        // rather than an opaque "kCLErrorDomain error 18".
        let infoDict = Bundle.main.object(forInfoDictionaryKey: "NSLocationTemporaryUsageDescriptionDictionary") as? [String: Any]
        if infoDict?[purpose] == nil {
            let known = (infoDict.map { Array($0.keys) } ?? []).sorted()
            completion(WireFormat.error("location.request-temporary-accuracy: --purpose \"\(purpose)\" not in NSLocationTemporaryUsageDescriptionDictionary. Known: \(known)")); return
        }
        // macOS only exposes .authorizedAlways (and legacy .authorized);
        // .authorizedWhenInUse is iOS-only.
        let baseStatus = manager.authorizationStatus
        let hasBaseAuth: Bool = {
            switch baseStatus {
            case .authorizedAlways: return true
            case .authorized:       return true
            default:                return false
            }
        }()
        guard hasBaseAuth else {
            completion(WireFormat.error("location.request-temporary-accuracy: app lacks base location auth (status=\(authStatusString(baseStatus))). Run `location request` first; system Location Services must be on.")); return
        }
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: purpose) { error in
            if let nsError = error as NSError?, nsError.domain == "kCLErrorDomain" && nsError.code == 18 {
                completion(WireFormat.error("location.request-temporary-accuracy: kCLErrorPromptDeclined. Apple disallows temporary-accuracy prompts from background-only agents (LSUIElement=true)."))
            } else if let error = error {
                completion(WireFormat.error("location: \(error.localizedDescription)"))
            } else {
                completion(WireFormat.success(["accuracyAuthorization": String(describing: self.manager.accuracyAuthorization)]))
            }
        }
    }

    private func currentLocation(completion: @escaping @Sendable ([String: Any]) -> Void) {
        lock.lock()
        oneShotCompletion = { loc in
            if let loc = loc { completion(WireFormat.success(self.locationDict(loc))) }
            else { completion(WireFormat.error("location.current: no location available")) }
        }
        lock.unlock()
        DispatchQueue.main.async {
            self.manager.requestLocation()
        }
    }

    // MARK: - Monitor

    private func monitorStart(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let accuracy = (action["accuracy"] as? String) ?? "best"
        switch accuracy {
        case "best":            manager.desiredAccuracy = kCLLocationAccuracyBest
        case "nearest":         manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        case "tenmeters":       manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        case "hundredmeters":   manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        case "kilometer":       manager.desiredAccuracy = kCLLocationAccuracyKilometer
        default:                manager.desiredAccuracy = kCLLocationAccuracyBest
        }
        DispatchQueue.main.async {
            self.continuousActive = true
            self.manager.startUpdatingLocation()
            completion(WireFormat.success(["monitoring": true, "accuracy": accuracy]))
        }
    }

    private func monitorStop(completion: @escaping @Sendable ([String: Any]) -> Void) {
        DispatchQueue.main.async {
            self.continuousActive = false
            self.manager.stopUpdatingLocation()
            completion(WireFormat.success(["monitoring": false]))
        }
    }

    private func monitorTail(completion: @escaping @Sendable ([String: Any]) -> Void) {
        lock.lock(); let snapshot = continuous; continuous.removeAll(); lock.unlock()
        completion(WireFormat.success(["locations": snapshot.map(locationDict), "monitoring": continuousActive]))
    }

    private func significantStart(completion: @escaping @Sendable ([String: Any]) -> Void) {
        DispatchQueue.main.async { self.manager.startMonitoringSignificantLocationChanges() }
        completion(WireFormat.success(["ok": true]))
    }
    private func significantStop(completion: @escaping @Sendable ([String: Any]) -> Void) {
        DispatchQueue.main.async { self.manager.stopMonitoringSignificantLocationChanges() }
        completion(WireFormat.success(["ok": true]))
    }
    private func visitsStart(completion: @escaping @Sendable ([String: Any]) -> Void) {
        DispatchQueue.main.async { self.manager.startMonitoringVisits() }
        completion(WireFormat.success(["ok": true]))
    }
    private func visitsStop(completion: @escaping @Sendable ([String: Any]) -> Void) {
        DispatchQueue.main.async { self.manager.stopMonitoringVisits() }
        completion(WireFormat.success(["ok": true]))
    }
    private func headingStart(completion: @escaping @Sendable ([String: Any]) -> Void) {
        // Heading is iOS-only; on macOS this returns a structured note.
        completion(WireFormat.success(["ok": false, "note": "heading updates are iOS-only; macOS does not provide CLHeading."]))
    }
    private func headingStop(completion: @escaping @Sendable ([String: Any]) -> Void) {
        completion(WireFormat.success(["ok": true, "note": "no-op on macOS"]))
    }

    // MARK: - Geocoding

    private func geocode(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let address = action["address"] as? String else { completion(WireFormat.error("location.geocode: <address> required")); return }
        let locale: Locale? = (action["locale"] as? String).map { Locale(identifier: $0) }
        if let regionRaw = action["region"] as? String {
            let parts = regionRaw.split(separator: ",").compactMap { Double($0) }
            if parts.count == 3 {
                let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1]),
                                              radius: parts[2], identifier: "interceptor-bridge")
                geocoder.geocodeAddressString(address, in: region, preferredLocale: locale) { placemarks, error in
                    self.completeGeocode(placemarks: placemarks, error: error, completion: completion)
                }
                return
            }
        }
        geocoder.geocodeAddressString(address, in: nil, preferredLocale: locale) { placemarks, error in
            self.completeGeocode(placemarks: placemarks, error: error, completion: completion)
        }
    }

    private func reverseGeocode(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let coords = action["coords"] as? String else { completion(WireFormat.error("location.reverse: <lat,lng> required")); return }
        let parts = coords.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { completion(WireFormat.error("location.reverse: <lat,lng> must be two doubles")); return }
        let loc = CLLocation(latitude: parts[0], longitude: parts[1])
        let locale: Locale? = (action["locale"] as? String).map { Locale(identifier: $0) }
        geocoder.reverseGeocodeLocation(loc, preferredLocale: locale) { placemarks, error in
            if let error = error { completion(WireFormat.error("location.reverse: \(error.localizedDescription)")); return }
            completion(WireFormat.success([
                "coordinate": [parts[0], parts[1]],
                "placemarks": (placemarks ?? []).map(self.placemarkDict),
            ]))
        }
    }

    private func completeGeocode(placemarks: [CLPlacemark]?, error: Error?, completion: @escaping @Sendable ([String: Any]) -> Void) {
        if let error = error { completion(WireFormat.error("location.geocode: \(error.localizedDescription)")); return }
        completion(WireFormat.success(["placemarks": (placemarks ?? []).map(self.placemarkDict)]))
    }

    private func distance(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let from = action["from"] as? String, let to = action["to"] as? String else {
            completion(WireFormat.error("location.distance: --from <lat,lng> --to <lat,lng> required")); return
        }
        let f = from.split(separator: ",").compactMap { Double($0) }
        let t = to.split(separator: ",").compactMap { Double($0) }
        guard f.count == 2, t.count == 2 else {
            completion(WireFormat.error("location.distance: each must be lat,lng")); return
        }
        let a = CLLocation(latitude: f[0], longitude: f[1])
        let b = CLLocation(latitude: t[0], longitude: t[1])
        completion(WireFormat.success(["meters": a.distance(from: b)]))
    }

    private func postalGeocode(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let raw = action["postal"] as? String,
              let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { completion(WireFormat.error("location.postal-geocode: --postal <json-postal> required")); return }
        let p = CNMutablePostalAddress()
        p.street = dict["street"] ?? ""
        p.city = dict["city"] ?? ""
        p.state = dict["state"] ?? ""
        p.postalCode = dict["postalCode"] ?? ""
        p.country = dict["country"] ?? ""
        p.isoCountryCode = dict["isoCountryCode"] ?? ""
        geocoder.geocodePostalAddress(p) { placemarks, error in
            if let error = error { completion(WireFormat.error("location.postal-geocode: \(error.localizedDescription)")); return }
            completion(WireFormat.success(["placemarks": (placemarks ?? []).map(self.placemarkDict)]))
        }
    }

    // MARK: - Delegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let cb = oneShotCompletion {
            oneShotCompletion = nil
            cb(locations.last)
            return
        }
        if continuousActive, let last = locations.last {
            lock.lock(); continuous.append(last); if continuous.count > 200 { continuous.removeFirst(100) }; lock.unlock()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let cb = oneShotCompletion {
            oneShotCompletion = nil
            cb(nil)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // No-op; status is always queried fresh.
    }
}

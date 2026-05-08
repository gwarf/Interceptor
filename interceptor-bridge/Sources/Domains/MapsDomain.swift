// PRD-66 Domain 11 — MapKit. macOS 10.9+. References:
// apple-developer-docs/MapKit/{MKLocalSearch,MKDirections,MKMapItem,MKPlacemark}.md.

import Foundation
import MapKit
import CoreLocation
import Contacts

final class MapsDomain: DomainHandler, @unchecked Sendable {
    private let mapItemCache = MapItemCache()

    func handle(_ command: String, action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let sub = action["sub"] as? String ?? command
        switch sub {
        case "search":         search(action, completion: completion)
        case "complete":       complete(action, completion: completion)
        case "directions":     directions(action, completion: completion)
        case "eta":            eta(action, completion: completion)
        case "mapitem-open":   mapItemOpen(action, completion: completion)
        case "reverse":        reverse(action, completion: completion)
        default:               completion(WireFormat.error("maps.\(sub) — unknown verb"))
        }
    }

    private func parseRegion(_ s: String?) -> MKCoordinateRegion? {
        guard let s = s else { return nil }
        let parts = s.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        let center = CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
        let span = MKCoordinateSpan(latitudeDelta: parts[2], longitudeDelta: parts[3])
        return MKCoordinateRegion(center: center, span: span)
    }

    private func placemarkDict(_ p: MKPlacemark) -> [String: Any] {
        var out: [String: Any] = [
            "coordinate": [p.coordinate.latitude, p.coordinate.longitude],
        ]
        if let v = p.thoroughfare { out["thoroughfare"] = v }
        if let v = p.subThoroughfare { out["subThoroughfare"] = v }
        if let v = p.locality { out["locality"] = v }
        if let v = p.subLocality { out["subLocality"] = v }
        if let v = p.administrativeArea { out["administrativeArea"] = v }
        if let v = p.subAdministrativeArea { out["subAdministrativeArea"] = v }
        if let v = p.postalCode { out["postalCode"] = v }
        if let v = p.country { out["country"] = v }
        if let v = p.isoCountryCode { out["isoCountryCode"] = v }
        return out
    }

    private func mapItemDict(_ item: MKMapItem) -> [String: Any] {
        let id = mapItemCache.put(item)
        var out: [String: Any] = [
            "id": id,
            "name": item.name as Any? ?? NSNull(),
            "isCurrentLocation": item.isCurrentLocation,
            "placemark": placemarkDict(item.placemark),
        ]
        if let tz = item.timeZone { out["timeZone"] = tz.identifier }
        if let url = item.url { out["url"] = url.absoluteString }
        if let phone = item.phoneNumber { out["phoneNumber"] = phone }
        if let cat = item.pointOfInterestCategory { out["pointOfInterestCategory"] = cat.rawValue }
        return out
    }

    private func search(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let query = action["query"] as? String else {
            completion(WireFormat.error("maps.search: missing query")); return
        }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        if let region = parseRegion(action["region"] as? String) {
            req.region = region
        }
        if let typesArg = action["types"] as? String {
            var types: MKLocalSearch.ResultType = []
            for raw in typesArg.split(separator: ",") {
                switch raw.trimmingCharacters(in: .whitespaces) {
                case "address": types.insert(.address)
                case "pointOfInterest": types.insert(.pointOfInterest)
                case "physicalFeature":
                    if #available(macOS 15, *) { types.insert(.physicalFeature) }
                default: break
                }
            }
            if !types.isEmpty { req.resultTypes = types }
        }
        let limit = action["limit"] as? Int

        let search = MKLocalSearch(request: req)
        search.start { resp, error in
            if let error = error {
                completion(WireFormat.error("maps.search: \(error.localizedDescription)"))
                return
            }
            guard let resp = resp else {
                completion(WireFormat.success(["query": query, "results": [Any]()]))
                return
            }
            var results = resp.mapItems.map { self.mapItemDict($0) }
            if let limit = limit { results = Array(results.prefix(limit)) }
            completion(WireFormat.success([
                "query": query,
                "boundingRegion": [
                    "center": [resp.boundingRegion.center.latitude, resp.boundingRegion.center.longitude],
                    "span":   [resp.boundingRegion.span.latitudeDelta, resp.boundingRegion.span.longitudeDelta],
                ],
                "results": results,
            ]))
        }
    }

    // MKLocalSearchCompleter is delegate-based and asynchronous; we wrap it
    // as a one-shot wait with a 500ms timeout per the PRD's "no hang" rule.
    private func complete(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let query = action["query"] as? String else {
            completion(WireFormat.error("maps.complete: missing query")); return
        }
        DispatchQueue.main.async {
            let completer = MKLocalSearchCompleter()
            let delegate = CompleterDelegate { suggestions in
                completion(WireFormat.success([
                    "query": query,
                    "completions": suggestions.map { ["title": $0.title, "subtitle": $0.subtitle] },
                ]))
            }
            completer.delegate = delegate
            completer.queryFragment = query
            // Hold delegate strongly until callback completes.
            objc_setAssociatedObject(completer, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            // Fire a 500ms safety timeout so we never hang.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if !delegate.fired {
                    delegate.fire(with: completer.results)
                }
            }
        }
    }

    private func resolveDestination(_ value: String, completion: @escaping @Sendable (MKMapItem?) -> Void) {
        // ID lookup first (from prior search)
        if let item = mapItemCache.get(value) { completion(item); return }
        // lat,lng coordinate
        let parts = value.split(separator: ",").compactMap { Double($0) }
        if parts.count == 2 {
            let coord = CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
            let placemark = MKPlacemark(coordinate: coord)
            completion(MKMapItem(placemark: placemark))
            return
        }
        // address string — geocode
        CLGeocoder().geocodeAddressString(value) { placemarks, _ in
            if let p = placemarks?.first, let c = p.location?.coordinate {
                let mk = MKPlacemark(coordinate: c, addressDictionary: nil)
                completion(MKMapItem(placemark: mk))
            } else {
                completion(nil)
            }
        }
    }

    private func directions(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let from = action["from"] as? String,
              let to = action["to"] as? String
        else { completion(WireFormat.error("maps.directions: requires --from and --to")); return }
        let transport = transportType((action["transport"] as? String) ?? "auto")
        let alts = (action["requests_alternates"] as? Bool) ?? false
        Task { @MainActor in
            let src = await self.resolveAsync(from)
            let dst = await self.resolveAsync(to)
            guard let src = src else { completion(WireFormat.error("maps.directions: cannot resolve --from")); return }
            guard let dst = dst else { completion(WireFormat.error("maps.directions: cannot resolve --to")); return }
            let req = MKDirections.Request()
            req.source = src
            req.destination = dst
            req.transportType = transport
            req.requestsAlternateRoutes = alts
            let mk = MKDirections(request: req)
            do {
                let response = try await mk.calculate()
                let routes: [[String: Any]] = response.routes.map { r in
                    [
                        "name": r.name,
                        "distance": r.distance,
                        "expectedTravelTime": r.expectedTravelTime,
                        "transportType": String(describing: r.transportType),
                        "advisoryNotices": r.advisoryNotices,
                        "hasTolls": r.hasTolls,
                        "steps": r.steps.map { ["instructions": $0.instructions, "distance": $0.distance] },
                    ]
                }
                completion(WireFormat.success([
                    "transport": String(describing: transport),
                    "routes": routes,
                    "source": self.mapItemDict(src),
                    "destination": self.mapItemDict(dst),
                ]))
            } catch {
                completion(WireFormat.error("maps.directions: \(error.localizedDescription)"))
            }
        }
    }

    private func eta(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let from = action["from"] as? String,
              let to = action["to"] as? String
        else { completion(WireFormat.error("maps.eta: requires --from and --to")); return }
        let transport = transportType((action["transport"] as? String) ?? "auto")
        Task { @MainActor in
            let src = await self.resolveAsync(from)
            let dst = await self.resolveAsync(to)
            guard let src = src else { completion(WireFormat.error("maps.eta: cannot resolve --from")); return }
            guard let dst = dst else { completion(WireFormat.error("maps.eta: cannot resolve --to")); return }
            let req = MKDirections.Request()
            req.source = src
            req.destination = dst
            req.transportType = transport
            let mk = MKDirections(request: req)
            do {
                let response = try await mk.calculateETA()
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime]
                completion(WireFormat.success([
                    "transport": String(describing: transport),
                    "expectedTravelTime": response.expectedTravelTime,
                    "distance": response.distance,
                    "expectedDepartureDate": f.string(from: response.expectedDepartureDate),
                    "expectedArrivalDate":   f.string(from: response.expectedArrivalDate),
                ]))
            } catch {
                completion(WireFormat.error("maps.eta: \(error.localizedDescription)"))
            }
        }
    }

    @MainActor
    private func resolveAsync(_ value: String) async -> MKMapItem? {
        if let item = mapItemCache.get(value) { return item }
        let parts = value.split(separator: ",").compactMap { Double($0) }
        if parts.count == 2 {
            let coord = CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
            return MKMapItem(placemark: MKPlacemark(coordinate: coord))
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<MKMapItem?, Never>) in
            CLGeocoder().geocodeAddressString(value) { placemarks, _ in
                if let p = placemarks?.first, let c = p.location?.coordinate {
                    let mk = MKPlacemark(coordinate: c, addressDictionary: nil)
                    cont.resume(returning: MKMapItem(placemark: mk))
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func transportType(_ s: String) -> MKDirectionsTransportType {
        switch s {
        case "walking": return .walking
        case "transit": return .transit
        case "any":     return .any
        default:        return .automobile
        }
    }

    private func mapItemOpen(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let id = action["id"] as? String, let item = mapItemCache.get(id) else {
            completion(WireFormat.error("maps.mapitem-open: unknown id (call maps search first)")); return
        }
        DispatchQueue.main.async {
            item.openInMaps(launchOptions: nil)
            completion(WireFormat.success(["ok": true, "id": id]))
        }
    }

    private func reverse(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let coords = action["coords"] as? String else {
            completion(WireFormat.error("maps.reverse: requires <lat,lng>")); return
        }
        let parts = coords.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else {
            completion(WireFormat.error("maps.reverse: --coords must be lat,lng")); return
        }
        let loc = CLLocation(latitude: parts[0], longitude: parts[1])
        CLGeocoder().reverseGeocodeLocation(loc) { placemarks, error in
            if let error = error { completion(WireFormat.error("maps.reverse: \(error.localizedDescription)")); return }
            let pms = (placemarks ?? []).map { (cp: CLPlacemark) -> [String: Any] in
                var out: [String: Any] = [
                    "name": cp.name as Any? ?? NSNull(),
                ]
                if let v = cp.thoroughfare { out["thoroughfare"] = v }
                if let v = cp.subThoroughfare { out["subThoroughfare"] = v }
                if let v = cp.locality { out["locality"] = v }
                if let v = cp.subLocality { out["subLocality"] = v }
                if let v = cp.administrativeArea { out["administrativeArea"] = v }
                if let v = cp.subAdministrativeArea { out["subAdministrativeArea"] = v }
                if let v = cp.postalCode { out["postalCode"] = v }
                if let v = cp.isoCountryCode { out["isoCountryCode"] = v }
                if let v = cp.country { out["country"] = v }
                return out
            }
            completion(WireFormat.success([
                "coordinate": [parts[0], parts[1]],
                "placemarks": pms,
            ]))
        }
    }
}

private final class MapItemCache: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: MKMapItem] = [:]
    private var counter: Int = 0
    func put(_ item: MKMapItem) -> String {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        let id = "B-\(counter)"
        items[id] = item
        return id
    }
    func get(_ id: String) -> MKMapItem? {
        lock.lock(); defer { lock.unlock() }
        return items[id]
    }
}

private final class CompleterDelegate: NSObject, MKLocalSearchCompleterDelegate, @unchecked Sendable {
    private let onResult: ([MKLocalSearchCompletion]) -> Void
    private(set) var fired = false
    init(onResult: @escaping ([MKLocalSearchCompletion]) -> Void) { self.onResult = onResult }
    func fire(with results: [MKLocalSearchCompletion]) {
        guard !fired else { return }
        fired = true
        onResult(results)
    }
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        fire(with: completer.results)
    }
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        fire(with: [])
    }
}

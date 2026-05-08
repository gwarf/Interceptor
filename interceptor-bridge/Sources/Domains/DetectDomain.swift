// PRD-66 Domain 2 — DataDetection. Foundation NSDataDetector (macOS 10.7+) is
// the universal backbone; the macOS-12+ DDMatch* and macOS-26+ DataDetector
// surfaces are opt-in via #available gates. References:
// apple-developer-docs/Foundation/NSDataDetector.md, DataDetection/DDMatch*.md.

import Foundation

final class DetectDomain: DomainHandler, @unchecked Sendable {
    func handle(_ command: String, action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let sub = action["sub"] as? String ?? command
        switch sub {
        case "types":  completion(WireFormat.success(["types": availableTypes()]))
        case "run":    runDetect(action, completion: completion)
        case "file":   detectFile(action, completion: completion)
        case "stdin":  // bridge consumers set the input via action["input"] when stdin is wrapped at the CLI
                       runDetect(action, completion: completion)
        default:       completion(WireFormat.error("detect.\(sub) — unknown verb"))
        }
    }

    private func availableTypes() -> [String] {
        var t = ["link", "phoneNumber", "calendarEvent", "postalAddress", "email"]
        if #available(macOS 12, *) {
            t.append(contentsOf: ["moneyAmount", "flightNumber", "shipmentTrackingNumber"])
        }
        if #available(macOS 26, *) {
            t.append(contentsOf: ["measurement", "paymentIdentifier"])
        }
        return t
    }

    private func runDetect(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let input = action["input"] as? String else {
            completion(WireFormat.error("detect.run: missing input")); return
        }
        let typesArg = (action["types"] as? String) ?? "all"
        let mask = compileMask(typesArg)
        do {
            let detector = try NSDataDetector(types: mask.rawValue)
            let range = NSRange(location: 0, length: input.utf16.count)
            let results = detector.matches(in: input, options: [], range: range)
            let matches = results.map { matchToDict($0, in: input) }
            completion(WireFormat.success(["input": input, "matches": matches]))
        } catch {
            completion(WireFormat.error("detect.run: \(error.localizedDescription)"))
        }
    }

    private func detectFile(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let path = action["path"] as? String else { completion(WireFormat.error("detect.file: missing path")); return }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { completion(WireFormat.error("detect.file: cannot read \(path) as utf-8")); return }
        var fwd = action
        fwd["input"] = text
        runDetect(fwd, completion: completion)
    }

    private func compileMask(_ types: String) -> NSTextCheckingResult.CheckingType {
        if types == "all" {
            return [.link, .phoneNumber, .date, .address]
        }
        var mask: NSTextCheckingResult.CheckingType = []
        for raw in types.split(separator: ",") {
            switch raw.trimmingCharacters(in: .whitespaces) {
            case "link", "url":                   mask.insert(.link)
            case "phone", "phoneNumber":          mask.insert(.phoneNumber)
            case "date", "calendarEvent":         mask.insert(.date)
            case "address", "postalAddress":      mask.insert(.address)
            case "email", "emailAddress":         mask.insert(.link) // Foundation surfaces emails as link with mailto:
            case "transit":                       mask.insert(.transitInformation)
            default: break
            }
        }
        return mask
    }

    private func matchToDict(_ m: NSTextCheckingResult, in s: String) -> [String: Any] {
        let r = m.range
        let value: String = {
            guard let range = Range(r, in: s) else { return "" }
            return String(s[range])
        }()
        var dict: [String: Any] = [
            "range": [r.location, r.length],
            "value": value,
        ]
        switch m.resultType {
        case .link:
            if let url = m.url {
                if url.scheme == "mailto" {
                    dict["type"] = "emailAddress"
                    dict["components"] = ["emailAddress": url.absoluteString.replacingOccurrences(of: "mailto:", with: "")]
                } else {
                    dict["type"] = "link"
                    dict["components"] = ["url": url.absoluteString]
                }
            } else {
                dict["type"] = "link"
            }
        case .phoneNumber:
            dict["type"] = "phoneNumber"
            dict["components"] = ["phoneNumber": m.phoneNumber ?? value]
        case .date:
            dict["type"] = "calendarEvent"
            var comp: [String: Any] = [:]
            if let date = m.date { comp["startDate"] = isoFormatter.string(from: date) }
            if let dur = m.duration as Double?, dur > 0 {
                comp["duration"] = dur
                if let date = m.date { comp["endDate"] = isoFormatter.string(from: date.addingTimeInterval(dur)) }
            }
            if let tz = m.timeZone { comp["timeZone"] = tz.identifier }
            dict["components"] = comp
        case .address:
            dict["type"] = "postalAddress"
            var comp: [String: Any] = [:]
            if let parts = m.addressComponents {
                if let v = parts[.street] { comp["street"] = v }
                if let v = parts[.city] { comp["city"] = v }
                if let v = parts[.state] { comp["state"] = v }
                if let v = parts[.zip] { comp["postalCode"] = v }
                if let v = parts[.country] { comp["country"] = v }
                if let v = parts[.name] { comp["name"] = v }
                if let v = parts[.organization] { comp["organization"] = v }
            }
            dict["components"] = comp
        case .transitInformation:
            dict["type"] = "transit"
        default:
            dict["type"] = "unknown"
        }
        return dict
    }

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

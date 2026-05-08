// PRD-66 Domain 6 (events half) — EventKit. macOS 10.8+ for EKEvent;
// macOS 14+ for requestFullAccessToEvents / requestWriteOnlyAccessToEvents.
// References: apple-developer-docs/EventKit/{EKEventStore,EKEvent,EKCalendar,
// EKAlarm,EKRecurrenceRule,EKAuthorizationStatus,accessing-the-event-store}.md.

import Foundation
import EventKit

final class CalendarDomain: DomainHandler, @unchecked Sendable {
    private let store = EKEventStore()
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func handle(_ command: String, action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let sub = action["sub"] as? String ?? command
        switch sub {
        case "status":              status(completion: completion)
        case "request":             requestAccess(action, completion: completion)
        case "list":                listCalendars(completion: completion)
        case "default":             defaultCalendar(completion: completion)
        case "sources":             listSources(completion: completion)
        case "create-calendar":     createCalendar(action, completion: completion)
        case "delete-calendar":     deleteCalendar(action, completion: completion)
        case "events":              listEvents(action, completion: completion)
        case "event":               getEvent(action, completion: completion)
        case "event-by-external":   eventByExternal(action, completion: completion)
        case "create":              createEvent(action, completion: completion)
        case "update":              updateEvent(action, completion: completion)
        case "delete":              deleteEvent(action, completion: completion)
        case "move":                moveEvent(action, completion: completion)
        case "refresh-sources":     refreshSources(completion: completion)
        case "reset":               reset(completion: completion)
        case "tail":                tail(completion: completion)
        default:                    completion(WireFormat.error("calendar.\(sub) — unknown verb"))
        }
    }

    private func authStatusString(_ s: EKAuthorizationStatus) -> String {
        switch s {
        case .fullAccess:    return "fullAccess"
        case .writeOnly:     return "writeOnly"
        case .denied:        return "denied"
        case .notDetermined: return "notDetermined"
        case .restricted:    return "restricted"
        case .authorized:    return "fullAccess"
        @unknown default:    return "unknown"
        }
    }

    private func status(completion: @escaping @Sendable ([String: Any]) -> Void) {
        let events = EKEventStore.authorizationStatus(for: .event)
        let reminders = EKEventStore.authorizationStatus(for: .reminder)
        completion(WireFormat.success([
            "events": authStatusString(events),
            "reminders": authStatusString(reminders),
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
        ]))
    }

    private func requestAccess(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let level = (action["level"] as? String) ?? "full"
        // Per Apple's `requestFullAccessToEvents(completion:)` docs: an
        // EKEventStore created before access is granted retains a stale
        // "not authorized" handle that allows reads/writes but rejects
        // remove() with EKErrorEventStoreNotAuthorized. After grant we must
        // call store.reset() to refresh the auth context.
        let store = self.store
        if #available(macOS 14, *) {
            switch level {
            case "write":
                store.requestWriteOnlyAccessToEvents { granted, error in
                    if granted { store.reset() }
                    completion(WireFormat.success([
                        "level": "write",
                        "granted": granted,
                        "error": error?.localizedDescription as Any? ?? NSNull(),
                    ]))
                }
            default:
                store.requestFullAccessToEvents { granted, error in
                    if granted { store.reset() }
                    completion(WireFormat.success([
                        "level": "full",
                        "granted": granted,
                        "error": error?.localizedDescription as Any? ?? NSNull(),
                    ]))
                }
            }
        } else {
            store.requestAccess(to: .event) { granted, error in
                if granted { store.reset() }
                completion(WireFormat.success([
                    "level": "legacy",
                    "granted": granted,
                    "error": error?.localizedDescription as Any? ?? NSNull(),
                ]))
            }
        }
    }

    private func calendarDict(_ c: EKCalendar) -> [String: Any] {
        var out: [String: Any] = [
            "id": c.calendarIdentifier,
            "title": c.title,
            "type": String(describing: c.type),
            "allowsContentModifications": c.allowsContentModifications,
            "isImmutable": c.isImmutable,
            "isSubscribed": c.isSubscribed,
            "supportedEventAvailabilities": c.supportedEventAvailabilities.rawValue,
        ]
        if let s = c.source { out["source"] = ["id": s.sourceIdentifier, "title": s.title, "type": String(describing: s.sourceType)] }
        return out
    }

    private func listCalendars(completion: @escaping @Sendable ([String: Any]) -> Void) {
        let calendars = store.calendars(for: .event)
        completion(WireFormat.success(["calendars": calendars.map(calendarDict)]))
    }

    private func defaultCalendar(completion: @escaping @Sendable ([String: Any]) -> Void) {
        if let c = store.defaultCalendarForNewEvents {
            completion(WireFormat.success(calendarDict(c)))
        } else {
            completion(WireFormat.success(["calendar": NSNull()]))
        }
    }

    private func listSources(completion: @escaping @Sendable ([String: Any]) -> Void) {
        let arr = store.sources.map { s -> [String: Any] in
            [
                "id": s.sourceIdentifier,
                "title": s.title,
                "type": String(describing: s.sourceType),
            ]
        }
        completion(WireFormat.success(["sources": arr]))
    }

    private func createCalendar(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let title = action["title"] as? String else { completion(WireFormat.error("calendar.create-calendar: --title required")); return }
        // CLI sends `cal_type` because `type` collides with the action envelope.
        let typeStr = (action["cal_type"] as? String) ?? (action["type"] as? String) ?? "local"
        let cal = EKCalendar(for: .event, eventStore: store)
        cal.title = title
        // Pick a source matching the requested type.
        let target: EKSource? = {
            switch typeStr {
            case "local":     return store.sources.first { $0.sourceType == .local }
            case "calDAV":    return store.sources.first { $0.sourceType == .calDAV }
            case "exchange":  return store.sources.first { $0.sourceType == .exchange }
            case "subscribed":return store.sources.first { $0.sourceType == .subscribed }
            default:          return store.sources.first { $0.sourceType == .local }
            }
        }()
        guard let src = target else { completion(WireFormat.error("calendar.create-calendar: no \(typeStr) source available")); return }
        cal.source = src
        do {
            try store.saveCalendar(cal, commit: true)
            completion(WireFormat.success(calendarDict(cal)))
        } catch {
            completion(WireFormat.error("calendar.create-calendar: \(error.localizedDescription)"))
        }
    }

    private func deleteCalendar(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let id = action["id"] as? String, let cal = store.calendar(withIdentifier: id) else {
            completion(WireFormat.error("calendar.delete-calendar: unknown id")); return
        }
        do {
            try store.removeCalendar(cal, commit: true)
            completion(WireFormat.success(["ok": true, "id": id]))
        } catch {
            completion(WireFormat.error("calendar.delete-calendar: \(error.localizedDescription)"))
        }
    }

    private func parseDate(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        return isoFormatter.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    private func parseSpan(_ raw: String?) -> EKSpan {
        return raw == "future" ? .futureEvents : .thisEvent
    }

    private func resolveCalendars(_ action: [String: Any]) -> [EKCalendar]? {
        if let id = action["calendar"] as? String, let c = store.calendar(withIdentifier: id) {
            return [c]
        }
        if let raw = action["calendars"] as? String {
            let ids = raw.split(separator: ",").map(String.init)
            let mapped = ids.compactMap { store.calendar(withIdentifier: $0) }
            return mapped.isEmpty ? nil : mapped
        }
        return nil
    }

    private func recurrenceFrequency(_ s: String) -> EKRecurrenceFrequency {
        switch s.lowercased() {
        case "daily":   return .daily
        case "weekly":  return .weekly
        case "monthly": return .monthly
        case "yearly":  return .yearly
        default:        return .daily
        }
    }

    private func buildRecurrence(from action: [String: Any]) -> EKRecurrenceRule? {
        guard let freq = action["recurrence_frequency"] as? String else { return nil }
        let interval = (action["recurrence_interval"] as? Int) ?? 1
        var end: EKRecurrenceEnd? = nil
        if let endRaw = action["recurrence_end"] as? String {
            if let n = Int(endRaw) {
                end = EKRecurrenceEnd(occurrenceCount: n)
            } else if let d = parseDate(endRaw) {
                end = EKRecurrenceEnd(end: d)
            }
        }
        return EKRecurrenceRule(recurrenceWith: recurrenceFrequency(freq), interval: interval, end: end)
    }

    private func buildAlarms(from action: [String: Any]) -> [EKAlarm] {
        let raw = action["alarms"] as? [String] ?? []
        var alarms: [EKAlarm] = []
        for s in raw {
            if let d = parseDate(s) {
                alarms.append(EKAlarm(absoluteDate: d))
            } else if let n = Double(s) {
                alarms.append(EKAlarm(relativeOffset: n))
            }
        }
        return alarms
    }

    private func eventDict(_ e: EKEvent) -> [String: Any] {
        var out: [String: Any] = [
            "id": e.eventIdentifier ?? "",
            "calendarId": e.calendar?.calendarIdentifier ?? "",
            "title": e.title ?? "",
            "startDate": isoFormatter.string(from: e.startDate),
            "endDate": isoFormatter.string(from: e.endDate),
            "isAllDay": e.isAllDay,
            "isDetached": e.isDetached,
            "status": String(describing: e.status),
            "availability": String(describing: e.availability),
        ]
        if let loc = e.location { out["location"] = loc }
        if let notes = e.notes { out["notes"] = notes }
        if let url = e.url { out["url"] = url.absoluteString }
        if let occ = e.occurrenceDate { out["occurrenceDate"] = isoFormatter.string(from: occ) }
        if let org = e.organizer {
            out["organizer"] = ["name": org.name as Any? ?? NSNull(), "isCurrentUser": org.isCurrentUser]
        }
        if let attendees = e.attendees {
            out["attendees"] = attendees.map { p -> [String: Any] in
                ["name": p.name as Any? ?? NSNull(),
                 "role": String(describing: p.participantRole),
                 "status": String(describing: p.participantStatus),
                 "type": String(describing: p.participantType)]
            }
        }
        if let alarms = e.alarms {
            out["alarms"] = alarms.map { a -> [String: Any] in
                var d: [String: Any] = ["type": String(describing: a.type), "relativeOffset": a.relativeOffset]
                if let abs = a.absoluteDate { d["absoluteDate"] = isoFormatter.string(from: abs) }
                // EKAlarm.url is unavailable in Swift on macOS — skipped.
                return d
            }
        }
        if let rules = e.recurrenceRules {
            out["recurrenceRules"] = rules.map { r -> [String: Any] in
                var d: [String: Any] = [
                    "frequency": String(describing: r.frequency),
                    "interval": r.interval,
                ]
                if let end = r.recurrenceEnd {
                    var endDict: [String: Any] = [:]
                    if let ed = end.endDate { endDict["date"] = isoFormatter.string(from: ed) }
                    if end.occurrenceCount > 0 { endDict["occurrenceCount"] = end.occurrenceCount }
                    d["end"] = endDict
                }
                return d
            }
        }
        if let sl = e.structuredLocation {
            var s: [String: Any] = ["title": sl.title as Any? ?? NSNull()]
            if let geo = sl.geoLocation {
                s["geoLocation"] = ["latitude": geo.coordinate.latitude, "longitude": geo.coordinate.longitude]
            }
            s["radius"] = sl.radius
            out["structuredLocation"] = s
        }
        return out
    }

    private func listEvents(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let start = parseDate(action["start"]),
              let end = parseDate(action["end"]) else {
            completion(WireFormat.error("calendar.events: --start and --end (ISO8601) required")); return
        }
        let cals = resolveCalendars(action)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: cals)
        let events = store.events(matching: predicate)
        completion(WireFormat.success(["events": events.map(eventDict)]))
    }

    private func getEvent(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let id = action["id"] as? String else { completion(WireFormat.error("calendar.event: <id> required")); return }
        if let e = store.event(withIdentifier: id) {
            completion(WireFormat.success(eventDict(e)))
        } else {
            completion(WireFormat.error("calendar.event: not found"))
        }
    }

    private func eventByExternal(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let id = action["id"] as? String else { completion(WireFormat.error("calendar.event-by-external: <id> required")); return }
        let items = store.calendarItems(withExternalIdentifier: id).compactMap { $0 as? EKEvent }
        completion(WireFormat.success(["events": items.map(eventDict)]))
    }

    private func createEvent(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let title = action["title"] as? String,
              let start = parseDate(action["start"]),
              let end = parseDate(action["end"])
        else { completion(WireFormat.error("calendar.create: --title, --start, --end required")); return }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        if let allDay = action["all_day"] as? Bool { event.isAllDay = allDay }
        if let loc = action["location"] as? String { event.location = loc }
        if let notes = action["notes"] as? String { event.notes = notes }
        if let urlStr = action["url"] as? String, let u = URL(string: urlStr) { event.url = u }
        let calId = action["calendar"] as? String
        event.calendar = (calId.flatMap { store.calendar(withIdentifier: $0) }) ?? store.defaultCalendarForNewEvents
        let alarms = buildAlarms(from: action)
        if !alarms.isEmpty { event.alarms = alarms }
        if let rule = buildRecurrence(from: action) { event.recurrenceRules = [rule] }
        do {
            try store.save(event, span: .thisEvent, commit: true)
            completion(WireFormat.success(eventDict(event)))
        } catch {
            completion(WireFormat.error("calendar.create: \(error.localizedDescription)"))
        }
    }

    private func updateEvent(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let id = action["id"] as? String, let event = store.event(withIdentifier: id) else {
            completion(WireFormat.error("calendar.update: unknown id")); return
        }
        if let title = action["title"] as? String { event.title = title }
        if let start = parseDate(action["start"]) { event.startDate = start }
        if let end = parseDate(action["end"]) { event.endDate = end }
        if let allDay = action["all_day"] as? Bool { event.isAllDay = allDay }
        if let loc = action["location"] as? String { event.location = loc }
        if let notes = action["notes"] as? String { event.notes = notes }
        if let urlStr = action["url"] as? String, let u = URL(string: urlStr) { event.url = u }
        let span = parseSpan(action["span"] as? String)
        do {
            try store.save(event, span: span, commit: true)
            completion(WireFormat.success(eventDict(event)))
        } catch {
            completion(WireFormat.error("calendar.update: \(error.localizedDescription)"))
        }
    }

    private func deleteEvent(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let id = action["id"] as? String, let event = store.event(withIdentifier: id) else {
            completion(WireFormat.error("calendar.delete: unknown id")); return
        }
        let span = parseSpan(action["span"] as? String)
        do {
            try store.remove(event, span: span, commit: true)
            completion(WireFormat.success(["ok": true, "id": id]))
        } catch {
            completion(WireFormat.error("calendar.delete: \(error.localizedDescription)"))
        }
    }

    private func moveEvent(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let id = action["id"] as? String, let event = store.event(withIdentifier: id) else {
            completion(WireFormat.error("calendar.move: unknown id")); return
        }
        guard let to = action["to"] as? String, let target = store.calendar(withIdentifier: to) else {
            completion(WireFormat.error("calendar.move: --to <calendar-id> required")); return
        }
        event.calendar = target
        do {
            try store.save(event, span: .thisEvent, commit: true)
            completion(WireFormat.success(eventDict(event)))
        } catch {
            completion(WireFormat.error("calendar.move: \(error.localizedDescription)"))
        }
    }

    private func refreshSources(completion: @escaping @Sendable ([String: Any]) -> Void) {
        store.refreshSourcesIfNecessary()
        completion(WireFormat.success(["ok": true]))
    }

    private func reset(completion: @escaping @Sendable ([String: Any]) -> Void) {
        store.reset()
        completion(WireFormat.success(["ok": true]))
    }

    // tail wires the EKEventStoreChanged DistributedNotification stream into a
    // simple counter; clients can poll to observe change deltas.
    private func tail(completion: @escaping @Sendable ([String: Any]) -> Void) {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: nil) { _ in }
        completion(WireFormat.success(["tailing": true]))
    }
}

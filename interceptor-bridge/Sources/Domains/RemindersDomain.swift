// PRD-66 Domain 6 (reminders half) — EventKit. macOS 10.8+ for EKReminder.
// macOS 14+ requestFullAccessToReminders. Reminders does NOT support
// write-only access (per Apple docs). References:
// apple-developer-docs/EventKit/{EKReminder,EKEventStore,...}.md.

import Foundation
import EventKit

final class RemindersDomain: DomainHandler, @unchecked Sendable {
    private let store = EKEventStore()
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func handle(_ command: String, action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let sub = action["sub"] as? String ?? command
        switch sub {
        case "status":     status(completion: completion)
        case "request":    requestAccess(completion: completion)
        case "lists":      listLists(completion: completion)
        case "default":    defaultList(completion: completion)
        case "all":        listAll(action, completion: completion)
        case "incomplete": listIncomplete(action, completion: completion)
        case "completed":  listCompleted(action, completion: completion)
        case "create":     createReminder(action, completion: completion)
        case "update":     updateReminder(action, completion: completion)
        case "complete":   complete(action, completion: completion, value: true)
        case "uncomplete": complete(action, completion: completion, value: false)
        case "delete":     deleteReminder(action, completion: completion)
        default:           completion(WireFormat.error("reminders.\(sub) — unknown verb"))
        }
    }

    private func authStatusString(_ s: EKAuthorizationStatus) -> String {
        switch s {
        case .fullAccess: return "fullAccess"
        case .writeOnly: return "writeOnly"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .authorized: return "fullAccess"
        @unknown default: return "unknown"
        }
    }

    private func status(completion: @escaping @Sendable ([String: Any]) -> Void) {
        completion(WireFormat.success([
            "status": authStatusString(EKEventStore.authorizationStatus(for: .reminder)),
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
        ]))
    }

    private func requestAccess(completion: @escaping @Sendable ([String: Any]) -> Void) {
        // EKEventStore created before access is granted retains a stale
        // auth context that rejects remove() with
        // EKErrorEventStoreNotAuthorized (29). store.reset() refreshes it.
        let store = self.store
        if #available(macOS 14, *) {
            store.requestFullAccessToReminders { granted, error in
                if granted { store.reset() }
                completion(WireFormat.success(["granted": granted, "error": error?.localizedDescription as Any? ?? NSNull()]))
            }
        } else {
            store.requestAccess(to: .reminder) { granted, error in
                if granted { store.reset() }
                completion(WireFormat.success(["granted": granted, "error": error?.localizedDescription as Any? ?? NSNull()]))
            }
        }
    }

    private func calendarDict(_ c: EKCalendar) -> [String: Any] {
        ["id": c.calendarIdentifier, "title": c.title, "allowsContentModifications": c.allowsContentModifications]
    }

    private func listLists(completion: @escaping @Sendable ([String: Any]) -> Void) {
        let lists = store.calendars(for: .reminder)
        completion(WireFormat.success(["lists": lists.map(calendarDict)]))
    }

    private func defaultList(completion: @escaping @Sendable ([String: Any]) -> Void) {
        if let c = store.defaultCalendarForNewReminders() {
            completion(WireFormat.success(calendarDict(c)))
        } else {
            completion(WireFormat.success(["list": NSNull()]))
        }
    }

    private func parseDate(_ raw: Any?) -> Date? {
        guard let s = raw as? String else { return nil }
        return isoFormatter.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    private func components(_ d: Date) -> DateComponents {
        Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
    }

    private func priorityValue(_ s: String?) -> Int {
        switch s {
        case "high": return 1
        case "medium": return 5
        case "low": return 9
        case "none": return 0
        default: return 0
        }
    }

    private func priorityString(_ p: Int) -> String {
        switch p {
        case 1...4: return "high"
        case 5: return "medium"
        case 6...9: return "low"
        default: return "none"
        }
    }

    private func reminderDict(_ r: EKReminder) -> [String: Any] {
        var out: [String: Any] = [
            "id": r.calendarItemIdentifier,
            "listId": r.calendar?.calendarIdentifier ?? "",
            "title": r.title ?? "",
            "isCompleted": r.isCompleted,
            "priority": priorityString(r.priority),
        ]
        if let d = r.completionDate { out["completionDate"] = isoFormatter.string(from: d) }
        if let n = r.notes { out["notes"] = n }
        if let url = r.url { out["url"] = url.absoluteString }
        if let s = r.startDateComponents { out["startDateComponents"] = encodeComponents(s) }
        if let due = r.dueDateComponents { out["dueDateComponents"] = encodeComponents(due) }
        if let alarms = r.alarms {
            out["alarms"] = alarms.map { a -> [String: Any] in
                var d: [String: Any] = ["relativeOffset": a.relativeOffset]
                if let abs = a.absoluteDate { d["absoluteDate"] = isoFormatter.string(from: abs) }
                return d
            }
        }
        if let rules = r.recurrenceRules {
            out["recurrenceRules"] = rules.map { rule -> [String: Any] in
                ["frequency": String(describing: rule.frequency), "interval": rule.interval]
            }
        }
        return out
    }

    private func encodeComponents(_ c: DateComponents) -> [String: Any] {
        var d: [String: Any] = [:]
        if let y = c.year { d["year"] = y }
        if let m = c.month { d["month"] = m }
        if let day = c.day { d["day"] = day }
        if let h = c.hour { d["hour"] = h }
        if let min = c.minute { d["minute"] = min }
        return d
    }

    private func resolveList(_ action: [String: Any]) -> EKCalendar? {
        if let id = action["list"] as? String, let c = store.calendar(withIdentifier: id) { return c }
        return store.defaultCalendarForNewReminders()
    }

    private func listAll(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let cals: [EKCalendar]? = (action["list"] as? String).flatMap { store.calendar(withIdentifier: $0).map { [$0] } }
        let predicate = store.predicateForReminders(in: cals)
        store.fetchReminders(matching: predicate) { reminders in
            completion(WireFormat.success(["reminders": (reminders ?? []).map(self.reminderDict)]))
        }
    }

    private func listIncomplete(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let cals: [EKCalendar]? = (action["list"] as? String).flatMap { store.calendar(withIdentifier: $0).map { [$0] } }
        let start = parseDate(action["due_start"])
        let end = parseDate(action["due_end"])
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: start, ending: end, calendars: cals)
        store.fetchReminders(matching: predicate) { reminders in
            completion(WireFormat.success(["reminders": (reminders ?? []).map(self.reminderDict)]))
        }
    }

    private func listCompleted(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let start = parseDate(action["since"]), let end = parseDate(action["until"]) else {
            completion(WireFormat.error("reminders.completed: --since and --until required (ISO8601)")); return
        }
        let cals: [EKCalendar]? = (action["list"] as? String).flatMap { store.calendar(withIdentifier: $0).map { [$0] } }
        let predicate = store.predicateForCompletedReminders(withCompletionDateStarting: start, ending: end, calendars: cals)
        store.fetchReminders(matching: predicate) { reminders in
            completion(WireFormat.success(["reminders": (reminders ?? []).map(self.reminderDict)]))
        }
    }

    private func createReminder(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let title = action["title"] as? String else { completion(WireFormat.error("reminders.create: --title required")); return }
        guard let cal = resolveList(action) else { completion(WireFormat.error("reminders.create: no list available — pass --list <id>")); return }
        let r = EKReminder(eventStore: store)
        r.title = title
        r.calendar = cal
        if let p = action["priority"] as? String { r.priority = priorityValue(p) }
        if let n = action["notes"] as? String { r.notes = n }
        if let urlStr = action["url"] as? String, let u = URL(string: urlStr) { r.url = u }
        if let due = parseDate(action["due"]) { r.dueDateComponents = components(due) }
        if let start = parseDate(action["start"]) { r.startDateComponents = components(start) }
        do {
            try store.save(r, commit: true)
            completion(WireFormat.success(reminderDict(r)))
        } catch {
            completion(WireFormat.error("reminders.create: \(error.localizedDescription)"))
        }
    }

    private func updateReminder(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let id = action["id"] as? String,
              let item = store.calendarItem(withIdentifier: id) as? EKReminder else {
            completion(WireFormat.error("reminders.update: unknown id")); return
        }
        if let title = action["title"] as? String { item.title = title }
        if let p = action["priority"] as? String { item.priority = priorityValue(p) }
        if let notes = action["notes"] as? String { item.notes = notes }
        if let urlStr = action["url"] as? String, let u = URL(string: urlStr) { item.url = u }
        if let due = parseDate(action["due"]) { item.dueDateComponents = components(due) }
        if let start = parseDate(action["start"]) { item.startDateComponents = components(start) }
        do {
            try store.save(item, commit: true)
            completion(WireFormat.success(reminderDict(item)))
        } catch {
            completion(WireFormat.error("reminders.update: \(error.localizedDescription)"))
        }
    }

    private func complete(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void, value: Bool) {
        guard let id = action["id"] as? String,
              let item = store.calendarItem(withIdentifier: id) as? EKReminder else {
            completion(WireFormat.error("reminders.complete/uncomplete: unknown id")); return
        }
        item.isCompleted = value
        do {
            try store.save(item, commit: true)
            completion(WireFormat.success(reminderDict(item)))
        } catch {
            completion(WireFormat.error("reminders.complete: \(error.localizedDescription)"))
        }
    }

    private func deleteReminder(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let id = action["id"] as? String,
              let item = store.calendarItem(withIdentifier: id) as? EKReminder else {
            completion(WireFormat.error("reminders.delete: unknown id")); return
        }
        do {
            try store.remove(item, commit: true)
            completion(WireFormat.success(["ok": true, "id": id]))
        } catch {
            completion(WireFormat.error("reminders.delete: \(error.localizedDescription)"))
        }
    }
}

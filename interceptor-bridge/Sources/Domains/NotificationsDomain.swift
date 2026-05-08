// PRD-66 Domain 9 — NotificationsDomain. Extends the original
// DistributedNotificationCenter tail/log verbs with the full UNUserNotificationCenter
// surface (post / schedule-* / pending / delivered / dismiss / categories /
// badge). Dispatch invariant per PRD-63: read action["sub"].

import Foundation
import UserNotifications
// NSApplication.setActivationPolicy is the documented escape-hatch for
// LSUIElement utilities that need TCC prompts to surface modally — see
// TrustDomain.checkMicrophone for the canonical pattern.
import AppKit

final class NotificationsDomain: DomainHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [[String: Any]] = []
    private var observing = false
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let unVerbs: Set<String> = [
        "status","request","settings","post","schedule-after","schedule-at",
        "schedule-cron","cancel","cancel-all","pending","delivered","dismiss",
        "dismiss-all","categories","badge",
    ]

    func handle(_ command: String, action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let sub = action["sub"] as? String ?? command
        // DistributedNotificationCenter verbs work in any process — never gate.
        switch sub {
        case "tail": startTailing(completion: completion); return
        case "log":  getLog(action, completion: completion); return
        default: break
        }
        // Unknown sub — surface the standard error before any bundle gate.
        guard Self.unVerbs.contains(sub) else {
            completion(WireFormat.error("notifications.\(sub) — unknown verb"))
            return
        }
        // UNUserNotificationCenter requires a registered .app bundle. Calling
        // current() in xctest aborts the process — return a structured error.
        guard hasAppBundle else {
            switch sub {
            case "schedule-after":
                if (action["seconds"] as? Int) == nil {
                    completion(WireFormat.error("notifications.schedule-after: --seconds <N> required"))
                    return
                }
            case "schedule-at":
                if (action["date"] as? String) == nil {
                    completion(WireFormat.error("notifications.schedule-at: --date <ISO8601> required"))
                    return
                }
            case "schedule-cron":
                if (action["components"] as? String) == nil {
                    completion(WireFormat.error("notifications.schedule-cron: --components key=val[,key=val] required"))
                    return
                }
            case "cancel":
                if (action["id"] as? String) == nil {
                    completion(WireFormat.error("notifications.cancel: <identifier> required"))
                    return
                }
            case "dismiss":
                if (action["id"] as? String) == nil {
                    completion(WireFormat.error("notifications.dismiss: <identifier> required"))
                    return
                }
            case "categories":
                if (action["verb"] as? String) == "register" {
                    completion(WireFormat.error("notifications.categories.register: --identifier and --actions <json> required"))
                    return
                }
            default: break
            }
            completion(WireFormat.error("notifications: UNUserNotificationCenter requires a registered .app bundle. Run inside the bridge bundle (`/Applications/Interceptor.app`), not the test runner."))
            return
        }
        switch sub {
        case "status":           unStatus(completion: completion)
        case "request":          unRequest(action, completion: completion)
        case "settings":         unSettings(completion: completion)
        case "post":             unPost(action, completion: completion)
        case "schedule-after":   unScheduleAfter(action, completion: completion)
        case "schedule-at":      unScheduleAt(action, completion: completion)
        case "schedule-cron":    unScheduleCron(action, completion: completion)
        case "cancel":           unCancel(action, completion: completion)
        case "cancel-all":       unCancelAll(completion: completion)
        case "pending":          unPending(completion: completion)
        case "delivered":        unDelivered(completion: completion)
        case "dismiss":          unDismiss(action, completion: completion)
        case "dismiss-all":      unDismissAll(completion: completion)
        case "categories":       unCategories(action, completion: completion)
        case "badge":            unBadge(action, completion: completion)
        default:                 completion(WireFormat.error("notifications.\(sub) — unknown verb"))
        }
    }

    // MARK: - DistributedNotificationCenter (existing)

    private func startTailing(completion: @escaping @Sendable ([String: Any]) -> Void) {
        if !observing {
            observing = true
            DistributedNotificationCenter.default().addObserver(
                forName: nil, object: nil, queue: nil
            ) { [weak self] notification in
                let entry: [String: Any] = [
                    "name": notification.name.rawValue,
                    "object": notification.object as? String ?? "",
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                ]
                self?.lock.lock()
                self?.captured.append(entry)
                if (self?.captured.count ?? 0) > 1000 { self?.captured.removeFirst(500) }
                self?.lock.unlock()
            }
        }
        completion(WireFormat.success(["tailing": true]))
    }

    private func getLog(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let limit = action["limit"] as? Int ?? 50
        let appFilter = action["app"] as? String
        lock.lock()
        var results = Array(captured.suffix(limit))
        lock.unlock()
        if let appFilter = appFilter {
            results = results.filter { entry in
                (entry["object"] as? String)?.contains(appFilter) == true ||
                (entry["name"] as? String)?.contains(appFilter) == true
            }
        }
        completion(WireFormat.success(results))
    }

    // MARK: - UNUserNotificationCenter (PRD-66)

    /// `UNUserNotificationCenter.current()` raises NSInternalInconsistencyException
    /// when the host process isn't inside a real `.app` bundle. xctest's host
    /// bundle has a bundleIdentifier (`com.apple.dt.xctest.tool`) but is NOT a
    /// `.app`, and UN center init aborts the process. Detect both conditions
    /// up front so the bridge surfaces a structured error instead of crashing.
    private var hasAppBundle: Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        // xctest sets XCTestConfigurationFilePath; treat that as "no app bundle".
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return false }
        // Host bundle path must end in .app for UN center to be safe.
        return Bundle.main.bundlePath.hasSuffix(".app")
    }

    private func unCenter() -> UNUserNotificationCenter { UNUserNotificationCenter.current() }

    private func unGuard(_ completion: @escaping @Sendable ([String: Any]) -> Void) -> Bool {
        if !hasAppBundle {
            completion(WireFormat.error("notifications: UNUserNotificationCenter requires a registered .app bundle. Run inside the bridge bundle (`/Applications/Interceptor.app`), not the test runner."))
            return false
        }
        return true
    }

    private func unStatus(completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard unGuard(completion) else { return }
        unCenter().getNotificationSettings { settings in
            completion(WireFormat.success([
                "status": self.statusString(settings.authorizationStatus),
                "alertSetting": self.settingString(settings.alertSetting),
                "soundSetting": self.settingString(settings.soundSetting),
                "badgeSetting": self.settingString(settings.badgeSetting),
                "lockScreenSetting": self.settingString(settings.lockScreenSetting),
                "notificationCenterSetting": self.settingString(settings.notificationCenterSetting),
                "criticalAlertSetting": self.settingString(settings.criticalAlertSetting),
                "alertStyle": String(describing: settings.alertStyle),
                "showsPreviews": String(describing: settings.showPreviewsSetting),
                "providesAppNotificationSettings": settings.providesAppNotificationSettings,
                "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            ]))
        }
    }

    private func statusString(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .denied:        return "denied"
        case .authorized:    return "authorized"
        case .provisional:   return "provisional"
        case .ephemeral:     return "ephemeral"
        @unknown default:    return "unknown"
        }
    }

    private func settingString(_ s: UNNotificationSetting) -> String {
        switch s {
        case .enabled: return "enabled"
        case .disabled: return "disabled"
        case .notSupported: return "notSupported"
        @unknown default: return "unknown"
        }
    }

    private func unRequest(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard unGuard(completion) else { return }
        var options: UNAuthorizationOptions = []
        let raw = (action["options"] as? String) ?? "alert,sound,badge"
        for opt in raw.split(separator: ",") {
            switch opt.trimmingCharacters(in: .whitespaces) {
            case "alert": options.insert(.alert)
            case "sound": options.insert(.sound)
            case "badge": options.insert(.badge)
            case "criticalAlert": options.insert(.criticalAlert)
            case "provisional": options.insert(.provisional)
            case "providesAppNotificationSettings": options.insert(.providesAppNotificationSettings)
            default: break
            }
        }
        // LSUIElement-attached caveat: a background-only agent calling
        // UNUserNotificationCenter.requestAuthorization gets denied with
        // "Notifications are not allowed for this application" because the
        // OS does not surface the registration banner to a faceless app.
        // Mirror the TrustDomain.checkMicrophone pattern: temporarily
        // upgrade activation policy to .regular so macOS recognizes the
        // bridge as a foreground process for the duration of the prompt,
        // then revert to .accessory once the completion handler fires.
        let isLiveBridge = Bundle.main.bundleIdentifier == "com.interceptor.bridge"
        if isLiveBridge {
            DispatchQueue.main.async {
                NSApplication.shared.setActivationPolicy(.regular)
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
        let center = unCenter()
        center.requestAuthorization(options: options) { granted, error in
            if isLiveBridge {
                DispatchQueue.main.async {
                    NSApplication.shared.setActivationPolicy(.accessory)
                }
            }
            // macOS quirk: requestAuthorization returns
            // "Notifications are not allowed for this application" for
            // LSUIElement (background-only) bundles even when the per-
            // feature toggles in System Settings → Notifications are
            // enabled and notifications actually deliver. Detect that
            // mismatch by inspecting NotificationSettings and surface an
            // honest "effectively granted" response so callers don't
            // mis-interpret the auth-layer denial as a hard block.
            center.getNotificationSettings { settings in
                let perFeatureEnabled =
                    settings.alertSetting == .enabled ||
                    settings.soundSetting == .enabled ||
                    settings.badgeSetting == .enabled ||
                    settings.notificationCenterSetting == .enabled
                let effectiveGrant = granted || perFeatureEnabled
                var resp: [String: Any] = [
                    "granted": effectiveGrant,
                    "options": Array(raw.split(separator: ",").map(String.init)),
                ]
                if let error = error {
                    resp["error"] = error.localizedDescription
                } else {
                    resp["error"] = NSNull()
                }
                if !granted && perFeatureEnabled {
                    resp["note"] = "auth-layer denied (LSUIElement quirk) but per-feature settings are enabled — notifications post and deliver. Open System Settings → Notifications → interceptor-bridge to manage."
                } else if !granted {
                    resp["note"] = "Notifications denied. Open System Settings → Notifications → interceptor-bridge to grant alert/sound/badge."
                }
                completion(WireFormat.success(resp))
            }
        }
    }

    private func unSettings(completion: @escaping @Sendable ([String: Any]) -> Void) {
        unStatus(completion: completion) // identical surface
    }

    private func buildContent(_ action: [String: Any]) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        if let title = action["title"] as? String { content.title = title }
        if let subtitle = action["subtitle"] as? String { content.subtitle = subtitle }
        if let body = action["body"] as? String { content.body = body }
        if let sound = action["sound"] as? String {
            switch sound {
            case "default": content.sound = .default
            case "critical":
                if #available(macOS 12, *) { content.sound = .defaultCritical }
            default:
                content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: sound))
            }
        }
        if let badge = action["badge"] as? Int { content.badge = NSNumber(value: badge) }
        if let cat = action["category"] as? String { content.categoryIdentifier = cat }
        if let thread = action["thread"] as? String { content.threadIdentifier = thread }
        if let userInfoStr = action["user_info"] as? String,
           let data = userInfoStr.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            content.userInfo = dict
        }
        if #available(macOS 12, *), let level = action["interruption"] as? String {
            switch level {
            case "active": content.interruptionLevel = .active
            case "passive": content.interruptionLevel = .passive
            case "timeSensitive": content.interruptionLevel = .timeSensitive
            default: break
            }
        }
        if let attachStr = action["attachment"] as? String {
            for raw in attachStr.split(separator: ",") {
                let parts = raw.split(separator: "=", maxSplits: 1)
                let id = parts.count == 2 ? String(parts[0]) : "att-\(UUID().uuidString.prefix(8))"
                let path = parts.count == 2 ? String(parts[1]) : String(raw)
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                if let attachment = try? UNNotificationAttachment(identifier: id, url: url) {
                    content.attachments.append(attachment)
                }
            }
        }
        return content
    }

    private func add(_ request: UNNotificationRequest, trigger: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard unGuard(completion) else { return }
        let identifier = request.identifier
        let categoryId = request.content.categoryIdentifier
        unCenter().add(request) { error in
            if let error = error {
                completion(WireFormat.error("notifications: \(error.localizedDescription)"))
            } else {
                completion(WireFormat.success([
                    "ok": true,
                    "identifier": identifier,
                    "trigger": trigger,
                    "categoryIdentifier": categoryId,
                ]))
            }
        }
    }

    private func unPost(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let content = buildContent(action)
        let identifier = (action["id"] as? String) ?? "interceptor-\(UUID().uuidString)"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        add(request, trigger: ["type": "timeInterval", "seconds": 1, "repeats": false], completion: completion)
    }

    private func unScheduleAfter(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let seconds = action["seconds"] as? Int, seconds > 0 else {
            completion(WireFormat.error("notifications.schedule-after: --seconds <N> required")); return
        }
        let repeats = (action["repeats"] as? Bool) ?? false
        let content = buildContent(action)
        let identifier = (action["id"] as? String) ?? "interceptor-\(UUID().uuidString)"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds), repeats: repeats)
        let req = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        add(req, trigger: ["type": "timeInterval", "seconds": seconds, "repeats": repeats], completion: completion)
    }

    private func unScheduleAt(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let dateStr = action["date"] as? String,
              let date = isoFormatter.date(from: dateStr) ?? ISO8601DateFormatter().date(from: dateStr)
        else { completion(WireFormat.error("notifications.schedule-at: --date <ISO8601> required")); return }
        let repeats = (action["repeats"] as? Bool) ?? false
        let content = buildContent(action)
        let identifier = (action["id"] as? String) ?? "interceptor-\(UUID().uuidString)"
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: repeats)
        let req = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        var componentsDict: [String: Any] = [:]
        if let y = comps.year { componentsDict["year"] = y } else { componentsDict["year"] = NSNull() }
        if let m = comps.month { componentsDict["month"] = m } else { componentsDict["month"] = NSNull() }
        if let d = comps.day { componentsDict["day"] = d } else { componentsDict["day"] = NSNull() }
        if let h = comps.hour { componentsDict["hour"] = h } else { componentsDict["hour"] = NSNull() }
        if let mi = comps.minute { componentsDict["minute"] = mi } else { componentsDict["minute"] = NSNull() }
        add(req, trigger: ["type": "calendar", "components": componentsDict, "repeats": repeats], completion: completion)
    }

    private func unScheduleCron(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let raw = action["components"] as? String else {
            completion(WireFormat.error("notifications.schedule-cron: --components key=val[,key=val] required")); return
        }
        var comps = DateComponents()
        for entry in raw.split(separator: ",") {
            let parts = entry.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let v = Int(parts[1]) else { continue }
            switch String(parts[0]).trimmingCharacters(in: .whitespaces) {
            case "year": comps.year = v
            case "month": comps.month = v
            case "day": comps.day = v
            case "weekday": comps.weekday = v
            case "hour": comps.hour = v
            case "minute": comps.minute = v
            case "second": comps.second = v
            default: break
            }
        }
        let repeats = (action["repeats"] as? Bool) ?? true
        let content = buildContent(action)
        let identifier = (action["id"] as? String) ?? "interceptor-\(UUID().uuidString)"
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: repeats)
        let req = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        add(req, trigger: ["type": "calendar", "raw_components": raw, "repeats": repeats], completion: completion)
    }

    private func unCancel(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let id = action["id"] as? String else {
            completion(WireFormat.error("notifications.cancel: <identifier> required")); return
        }
        guard unGuard(completion) else { return }
        unCenter().removePendingNotificationRequests(withIdentifiers: [id])
        completion(WireFormat.success(["ok": true, "id": id]))
    }

    private func unCancelAll(completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard unGuard(completion) else { return }
        unCenter().removeAllPendingNotificationRequests()
        completion(WireFormat.success(["ok": true]))
    }

    private func unPending(completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard unGuard(completion) else { return }
        unCenter().getPendingNotificationRequests { requests in
            let arr = requests.map { self.requestDict($0) }
            completion(WireFormat.success(["requests": arr]))
        }
    }

    private func unDelivered(completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard unGuard(completion) else { return }
        unCenter().getDeliveredNotifications { delivered in
            let arr = delivered.map { d -> [String: Any] in
                var e = self.requestDict(d.request)
                e["deliveryDate"] = self.isoFormatter.string(from: d.date)
                return e
            }
            completion(WireFormat.success(["delivered": arr]))
        }
    }

    private func requestDict(_ request: UNNotificationRequest) -> [String: Any] {
        var entry: [String: Any] = [
            "identifier": request.identifier,
            "title": request.content.title,
            "subtitle": request.content.subtitle,
            "body": request.content.body,
            "categoryIdentifier": request.content.categoryIdentifier,
            "threadIdentifier": request.content.threadIdentifier,
            "userInfo": request.content.userInfo,
        ]
        if let badge = request.content.badge { entry["badge"] = badge.intValue }
        entry["sound"] = request.content.sound != nil ? "set" : NSNull()
        if #available(macOS 12, *) {
            entry["interruptionLevel"] = String(describing: request.content.interruptionLevel)
        }
        if let trig = request.trigger {
            var t: [String: Any] = ["repeats": trig.repeats]
            if let ti = trig as? UNTimeIntervalNotificationTrigger {
                t["type"] = "timeInterval"
                t["seconds"] = ti.timeInterval
            } else if let cal = trig as? UNCalendarNotificationTrigger {
                t["type"] = "calendar"
                t["nextTriggerDate"] = cal.nextTriggerDate().map { isoFormatter.string(from: $0) } as Any? ?? NSNull()
            } else {
                t["type"] = String(describing: type(of: trig))
            }
            entry["trigger"] = t
        }
        entry["attachments"] = request.content.attachments.map { att -> [String: Any] in
            ["identifier": att.identifier, "url": att.url.absoluteString, "type": att.type as Any? ?? NSNull()]
        }
        return entry
    }

    private func unDismiss(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let id = action["id"] as? String else {
            completion(WireFormat.error("notifications.dismiss: <identifier> required")); return
        }
        guard unGuard(completion) else { return }
        unCenter().removeDeliveredNotifications(withIdentifiers: [id])
        completion(WireFormat.success(["ok": true, "id": id]))
    }

    private func unDismissAll(completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard unGuard(completion) else { return }
        unCenter().removeAllDeliveredNotifications()
        completion(WireFormat.success(["ok": true]))
    }

    private func unCategories(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard unGuard(completion) else { return }
        let verb = (action["verb"] as? String) ?? (action["sub2"] as? String) ?? "list"
        switch verb {
        case "list":
            unCenter().getNotificationCategories { cats in
                let arr = cats.map { c -> [String: Any] in
                    [
                        "identifier": c.identifier,
                        "actions": c.actions.map { ["identifier": $0.identifier, "title": $0.title] },
                        "intentIdentifiers": c.intentIdentifiers,
                        "options": c.options.rawValue,
                    ]
                }
                completion(WireFormat.success(["categories": arr]))
            }
        case "register":
            guard let id = action["identifier"] as? String,
                  let actionsJson = action["actions"] as? String,
                  let data = actionsJson.data(using: .utf8),
                  let actionsArr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { completion(WireFormat.error("notifications.categories.register: --identifier and --actions <json> required")); return }
            let unActions: [UNNotificationAction] = actionsArr.compactMap { dict in
                guard let aId = dict["identifier"] as? String, let title = dict["title"] as? String else { return nil }
                var opts: UNNotificationActionOptions = []
                if let raw = dict["options"] as? [String] {
                    if raw.contains("foreground") { opts.insert(.foreground) }
                    if raw.contains("destructive") { opts.insert(.destructive) }
                    if raw.contains("authenticationRequired") { opts.insert(.authenticationRequired) }
                }
                return UNNotificationAction(identifier: aId, title: title, options: opts)
            }
            let intentIds = (action["intent_identifiers"] as? String)?.split(separator: ",").map(String.init) ?? []
            let cat = UNNotificationCategory(identifier: id, actions: unActions, intentIdentifiers: intentIds)
            unCenter().setNotificationCategories(Set([cat]))
            completion(WireFormat.success(["ok": true, "identifier": id]))
        case "clear":
            unCenter().setNotificationCategories(Set<UNNotificationCategory>())
            completion(WireFormat.success(["ok": true]))
        default:
            completion(WireFormat.error("notifications.categories: unknown verb \(verb)"))
        }
    }

    private func unBadge(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard unGuard(completion) else { return }
        let count = (action["count"] as? Int) ?? (action["clear"] as? Bool == true ? 0 : 0)
        if #available(macOS 13, *) {
            unCenter().setBadgeCount(count) { error in
                if let error = error { completion(WireFormat.error("notifications.badge: \(error.localizedDescription)")) }
                else { completion(WireFormat.success(["ok": true, "count": count])) }
            }
        } else {
            completion(WireFormat.success(["ok": true, "count": count, "note": "setBadgeCount requires macOS 13+"]))
        }
    }
}

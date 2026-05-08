// PRD-66 Domain 14 — NSSharingService. macOS 10.8+. Background-first save:
// AirDrop sheet is OS-rendered above the sender, but `performWithItems:` does
// not raise the calling bridge. References:
// apple-developer-docs/AppKit/NSSharingService.md.

import Foundation
import AppKit

final class ShareDomain: DomainHandler, @unchecked Sendable {
    func handle(_ command: String, action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let sub = action["sub"] as? String ?? command
        switch sub {
        case "services":         services(action, completion: completion)
        case "airdrop":          run(named: NSSharingService.Name.sendViaAirDrop, action: action, completion: completion)
        case "email":            run(named: NSSharingService.Name.composeEmail, action: action, completion: completion)
        case "message":          run(named: NSSharingService.Name.composeMessage, action: action, completion: completion)
        case "reading-list":     run(named: NSSharingService.Name.addToSafariReadingList, action: action, completion: completion)
        case "desktop-picture":  run(named: NSSharingService.Name.useAsDesktopPicture, action: action, completion: completion)
        case "named":            runNamed(action: action, completion: completion)
        case "text":             runStringOrUrl(action: action, completion: completion, isUrl: false)
        case "url":              runStringOrUrl(action: action, completion: completion, isUrl: true)
        default:                 completion(WireFormat.error("share.\(sub) — unknown verb"))
        }
    }

    /// Builds the share payload from any combination of:
    ///   - `items` array (filesystem paths, urls, or strings)
    ///   - `text` flag (plain string)
    ///   - `url` flag (parsed as URL)
    ///   - `body` flag (alias for text)
    /// At least one source must produce a non-empty list, otherwise
    /// NSSharingService.canPerform(withItems:) will reject the share.
    private func resolveItems(_ action: [String: Any]) -> [Any] {
        var out: [Any] = []
        if let raw = action["items"] as? [String] {
            for p in raw {
                let expanded = (p as NSString).expandingTildeInPath
                if FileManager.default.fileExists(atPath: expanded) {
                    out.append(URL(fileURLWithPath: expanded))
                } else if let url = URL(string: p), url.scheme != nil {
                    out.append(url)
                } else {
                    out.append(p)
                }
            }
        }
        if let t = action["text"] as? String, !t.isEmpty { out.append(t) }
        if let u = action["url"] as? String, !u.isEmpty {
            if let url = URL(string: u), url.scheme != nil { out.append(url) } else { out.append(u) }
        }
        if let b = action["body"] as? String, !b.isEmpty { out.append(b) }
        return out
    }

    /// Apple's `NSSharingService(named:)` only accepts canonical raw names
    /// (e.g. `com.apple.share.composeMessage`). The `services` enumerator
    /// returns NSSharingService instances whose `.title` is a localized
    /// display string (e.g. "Messages"). The CLI surface accepts either
    /// form — we resolve the supplied identifier against (1) the raw-value
    /// init, then (2) the live services-for-items title list, and (3) a
    /// short alias map for friendly common names.
    private func resolveService(_ identifier: String, items: [Any]) -> NSSharingService? {
        // (1) Direct raw-name init.
        if let svc = NSSharingService(named: NSSharingService.Name(rawValue: identifier)) {
            return svc
        }
        // (2) Live title match against services-for-these-items.
        let probeItems: [Any] = items.isEmpty ? [URL(fileURLWithPath: "/tmp/")] : items
        let live = NSSharingService.sharingServices(forItems: probeItems)
        if let match = live.first(where: { $0.title.compare(identifier, options: .caseInsensitive) == .orderedSame }) {
            return match
        }
        // (3) Friendly aliases for the common cases.
        let alias: [String: NSSharingService.Name] = [
            "airdrop":          .sendViaAirDrop,
            "mail":             .composeEmail,
            "email":            .composeEmail,
            "messages":         .composeMessage,
            "message":          .composeMessage,
            "reading list":     .addToSafariReadingList,
            "reading-list":     .addToSafariReadingList,
            "desktop":          .useAsDesktopPicture,
            "desktop picture":  .useAsDesktopPicture,
            "desktop-picture":  .useAsDesktopPicture,
        ]
        if let n = alias[identifier.lowercased()], let svc = NSSharingService(named: n) {
            return svc
        }
        return nil
    }

    private func services(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        // Probe with two sentinel item types so we capture both file-only and string services.
        let sentinelURL: URL = URL(fileURLWithPath: "/tmp/")
        let sentinelText: String = "interceptor-sentinel"
        let unionRaw = NSSharingService.sharingServices(forItems: [sentinelURL]) + NSSharingService.sharingServices(forItems: [sentinelText])
        var seen = Set<String>()
        let union = unionRaw.filter { svc in
            let name = svc.title // not stable across locales but unique enough for dedupe
            if seen.contains(name) { return false }
            seen.insert(name)
            return true
        }
        let forFlag = action["for_item"] as? String
        let scoped: [NSSharingService]
        if let path = forFlag {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            scoped = NSSharingService.sharingServices(forItems: [url])
        } else {
            scoped = union
        }
        let dicts = scoped.map { svc -> [String: Any] in
            return [
                "title": svc.title,
                "menuItemTitle": svc.menuItemTitle,
                "canPerform": true,
            ]
        }
        completion(WireFormat.success(["services": dicts]))
    }

    private func run(named name: NSSharingService.Name, action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let items = resolveItems(action)
        guard let svc = NSSharingService(named: name) else {
            completion(WireFormat.error("share: service \(name.rawValue) is not available")); return
        }
        configure(svc, with: action)
        guard svc.canPerform(withItems: items) else {
            completion(WireFormat.error("share: service \(name.rawValue) cannot share these items (got \(items.count) item(s)). Pass --text, --url, or --items <path>."))
            return
        }
        // ShareKit's `performStandardServiceWithItems:` raises an ObjC
        // NSException for some services (Messages, Notes, Reminders…) when
        // invoked from a background-only daemon — it expects a foreground UI
        // context. Return success to the IPC client first, then dispatch
        // perform on the main queue so a thrown exception kills only the
        // dispatched block, not the synchronous response path. The
        // share-sheet activation is fire-and-forget from the bridge's view.
        completion(WireFormat.success([
            "ok": true,
            "service": name.rawValue,
            "items": items.map { String(describing: $0) },
            "recipients": svc.recipients ?? [],
            "subject": svc.subject as Any? ?? NSNull(),
            "note": "perform dispatched async; share UI activation is fire-and-forget from a background daemon.",
        ]))
        // NSSharingService and items are not Sendable; box them through
        // nonisolated(unsafe) captures to satisfy Swift 6 strict concurrency.
        nonisolated(unsafe) let svcCapture = svc
        nonisolated(unsafe) let itemsCapture = items
        DispatchQueue.main.async {
            svcCapture.perform(withItems: itemsCapture)
        }
    }

    private func runNamed(action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let serviceName = action["service"] as? String else {
            completion(WireFormat.error("share.named: --service required")); return
        }
        let items = resolveItems(action)
        guard let svc = resolveService(serviceName, items: items) else {
            let live = NSSharingService.sharingServices(forItems: items.isEmpty ? [URL(fileURLWithPath: "/tmp/")] : items)
            completion(WireFormat.error("share.named: \"\(serviceName)\" not found. Live titles: \(live.map { $0.title }). Aliases: airdrop, email, messages, reading-list, desktop-picture."))
            return
        }
        configure(svc, with: action)
        guard svc.canPerform(withItems: items) else {
            completion(WireFormat.error("share.named: service \(svc.title) cannot share these items (got \(items.count) item(s)). Pass --text, --url, or --items <path>."))
            return
        }
        completion(WireFormat.success([
            "ok": true, "service": svc.title, "items": items.map { String(describing: $0) },
            "note": "perform dispatched async; share UI activation is fire-and-forget from a background daemon.",
        ]))
        // NSSharingService and items are not Sendable; box them through
        // nonisolated(unsafe) captures to satisfy Swift 6 strict concurrency.
        nonisolated(unsafe) let svcCapture = svc
        nonisolated(unsafe) let itemsCapture = items
        DispatchQueue.main.async {
            svcCapture.perform(withItems: itemsCapture)
        }
    }

    private func runStringOrUrl(action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void, isUrl: Bool) {
        guard let value = action["value"] as? String else {
            completion(WireFormat.error("share: --value required")); return
        }
        let item: Any = isUrl ? ((URL(string: value)) ?? value) : value
        let items: [Any] = [item]
        guard let serviceName = action["service"] as? String else {
            completion(WireFormat.error("share: --service required")); return
        }
        guard let svc = resolveService(serviceName, items: items) else {
            let live = NSSharingService.sharingServices(forItems: items)
            completion(WireFormat.error("share: \"\(serviceName)\" not found. Live titles: \(live.map { $0.title })."))
            return
        }
        configure(svc, with: action)
        guard svc.canPerform(withItems: items) else {
            completion(WireFormat.error("share: service \(svc.title) cannot share these items"))
            return
        }
        completion(WireFormat.success([
            "ok": true, "service": svc.title,
            "note": "perform dispatched async; share UI activation is fire-and-forget from a background daemon.",
        ]))
        // NSSharingService and items are not Sendable; box them through
        // nonisolated(unsafe) captures to satisfy Swift 6 strict concurrency.
        nonisolated(unsafe) let svcCapture = svc
        nonisolated(unsafe) let itemsCapture = items
        DispatchQueue.main.async {
            svcCapture.perform(withItems: itemsCapture)
        }
    }

    private func configure(_ svc: NSSharingService, with action: [String: Any]) {
        if let r = action["recipient"] as? String { svc.recipients = [r] }
        if let r = action["recipients"] as? [String] { svc.recipients = r }
        if let s = action["subject"] as? String { svc.subject = s }
    }
}

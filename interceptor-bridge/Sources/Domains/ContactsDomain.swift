// PRD-66 Domain 7 — Contacts. macOS 10.11+; CNChangeHistoryFetchRequest macOS 10.15+.
// References: apple-developer-docs/Contacts/{CNContactStore,CNContact,CNContactFetchRequest,
// CNSaveRequest,CNGroup,CNAuthorizationStatus,CNChangeHistoryFetchRequest,...}.md.

import Foundation
import Contacts

final class ContactsDomain: DomainHandler, @unchecked Sendable {
    private let store = CNContactStore()
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func handle(_ command: String, action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let sub = action["sub"] as? String ?? command
        switch sub {
        case "status":               status(completion: completion)
        case "request":              requestAccess(completion: completion)
        case "containers":           containers(completion: completion)
        case "default-container":    defaultContainer(completion: completion)
        case "groups":               groups(action, completion: completion)
        case "group":                groupGet(action, completion: completion)
        case "group-create":         groupCreate(action, completion: completion)
        case "group-update":         groupUpdate(action, completion: completion)
        case "group-delete":         groupDelete(action, completion: completion)
        case "group-add-member":     groupMember(action, completion: completion, add: true)
        case "group-remove-member":  groupMember(action, completion: completion, add: false)
        case "list":                 listContacts(action, completion: completion)
        case "contact":              getContact(action, completion: completion)
        case "me":                   meContact(completion: completion)
        case "find":                 findContacts(action, completion: completion)
        case "create":               createContact(action, completion: completion)
        case "update":               updateContact(action, completion: completion)
        case "delete":               deleteContact(action, completion: completion)
        case "vcard":                vcard(action, completion: completion)
        case "import-vcard":         importVcard(action, completion: completion)
        case "current-token":        currentToken(completion: completion)
        case "changes":              changes(action, completion: completion)
        default:                     completion(WireFormat.error("contacts.\(sub) — unknown verb"))
        }
    }

    // MARK: - Helpers

    private func authStatusString(_ s: CNAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .restricted:    return "restricted"
        case .denied:        return "denied"
        case .authorized:    return "authorized"
        case .limited:       return "limited"
        @unknown default:    return "unknown"
        }
    }

    private func defaultKeys() -> [CNKeyDescriptor] {
        var keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactNamePrefixKey as CNKeyDescriptor,
            CNContactNameSuffixKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            // contactDict reads the four phonetic-name properties. They must
            // be in keysToFetch — otherwise CNContact throws
            // CNPropertyNotFetchedException on first access and crashes the
            // bridge mid-serialization.
            CNContactPhoneticGivenNameKey as CNKeyDescriptor,
            CNContactPhoneticMiddleNameKey as CNKeyDescriptor,
            CNContactPhoneticFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneticOrganizationNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactDepartmentNameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor,
            CNContactUrlAddressesKey as CNKeyDescriptor,
            CNContactSocialProfilesKey as CNKeyDescriptor,
            CNContactInstantMessageAddressesKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor,
            CNContactNonGregorianBirthdayKey as CNKeyDescriptor,
            CNContactDatesKey as CNKeyDescriptor,
            CNContactImageDataAvailableKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
            CNContactRelationsKey as CNKeyDescriptor,
            CNContactTypeKey as CNKeyDescriptor,
        ]
        return keys
    }

    private func contactDict(_ c: CNContact, includeNote: Bool = false, includeImage: Bool = false, includeThumbnail: Bool = true) -> [String: Any] {
        var out: [String: Any] = [
            "id": c.identifier,
            "contactType": c.contactType == .person ? "person" : "organization",
            "namePrefix": c.namePrefix,
            "givenName": c.givenName,
            "middleName": c.middleName,
            "familyName": c.familyName,
            "nameSuffix": c.nameSuffix,
            "nickname": c.nickname,
            "phonetic": [
                "given": c.phoneticGivenName,
                "middle": c.phoneticMiddleName,
                "family": c.phoneticFamilyName,
            ],
            "organization": [
                "name": c.organizationName,
                "department": c.departmentName,
                "jobTitle": c.jobTitle,
                "phonetic": c.phoneticOrganizationName,
            ],
            "emailAddresses": c.emailAddresses.map { ["label": labelString($0.label), "value": $0.value as String] },
            "phoneNumbers": c.phoneNumbers.map { ["label": labelString($0.label), "value": $0.value.stringValue] },
            "urlAddresses": c.urlAddresses.map { ["label": labelString($0.label), "value": $0.value as String] },
            "socialProfiles": c.socialProfiles.map { lp -> [String: Any] in
                ["label": labelString(lp.label),
                 "service": lp.value.service,
                 "username": lp.value.username,
                 "url": lp.value.urlString]
            },
            "instantMessageAddresses": c.instantMessageAddresses.map { lp -> [String: Any] in
                ["label": labelString(lp.label),
                 "service": lp.value.service,
                 "username": lp.value.username]
            },
            "contactRelations": c.contactRelations.map { lp -> [String: Any] in
                ["label": labelString(lp.label), "name": lp.value.name]
            },
            "imageDataAvailable": c.imageDataAvailable,
        ]
        out["postalAddresses"] = c.postalAddresses.map { lp -> [String: Any] in
            let p = lp.value
            return [
                "label": labelString(lp.label),
                "street": p.street,
                "city": p.city,
                "state": p.state,
                "postalCode": p.postalCode,
                "country": p.country,
                "isoCountryCode": p.isoCountryCode,
            ]
        }
        out["dates"] = c.dates.map { lp -> [String: Any] in
            ["label": labelString(lp.label), "date": isoFormatter.string(from: dateFrom(lp.value) ?? Date(timeIntervalSince1970: 0))]
        }
        if let bday = c.birthday, let d = bday.date {
            out["birthday"] = isoFormatter.string(from: d)
        }
        if includeThumbnail, let data = c.thumbnailImageData {
            out["thumbnailDataUrl"] = "data:image/jpeg;base64,\(data.base64EncodedString())"
        }
        if includeImage, let data = c.imageData {
            out["imageDataUrl"] = "data:image/jpeg;base64,\(data.base64EncodedString())"
        }
        if includeNote {
            out["note"] = (try? c.value(forKey: CNContactNoteKey) as? String) ?? NSNull()
        } else {
            out["note"] = NSNull()
            out["requires_entitlement"] = "com.apple.developer.contacts.notes"
        }
        return out
    }

    private func labelString(_ raw: String?) -> String {
        guard let raw = raw else { return "" }
        return CNLabeledValue<NSString>.localizedString(forLabel: raw)
    }

    private func dateFrom(_ comps: NSDateComponents) -> Date? {
        Calendar.current.date(from: comps as DateComponents)
    }

    // MARK: - Verbs

    private func status(completion: @escaping @Sendable ([String: Any]) -> Void) {
        completion(WireFormat.success([
            "status": authStatusString(CNContactStore.authorizationStatus(for: .contacts)),
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "supportsLimited": true,
            "notesEntitlement": false,
        ]))
    }

    private func requestAccess(completion: @escaping @Sendable ([String: Any]) -> Void) {
        store.requestAccess(for: .contacts) { granted, error in
            completion(WireFormat.success([
                "granted": granted,
                "error": error?.localizedDescription as Any? ?? NSNull(),
            ]))
        }
    }

    private func containers(completion: @escaping @Sendable ([String: Any]) -> Void) {
        do {
            let result = try store.containers(matching: nil)
            let arr = result.map { c -> [String: Any] in
                ["id": c.identifier, "name": c.name, "type": String(describing: c.type)]
            }
            completion(WireFormat.success(["containers": arr]))
        } catch {
            completion(WireFormat.error("contacts.containers: \(error.localizedDescription)"))
        }
    }

    private func defaultContainer(completion: @escaping @Sendable ([String: Any]) -> Void) {
        completion(WireFormat.success(["id": store.defaultContainerIdentifier()]))
    }

    private func groups(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let pred: NSPredicate? = {
            if let cid = action["container"] as? String {
                return CNGroup.predicateForGroupsInContainer(withIdentifier: cid)
            }
            return nil
        }()
        do {
            let result = try store.groups(matching: pred)
            let arr = result.map { ["id": $0.identifier, "name": $0.name] }
            completion(WireFormat.success(["groups": arr]))
        } catch {
            completion(WireFormat.error("contacts.groups: \(error.localizedDescription)"))
        }
    }

    private func groupGet(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let id = action["id"] as? String else { completion(WireFormat.error("contacts.group: <id> required")); return }
        do {
            let groups = try store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [id]))
            guard let g = groups.first else { completion(WireFormat.error("contacts.group: not found")); return }
            completion(WireFormat.success(["id": g.identifier, "name": g.name]))
        } catch {
            completion(WireFormat.error("contacts.group: \(error.localizedDescription)"))
        }
    }

    private func groupCreate(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let name = action["name"] as? String else { completion(WireFormat.error("contacts.group-create: --name required")); return }
        let g = CNMutableGroup()
        g.name = name
        let saveRequest = CNSaveRequest()
        let containerId = action["container"] as? String
        saveRequest.add(g, toContainerWithIdentifier: containerId)
        do {
            try store.execute(saveRequest)
            completion(WireFormat.success(["id": g.identifier, "name": g.name]))
        } catch {
            completion(WireFormat.error("contacts.group-create: \(error.localizedDescription)"))
        }
    }

    private func groupUpdate(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let id = action["id"] as? String, let name = action["name"] as? String else {
            completion(WireFormat.error("contacts.group-update: <id> and --name required")); return
        }
        do {
            let groups = try store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [id]))
            guard let g = groups.first?.mutableCopy() as? CNMutableGroup else {
                completion(WireFormat.error("contacts.group-update: not found")); return
            }
            g.name = name
            let saveRequest = CNSaveRequest()
            saveRequest.update(g)
            try store.execute(saveRequest)
            completion(WireFormat.success(["id": g.identifier, "name": g.name]))
        } catch {
            completion(WireFormat.error("contacts.group-update: \(error.localizedDescription)"))
        }
    }

    private func groupDelete(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let id = action["id"] as? String else { completion(WireFormat.error("contacts.group-delete: <id> required")); return }
        do {
            let groups = try store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [id]))
            guard let g = groups.first?.mutableCopy() as? CNMutableGroup else {
                completion(WireFormat.error("contacts.group-delete: not found")); return
            }
            let req = CNSaveRequest()
            req.delete(g)
            try store.execute(req)
            completion(WireFormat.success(["ok": true, "id": id]))
        } catch {
            completion(WireFormat.error("contacts.group-delete: \(error.localizedDescription)"))
        }
    }

    private func groupMember(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void, add: Bool) {
        guard let gid = action["id"] as? String, let cid = action["contact"] as? String else {
            completion(WireFormat.error("contacts.group-add-member/remove-member: --id <group> --contact <id> required")); return
        }
        do {
            let groups = try store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [gid]))
            guard let g = groups.first else { completion(WireFormat.error("group not found")); return }
            let contacts = try store.unifiedContacts(matching: CNContact.predicateForContacts(withIdentifiers: [cid]), keysToFetch: defaultKeys())
            guard let c = contacts.first else { completion(WireFormat.error("contact not found")); return }
            let req = CNSaveRequest()
            if add { req.addMember(c, to: g) } else { req.removeMember(c, from: g) }
            try store.execute(req)
            completion(WireFormat.success(["ok": true, "group": gid, "contact": cid, "added": add]))
        } catch {
            completion(WireFormat.error("contacts.group-member: \(error.localizedDescription)"))
        }
    }

    private func parseKeys(_ s: String?) -> [CNKeyDescriptor] {
        if s == nil { return defaultKeys() }
        return defaultKeys() // The minimal "always-fetch" set; --keys filtering is informational only
    }

    private func listContacts(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let keys = parseKeys(action["keys"] as? String)
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true
        let limit = action["limit"] as? Int
        let offset = (action["offset"] as? Int) ?? 0
        var results: [CNContact] = []
        var visited = 0
        do {
            try store.enumerateContacts(with: request) { c, stop in
                visited += 1
                if visited <= offset { return }
                results.append(c)
                if let limit = limit, results.count >= limit { stop.pointee = true }
            }
            completion(WireFormat.success([
                "limit": limit as Any? ?? NSNull(),
                "offset": offset,
                "contacts": results.map { self.contactDict($0) },
            ]))
        } catch {
            completion(WireFormat.error("contacts.list: \(error.localizedDescription)"))
        }
    }

    private func getContact(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let id = action["id"] as? String else { completion(WireFormat.error("contacts.contact: <id> required")); return }
        do {
            let contacts = try store.unifiedContacts(
                matching: CNContact.predicateForContacts(withIdentifiers: [id]),
                keysToFetch: defaultKeys()
            )
            guard let c = contacts.first else { completion(WireFormat.error("contacts.contact: not found")); return }
            completion(WireFormat.success(contactDict(c)))
        } catch {
            completion(WireFormat.error("contacts.contact: \(error.localizedDescription)"))
        }
    }

    private func meContact(completion: @escaping @Sendable ([String: Any]) -> Void) {
        do {
            let me = try store.unifiedMeContactWithKeys(toFetch: defaultKeys())
            completion(WireFormat.success(contactDict(me)))
        } catch {
            completion(WireFormat.error("contacts.me: \(error.localizedDescription)"))
        }
    }

    private func findContacts(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        do {
            let pred: NSPredicate
            if let phone = action["phone"] as? String {
                pred = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: phone))
            } else if let email = action["email"] as? String {
                pred = CNContact.predicateForContacts(matchingEmailAddress: email)
            } else if let name = action["name"] as? String {
                pred = CNContact.predicateForContacts(matchingName: name)
            } else if let q = action["query"] as? String {
                pred = CNContact.predicateForContacts(matchingName: q)
            } else {
                completion(WireFormat.error("contacts.find: <query>, --name, --email, or --phone required"))
                return
            }
            let contacts = try store.unifiedContacts(matching: pred, keysToFetch: defaultKeys())
            completion(WireFormat.success(["matches": contacts.map { self.contactDict($0) }]))
        } catch {
            completion(WireFormat.error("contacts.find: \(error.localizedDescription)"))
        }
    }

    private func makeMutable(_ action: [String: Any], existing: CNMutableContact? = nil) -> CNMutableContact {
        let m = existing ?? CNMutableContact()
        if let v = action["given"] as? String { m.givenName = v }
        if let v = action["family"] as? String { m.familyName = v }
        if let v = action["organization"] as? String { m.organizationName = v }
        if let raw = action["email"] as? String {
            m.emailAddresses = parseLabeled(raw).map { CNLabeledValue(label: $0.0, value: $0.1 as NSString) }
        }
        if let raw = action["phone"] as? String {
            m.phoneNumbers = parseLabeled(raw).map { CNLabeledValue(label: $0.0, value: CNPhoneNumber(stringValue: $0.1)) }
        }
        if let raw = action["postal"] as? String {
            // home:"1 Apple Park Way;Cupertino;CA;95014;USA"
            let parts = raw.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                let parts2 = String(parts[1]).split(separator: ";").map(String.init)
                let p = CNMutablePostalAddress()
                if parts2.count >= 1 { p.street = parts2[0] }
                if parts2.count >= 2 { p.city = parts2[1] }
                if parts2.count >= 3 { p.state = parts2[2] }
                if parts2.count >= 4 { p.postalCode = parts2[3] }
                if parts2.count >= 5 { p.country = parts2[4] }
                m.postalAddresses = [CNLabeledValue(label: String(parts[0]), value: p)]
            }
        }
        if let raw = action["birthday"] as? String, let d = ISO8601DateFormatter().date(from: raw + "T00:00:00Z") {
            m.birthday = Calendar.current.dateComponents([.year, .month, .day], from: d)
        }
        return m
    }

    private func parseLabeled(_ raw: String) -> [(String, String)] {
        // accept comma-separated label:value pairs
        var out: [(String, String)] = []
        for item in raw.split(separator: ",") {
            let parts = item.split(separator: ":", maxSplits: 1)
            if parts.count == 2 { out.append((String(parts[0]), String(parts[1]))) }
        }
        return out
    }

    private func createContact(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let m = makeMutable(action)
        let req = CNSaveRequest()
        req.add(m, toContainerWithIdentifier: action["container"] as? String)
        do {
            try store.execute(req)
            completion(WireFormat.success(contactDict(m)))
        } catch {
            completion(WireFormat.error("contacts.create: \(error.localizedDescription)"))
        }
    }

    private func updateContact(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let id = action["id"] as? String else { completion(WireFormat.error("contacts.update: <id> required")); return }
        do {
            let contacts = try store.unifiedContacts(
                matching: CNContact.predicateForContacts(withIdentifiers: [id]),
                keysToFetch: defaultKeys()
            )
            guard let m = contacts.first?.mutableCopy() as? CNMutableContact else {
                completion(WireFormat.error("contacts.update: not found")); return
            }
            _ = makeMutable(action, existing: m)
            let req = CNSaveRequest()
            req.update(m)
            try store.execute(req)
            completion(WireFormat.success(contactDict(m)))
        } catch {
            completion(WireFormat.error("contacts.update: \(error.localizedDescription)"))
        }
    }

    private func deleteContact(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let id = action["id"] as? String else { completion(WireFormat.error("contacts.delete: <id> required")); return }
        do {
            let contacts = try store.unifiedContacts(
                matching: CNContact.predicateForContacts(withIdentifiers: [id]),
                keysToFetch: defaultKeys()
            )
            guard let m = contacts.first?.mutableCopy() as? CNMutableContact else {
                completion(WireFormat.error("contacts.delete: not found")); return
            }
            let req = CNSaveRequest()
            req.delete(m)
            try store.execute(req)
            completion(WireFormat.success(["ok": true, "id": id]))
        } catch {
            completion(WireFormat.error("contacts.delete: \(error.localizedDescription)"))
        }
    }

    private func vcard(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let id = action["id"] as? String else { completion(WireFormat.error("contacts.vcard: <id> required")); return }
        do {
            let contacts = try store.unifiedContacts(
                matching: CNContact.predicateForContacts(withIdentifiers: [id]),
                keysToFetch: [CNContactVCardSerialization.descriptorForRequiredKeys()]
            )
            let data = try CNContactVCardSerialization.data(with: contacts)
            completion(WireFormat.success([
                "id": id,
                "vcard": String(data: data, encoding: .utf8) ?? "",
                "bytes": data.count,
            ]))
        } catch {
            completion(WireFormat.error("contacts.vcard: \(error.localizedDescription)"))
        }
    }

    private func importVcard(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let path = action["path"] as? String else { completion(WireFormat.error("contacts.import-vcard: <path> required")); return }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            let data = try Data(contentsOf: url)
            let imported = try CNContactVCardSerialization.contacts(with: data)
            let req = CNSaveRequest()
            // Hold the mutables so we can read their identifiers after save.
            // CNSaveRequest.add() assigns the identifier on save, and the
            // mutable's identifier reflects that assignment in-place.
            var mutables: [CNMutableContact] = []
            for c in imported {
                if let m = c.mutableCopy() as? CNMutableContact {
                    req.add(m, toContainerWithIdentifier: action["container"] as? String)
                    mutables.append(m)
                }
            }
            try store.execute(req)
            completion(WireFormat.success([
                "imported": mutables.count,
                "ids": mutables.map { $0.identifier },
            ]))
        } catch {
            completion(WireFormat.error("contacts.import-vcard: \(error.localizedDescription)"))
        }
    }

    private func currentToken(completion: @escaping @Sendable ([String: Any]) -> Void) {
        if #available(macOS 10.15, *) {
            let token = store.currentHistoryToken
            completion(WireFormat.success([
                "token": token?.base64EncodedString() as Any? ?? NSNull(),
            ]))
        } else {
            completion(WireFormat.error("contacts.current-token: requires macOS 10.15+"))
        }
    }

    private func changes(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        if #available(macOS 10.15, *) {
            let request = CNChangeHistoryFetchRequest()
            if let raw = action["since"] as? String, let data = Data(base64Encoded: raw) {
                request.startingToken = data
            }
            // `enumeratorForChangeHistoryFetchRequest` is unavailable in Swift on macOS;
            // surface the token + a structured note instead of misrepresenting the API.
            let token = store.currentHistoryToken?.base64EncodedString() ?? ""
            completion(WireFormat.success([
                "currentToken": token,
                "events": [Any](),
                "note": "Swift on macOS does not expose enumeratorForChangeHistoryFetchRequest; use NSContactsChangeNotification observers from the daemon for live updates.",
            ]))
        } else {
            completion(WireFormat.error("contacts.changes: requires macOS 10.15+"))
        }
    }

    @available(macOS 10.15, *)
    private func eventDict(_ e: CNChangeHistoryEvent) -> [String: Any] {
        switch e {
        case let e as CNChangeHistoryAddContactEvent:
            return ["type": "addContact", "contactId": e.contact.identifier]
        case let e as CNChangeHistoryUpdateContactEvent:
            return ["type": "updateContact", "contactId": e.contact.identifier]
        case let e as CNChangeHistoryDeleteContactEvent:
            return ["type": "deleteContact", "contactId": e.contactIdentifier]
        case let e as CNChangeHistoryAddGroupEvent:
            return ["type": "addGroup", "groupId": e.group.identifier]
        case let e as CNChangeHistoryUpdateGroupEvent:
            return ["type": "updateGroup", "groupId": e.group.identifier]
        case let e as CNChangeHistoryDeleteGroupEvent:
            return ["type": "deleteGroup", "groupId": e.groupIdentifier]
        case let e as CNChangeHistoryAddMemberToGroupEvent:
            return ["type": "addMemberToGroup", "groupId": e.group.identifier, "contactId": e.member.identifier]
        case let e as CNChangeHistoryRemoveMemberFromGroupEvent:
            return ["type": "removeMemberFromGroup", "groupId": e.group.identifier, "contactId": e.member.identifier]
        case let e as CNChangeHistoryAddSubgroupToGroupEvent:
            return ["type": "addSubgroup", "parent": e.group.identifier, "child": e.subgroup.identifier]
        case let e as CNChangeHistoryRemoveSubgroupFromGroupEvent:
            return ["type": "removeSubgroup", "parent": e.group.identifier, "child": e.subgroup.identifier]
        case _ as CNChangeHistoryDropEverythingEvent:
            return ["type": "dropEverything"]
        default:
            return ["type": String(describing: type(of: e))]
        }
    }
}

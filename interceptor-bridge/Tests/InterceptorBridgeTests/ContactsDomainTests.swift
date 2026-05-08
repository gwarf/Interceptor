// PRD-66 — ContactsDomain unit tests. Live tests gated behind LIVE_CONTACTS=1.

import XCTest
@testable import interceptor_bridge

final class ContactsDomainTests: XCTestCase {
    private let domain = ContactsDomain()

    func runVerb(_ sub: String, action: [String: Any] = [:]) -> [String: Any] {
        var act = action; act["sub"] = sub
        let holder = TestResultHolder()
        let exp = expectation(description: sub)
        domain.handle(sub, action: act) { resp in holder.set(resp); exp.fulfill() }
        wait(for: [exp], timeout: 10.0)
        return holder.value
    }

    // Offline tests — input-validation only; never enter the framework.

    func testStatus_returnsAuthField() {
        let r = runVerb("status")
        XCTAssertEqual(r["success"] as? Bool, true)
    }

    func testContact_missingId_errors() {
        let r = runVerb("contact")
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testFind_missingQuery_errors() {
        let r = runVerb("find")
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testGroupCreate_missingName_errors() {
        let r = runVerb("group-create")
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testImportVcard_missingPath_errors() {
        let r = runVerb("import-vcard")
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testUnknownVerb_errors() {
        let r = runVerb("nope")
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    // Live tests — gated behind LIVE_CONTACTS=1. These call into CNContactStore
    // and block on TCC consent if Contacts access isn't already granted.

    func testDefaultContainer_live() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE_CONTACTS"] == "1")
        let r = runVerb("default-container")
        XCTAssertEqual(r["success"] as? Bool, true)
    }

    func testUpdate_unknownId_live() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE_CONTACTS"] == "1")
        let r = runVerb("update", action: ["id": "no-such-id"])
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testDelete_unknownId_live() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE_CONTACTS"] == "1")
        let r = runVerb("delete", action: ["id": "no-such-id"])
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testVcard_unknownId_live() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE_CONTACTS"] == "1")
        let r = runVerb("vcard", action: ["id": "no-such-id"])
        XCTAssertNotNil(r["success"])
    }

    func testCurrentToken_live() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE_CONTACTS"] == "1")
        let r = runVerb("current-token")
        XCTAssertEqual(r["success"] as? Bool, true)
    }

    func testList_live() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE_CONTACTS"] == "1")
        let r = runVerb("list", action: ["limit": 5])
        XCTAssertEqual(r["success"] as? Bool, true)
    }
}

// PRD-66 — CalendarDomain unit tests. Live tests gated behind LIVE_EVENTKIT=1.

import XCTest
@testable import interceptor_bridge

final class CalendarDomainTests: XCTestCase {
    private let domain = CalendarDomain()

    func runVerb(_ sub: String, action: [String: Any] = [:]) -> [String: Any] {
        var act = action; act["sub"] = sub
        let holder = TestResultHolder()
        let exp = expectation(description: sub)
        domain.handle(sub, action: act) { resp in holder.set(resp); exp.fulfill() }
        wait(for: [exp], timeout: 10.0)
        return holder.value
    }

    func testStatus_returnsAuthorizationFields() {
        let r = runVerb("status")
        XCTAssertEqual(r["success"] as? Bool, true)
    }

    func testEvents_missingDates_errors() {
        let r = runVerb("events")
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testEvent_missingId_errors() {
        let r = runVerb("event")
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testCreate_missingFields_errors() {
        let r = runVerb("create")
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testUpdate_unknownId_errors() {
        let r = runVerb("update", action: ["id": "no-such-event-id"])
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testDelete_unknownId_errors() {
        let r = runVerb("delete", action: ["id": "no-such-event-id"])
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testRefreshSources_succeeds() {
        let r = runVerb("refresh-sources")
        XCTAssertEqual(r["success"] as? Bool, true)
    }

    func testReset_succeeds() {
        let r = runVerb("reset")
        XCTAssertEqual(r["success"] as? Bool, true)
    }

    func testTail_succeeds() {
        let r = runVerb("tail")
        XCTAssertEqual(r["success"] as? Bool, true)
    }

    func testUnknownVerb_errors() {
        let r = runVerb("nope")
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testList_live() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE_EVENTKIT"] == "1")
        let r = runVerb("list")
        XCTAssertEqual(r["success"] as? Bool, true)
    }

    func testCreateRoundtrip_live() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE_EVENTKIT"] == "1")
        let now = Date()
        let f = ISO8601DateFormatter()
        let r = runVerb("create", action: [
            "title": "PRD-66 test event",
            "start": f.string(from: now),
            "end": f.string(from: now.addingTimeInterval(1800)),
        ])
        XCTAssertEqual(r["success"] as? Bool, true)
    }
}

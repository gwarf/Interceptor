// PRD-66 — LocationDomain unit tests. Live tests gated behind LIVE_LOCATION=1.

import XCTest
@testable import interceptor_bridge

final class LocationDomainTests: XCTestCase {
    private let domain = LocationDomain()

    func runVerb(_ sub: String, action: [String: Any] = [:]) -> [String: Any] {
        var act = action; act["sub"] = sub
        let holder = TestResultHolder()
        let exp = expectation(description: sub)
        domain.handle(sub, action: act) { resp in holder.set(resp); exp.fulfill() }
        wait(for: [exp], timeout: 15.0)
        return holder.value
    }

    func testStatus_returnsField() {
        let r = runVerb("status")
        XCTAssertEqual(r["success"] as? Bool, true)
    }

    func testReverse_invalidCoords_errors() {
        let r = runVerb("reverse", action: ["coords": "not-a-coord"])
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testGeocode_missingAddress_errors() {
        let r = runVerb("geocode")
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testDistance_missingFields_errors() {
        let r = runVerb("distance")
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testDistance_validCoords_succeeds() {
        let r = runVerb("distance", action: ["from": "37.0,-122.0", "to": "37.1,-122.1"])
        XCTAssertEqual(r["success"] as? Bool, true)
    }

    func testHeadingStart_returnsMacOSNote() {
        let r = runVerb("heading_start")
        XCTAssertEqual(r["success"] as? Bool, true)
    }

    func testUnknownVerb_errors() {
        let r = runVerb("nope")
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testGeocode_live() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE_LOCATION"] == "1")
        let r = runVerb("geocode", action: ["address": "1 Apple Park Way Cupertino CA"])
        XCTAssertEqual(r["success"] as? Bool, true)
    }
}

// PRD-66 — MapsDomain unit tests. Network-dependent calls (search, directions,
// reverse-geocode) are gated behind LIVE_NETWORK=1 to keep CI offline-clean.

import XCTest
@testable import interceptor_bridge

final class MapsDomainTests: XCTestCase {
    private let domain = MapsDomain()

    func runVerb(_ sub: String, action: [String: Any] = [:]) -> [String: Any] {
        var act = action; act["sub"] = sub
        let holder = TestResultHolder()
        let exp = expectation(description: sub)
        domain.handle(sub, action: act) { resp in holder.set(resp); exp.fulfill() }
        wait(for: [exp], timeout: 10.0)
        return holder.value
    }

    func testSearch_missingQuery_errors() {
        let r = runVerb("search")
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testDirections_missingFrom_errors() {
        let r = runVerb("directions", action: ["to": "Apple Park"])
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testEta_missingTo_errors() {
        let r = runVerb("eta", action: ["from": "Apple Park"])
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testReverse_invalidCoords_errors() {
        let r = runVerb("reverse", action: ["coords": "not-a-coord"])
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testMapItemOpen_unknownId_errors() {
        let r = runVerb("mapitem-open", action: ["id": "B-99999"])
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testUnknownVerb_errors() {
        let r = runVerb("nope")
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    // Live tests — gated behind LIVE_NETWORK=1.
    func testSearch_live_coffee() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE_NETWORK"] == "1")
        let r = runVerb("search", action: ["query": "coffee", "limit": 3])
        XCTAssertEqual(r["success"] as? Bool, true)
    }
}

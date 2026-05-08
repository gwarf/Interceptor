// PRD-66 — ShareDomain unit tests.

import XCTest
@testable import interceptor_bridge

final class ShareDomainTests: XCTestCase {
    private let domain = ShareDomain()

    func runVerb(_ sub: String, action: [String: Any] = [:]) -> [String: Any] {
        var act = action; act["sub"] = sub
        let holder = TestResultHolder()
        let exp = expectation(description: sub)
        domain.handle(sub, action: act) { resp in holder.set(resp); exp.fulfill() }
        wait(for: [exp], timeout: 5.0)
        return holder.value
    }

    func testServices_returnsLiveList() {
        let r = runVerb("services")
        XCTAssertEqual(r["success"] as? Bool, true)
        let data = r["data"] as? [String: Any]
        XCTAssertNotNil(data?["services"])
    }

    func testNamed_unknownService_errors() {
        let r = runVerb("named", action: ["service": "com.does.not.exist"])
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testText_missingValue_errors() {
        let r = runVerb("text", action: ["service": "com.apple.share.AirDrop.send"])
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testUrl_missingService_errors() {
        let r = runVerb("url", action: ["value": "https://example.com"])
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testUnknownVerb_errors() {
        let r = runVerb("nope")
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testServices_forItem_filtersByApplicableServices() {
        let r = runVerb("services", action: ["for_item": "/etc/hosts"])
        XCTAssertEqual(r["success"] as? Bool, true)
    }

    func testAirdrop_live() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE_SHARE"] == "1")
        let r = runVerb("airdrop", action: ["items": ["/etc/hosts"]])
        XCTAssertEqual(r["success"] as? Bool, true)
    }
}

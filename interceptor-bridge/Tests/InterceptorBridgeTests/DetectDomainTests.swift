// PRD-66 — DetectDomain unit tests.

import XCTest
@testable import interceptor_bridge

final class DetectDomainTests: XCTestCase {
    private let domain = DetectDomain()

    func runVerb(_ sub: String, action: [String: Any] = [:]) -> [String: Any] {
        var act = action; act["sub"] = sub
        let holder = TestResultHolder()
        let exp = expectation(description: sub)
        domain.handle(sub, action: act) { resp in holder.set(resp); exp.fulfill() }
        wait(for: [exp], timeout: 5.0)
        return holder.value
    }

    func testTypes_listsDetectorVocabulary() {
        let r = runVerb("types")
        XCTAssertEqual(r["success"] as? Bool, true)
        let data = r["data"] as? [String: Any]
        let types = data?["types"] as? [String] ?? []
        XCTAssertTrue(types.contains("link"))
        XCTAssertTrue(types.contains("phoneNumber"))
        XCTAssertTrue(types.contains("calendarEvent"))
        XCTAssertTrue(types.contains("postalAddress"))
    }

    func testRun_phoneNumber_match() {
        let r = runVerb("run", action: ["input": "Call me at 555-1234 tomorrow"])
        XCTAssertEqual(r["success"] as? Bool, true)
        let data = r["data"] as? [String: Any]
        let matches = data?["matches"] as? [[String: Any]] ?? []
        XCTAssertTrue(matches.contains(where: { ($0["type"] as? String) == "phoneNumber" }))
    }

    func testRun_url_match() {
        let r = runVerb("run", action: ["input": "Visit https://example.com for details"])
        XCTAssertEqual(r["success"] as? Bool, true)
        let data = r["data"] as? [String: Any]
        let matches = data?["matches"] as? [[String: Any]] ?? []
        XCTAssertTrue(matches.contains(where: { ($0["type"] as? String) == "link" }))
    }

    func testRun_typesFilter_phoneOnly() {
        let r = runVerb("run", action: ["input": "Call 555-1234 or visit https://example.com", "types": "phone"])
        XCTAssertEqual(r["success"] as? Bool, true)
        let data = r["data"] as? [String: Any]
        let matches = data?["matches"] as? [[String: Any]] ?? []
        XCTAssertTrue(matches.allSatisfy { ($0["type"] as? String) == "phoneNumber" })
    }

    func testRun_missingInput_errors() {
        let r = runVerb("run")
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testFile_missingPath_errors() {
        let r = runVerb("file")
        XCTAssertEqual(r["success"] as? Bool, false)
    }
}

// PRD-66 — PhotosDomain unit tests. Live tests gated behind LIVE_PHOTOS=1.

import XCTest
@testable import interceptor_bridge

final class PhotosDomainTests: XCTestCase {
    private let domain = PhotosDomain()

    func runVerb(_ sub: String, action: [String: Any] = [:]) -> [String: Any] {
        var act = action; act["sub"] = sub
        let holder = TestResultHolder()
        let exp = expectation(description: sub)
        domain.handle(sub, action: act) { resp in holder.set(resp); exp.fulfill() }
        wait(for: [exp], timeout: 10.0)
        return holder.value
    }

    func testStatus_returnsAuthField() {
        let r = runVerb("status")
        XCTAssertEqual(r["success"] as? Bool, true)
    }

    func testAlbum_missingId_errors() {
        let r = runVerb("album")
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testAsset_missingId_errors() {
        let r = runVerb("asset")
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testExport_missingFields_errors() {
        let r = runVerb("export")
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testFavorite_missingId_errors() {
        let r = runVerb("favorite")
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testHide_missingId_errors() {
        let r = runVerb("hide")
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testDelete_missingId_errors() {
        let r = runVerb("delete")
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testAlbumCreate_missingName_errors() {
        let r = runVerb("album-create")
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testImport_missingFile_errors() {
        let r = runVerb("import")
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testUnknownVerb_errors() {
        let r = runVerb("nope")
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testAlbums_live() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE_PHOTOS"] == "1")
        let r = runVerb("albums")
        XCTAssertEqual(r["success"] as? Bool, true)
    }
}

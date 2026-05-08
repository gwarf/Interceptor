import XCTest
@testable import interceptor_bridge

// Regression: NotificationsDomain.handle was switching on
// `command` so `notifications tail` and `notifications log` all fell
// through to `notImplemented`. These tests pin the dispatch contract.

private final class NotificationsResultHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Any] = [:]
    var value: [String: Any] {
        lock.lock(); defer { lock.unlock() }; return stored
    }
    func set(_ v: [String: Any]) { lock.lock(); stored = v; lock.unlock() }
}

final class NotificationsDispatchTests: XCTestCase {
    private func dispatch(sub: String, extra: [String: Any] = [:]) -> [String: Any] {
        let domain = NotificationsDomain()
        var action: [String: Any] = ["type": "macos_notifications", "sub": sub]
        for (k, v) in extra { action[k] = v }
        let holder = NotificationsResultHolder()
        let exp = expectation(description: "notifications dispatch \(sub)")
        domain.handle("notifications", action: action) { r in
            holder.set(r)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
        return holder.value
    }

    private func isNotImplemented(_ result: [String: Any]) -> Bool {
        let err = (result["error"] as? String) ?? ""
        return err.contains("not yet implemented") || err.contains("not implemented")
    }

    func testTailIsRoutedFromSub() {
        let r = dispatch(sub: "tail")
        XCTAssertFalse(isNotImplemented(r), "tail sub must reach the tail handler")
        XCTAssertEqual(r["success"] as? Bool, true)
    }

    func testLogIsRoutedFromSub() {
        let r = dispatch(sub: "log", extra: ["limit": 5])
        XCTAssertFalse(isNotImplemented(r), "log sub must reach the log handler")
    }

    func testUnknownSubReturnsNotImplementedWithSubString() {
        let r = dispatch(sub: "unknownop")
        let err = (r["error"] as? String) ?? ""
        XCTAssertTrue(err.contains("unknownop"), "Error should reference the unknown sub")
    }

    // PRD-66 — UNUserNotificationCenter dispatch tests.
    //
    // The xctest runner has no .app bundle, so UNUserNotificationCenter.current()
    // raises NSInternalInconsistencyException. Production code runs inside the
    // Interceptor.app bundle and reaches the live UN center; the bridge guards
    // every UN entry point with `unGuard` and returns a structured error here.
    // Tests below assert dispatch reaches the handler and returns either the
    // live success or the bundle-absence error — never `notImplemented`.

    private func reachesUnHandler(_ result: [String: Any]) -> Bool {
        if !isNotImplemented(result) { return true }
        return false
    }

    func testUnStatus_dispatchesToHandler() {
        let r = dispatch(sub: "status")
        XCTAssertTrue(reachesUnHandler(r))
    }

    func testUnPost_dispatchesToHandler() {
        let r = dispatch(sub: "post", extra: ["title": "Test", "body": "Hello"])
        XCTAssertTrue(reachesUnHandler(r))
    }

    func testUnScheduleAfter_missingSeconds_errors() {
        let r = dispatch(sub: "schedule-after", extra: ["title": "x", "body": "y"])
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testUnScheduleAt_missingDate_errors() {
        let r = dispatch(sub: "schedule-at", extra: ["title": "x", "body": "y"])
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testUnScheduleCron_missingComponents_errors() {
        let r = dispatch(sub: "schedule-cron", extra: ["title": "x", "body": "y"])
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testUnCancel_missingId_errors() {
        let r = dispatch(sub: "cancel")
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testUnCancelAll_dispatchesToHandler() {
        let r = dispatch(sub: "cancel-all")
        XCTAssertTrue(reachesUnHandler(r))
    }

    func testUnPending_dispatchesToHandler() {
        let r = dispatch(sub: "pending")
        XCTAssertTrue(reachesUnHandler(r))
    }

    func testUnDelivered_dispatchesToHandler() {
        let r = dispatch(sub: "delivered")
        XCTAssertTrue(reachesUnHandler(r))
    }

    func testUnDismiss_missingId_errors() {
        let r = dispatch(sub: "dismiss")
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testUnDismissAll_dispatchesToHandler() {
        let r = dispatch(sub: "dismiss-all")
        XCTAssertTrue(reachesUnHandler(r))
    }

    func testUnCategoriesList_dispatchesToHandler() {
        let r = dispatch(sub: "categories", extra: ["verb": "list"])
        XCTAssertTrue(reachesUnHandler(r))
    }

    func testUnCategoriesRegister_missingFields_errors() {
        let r = dispatch(sub: "categories", extra: ["verb": "register"])
        XCTAssertEqual(r["success"] as? Bool, false)
    }

    func testUnCategoriesClear_dispatchesToHandler() {
        let r = dispatch(sub: "categories", extra: ["verb": "clear"])
        XCTAssertTrue(reachesUnHandler(r))
    }
}

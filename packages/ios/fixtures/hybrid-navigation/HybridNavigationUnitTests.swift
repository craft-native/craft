import UIKit
import XCTest
@testable import HybridNavigation

@MainActor
final class HybridNavigationUnitTests: XCTestCase {
    private func wait(timeout: TimeInterval = 15, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    func testSlowWebPushRetainsIncomingContentUntilThePageArrives() async throws {
        let hybrid = CraftHybrid.shared
        // Match the cold-start UI fixtures: a hosted simulator's first WebKit
        // network/privacy initialization can take over 45 seconds.
        let ready = await wait(timeout: 120) {
            hybrid.pageReady && hybrid.controller != nil && !CraftChrome.shared.splashVisible
        }
        guard ready else {
            XCTFail("the real fixture page must load before navigation: pageReady=\(hybrid.pageReady), pagePath=\(String(describing: hybrid.pagePath)), splashVisible=\(CraftChrome.shared.splashVisible), URL=\(String(describing: hybrid.webView?.url)), loading=\(String(describing: hybrid.webView?.isLoading))")
            return
        }
        let controller = try XCTUnwrap(hybrid.controller)
        let nav = try XCTUnwrap(controller.children.compactMap { $0 as? UINavigationController }.first)
        let source = try XCTUnwrap(nav.topViewController as? CraftHybridWebSlot)
        let webView = try XCTUnwrap(hybrid.webView)
        let settled = await wait { hybrid.pagePath == "/" && nav.transitionCoordinator == nil }
        guard settled else {
            XCTFail("the initial fixture route must settle before navigation")
            return
        }
        // Hold the real fixture router, so observing the pending native slot
        // does not race its 650ms timer on a busy simulator.
        _ = try await webView.evaluateJavaScript("window.hybridFixture.holdArrival = true")
        defer {
            webView.evaluateJavaScript("window.hybridFixture.release()", completionHandler: nil)
            nav.popToRootViewController(animated: false)
        }

        controller.open("/second")
        let pushed = await wait {
            guard let incoming = nav.topViewController as? CraftHybridWebSlot, incoming !== source else { return false }
            return incoming.waitingPageSnapshot != nil
        }
        XCTAssertTrue(pushed)
        let destination = try XCTUnwrap(nav.topViewController as? CraftHybridWebSlot)
        let snapshot = try XCTUnwrap(destination.waitingPageSnapshot,
                                     "the incoming slot must retain content while its page is pending")
        XCTAssertTrue(destination.awaitingPage)
        XCTAssertTrue(snapshot.superview === destination.view)
        XCTAssertTrue(snapshot.accessibilityElementsHidden)
        XCTAssertFalse(snapshot.isHidden)
        XCTAssertEqual(snapshot.alpha, 1)
        XCTAssertEqual(snapshot.bounds.size, destination.view.bounds.size)

        _ = try await webView.evaluateJavaScript("window.hybridFixture.release(); true")
        let arrived = await wait { hybrid.pagePath == "/second" && !destination.awaitingPage }
        XCTAssertTrue(arrived, "the actual page router must complete")
        XCTAssertNil(destination.waitingPageSnapshot)
        XCTAssertNil(snapshot.superview, "a committed page must release its snapshot")
        XCTAssertEqual(destination.view.subviews.last?.alpha, 1)

        controller.popTop()
        let returned = await wait { hybrid.pagePath == "/" }
        XCTAssertTrue(returned)
    }

    func testCanceledTabSwipeRevealsAWebSlotThatAlreadyReachedItsRoute() {
        let slot = CraftHybridWebSlot(path: "/second", depth: nil, isTabRoot: true)
        slot.awaitingPage = true

        XCTAssertFalse(slot.markArrivedIfNeeded("/"))
        XCTAssertTrue(slot.awaitingPage)
        XCTAssertTrue(slot.markArrivedIfNeeded("/second"))
        XCTAssertFalse(slot.awaitingPage)
        XCTAssertFalse(slot.markArrivedIfNeeded("/second"))
    }
}

import UIKit
import XCTest
import JavaScriptCore
@testable import NativeRender

/// `nativeScriptThread: "background"`: a screen's JavaScript runs on a serial
/// thread of its own (CraftNativeScriptThread) and only UIKit runs on main.
/// These run the fixture screen (render-test.js) that way: it renders, hears
/// taps and typing, runs its timers, and goes away cleanly.
@MainActor
final class ScriptThreadUnitTests: XCTestCase {
    private var window: UIWindow?

    override func setUp() async throws {
        try await super.setUp()
        CraftNativeScriptThread.isBackground = true
    }

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        // Whatever the last test queued finishes before main-thread mode returns.
        CraftNativeScriptThread.queue.sync {}
        CraftNativeScriptThread.isBackground = false
        try await super.tearDown()
    }

    private func find<T: UIView>(_ type: T.Type, key: String, below view: UIView) -> T? {
        if let match = view as? T, match.accessibilityIdentifier == key { return match }
        for child in view.subviews {
            if let match = find(type, key: key, below: child) { return match }
        }
        return nil
    }

    /// Lets the main run loop turn (renders arrive from the script thread as
    /// main-queue work) until `check` holds.
    private func until(_ what: String, timeout: TimeInterval = 10, _ check: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !check() {
            if Date() > deadline {
                XCTFail("Timed out waiting for \(what)")
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func mounted() -> CraftNativeScreenController {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        controller.loadViewIfNeeded()
        return controller
    }

    /// requestAnimationFrame rides the display (CraftNativeFrameClock): a run
    /// of frames in order, a cancelled callback skipped, a throwing one not
    /// stopping the rest, a hidden screen waiting until it is shown, and the
    /// display link stopping once nobody waits.
    func testAnimationFramesReachTheScriptThread() throws {
        let controller = CraftNativeScreenController(config: CraftConfig())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.loadViewIfNeeded()
        func number(_ script: String) -> Double { controller.evaluateScript(script)?.toDouble() ?? .nan }
        func wait(_ what: String, _ check: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !check() {
                if Date() > deadline { XCTFail("Timed out waiting for \(what)"); return }
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
        }

        controller.evaluateScript("""
            globalThis.__frames = [];
            (function tick(time) { __frames.push(time); if (__frames.length < 20) requestAnimationFrame(tick); })(0);
        """)
        wait("twenty frames") { number("__frames.length") == 20 }
        XCTAssertEqual(controller.evaluateScript("__frames.every(function(t, i) { return i === 0 || t > __frames[i - 1]; })")?.toBool(), true)
        wait("the display link to stop") { !CraftNativeFrameClock.shared.isRunning }
        XCTAssertEqual(CraftNativeFrameClock.shared.waitingCount, 0)

        controller.evaluateScript("""
            globalThis.__hits = 0;
            var gone = requestAnimationFrame(function() { __hits += 100; });
            requestAnimationFrame(function() { throw new Error('one callback failing'); });
            requestAnimationFrame(function() { __hits += 1; });
            cancelAnimationFrame(gone);
        """)
        wait("the frame") { number("__hits") == 1 }

        controller.screenVisibilityChanged(false)
        controller.evaluateScript("globalThis.__shown = 0; requestAnimationFrame(function() { __shown = 1; });")
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertEqual(number("__shown"), 0, "a hidden screen's frame waits")
        XCTAssertEqual(CraftNativeFrameClock.shared.waitingCount, 0)
        controller.screenVisibilityChanged(true)
        wait("the frame once shown") { number("__shown") == 1 }
    }

    func testTheScriptRunsOffTheMainThreadAndItsRenderLandsOnMain() throws {
        let controller = mounted()
        // The script was handed to its own thread: the first frame comes from there.
        until("the first render") { find(UILabel.self, key: "count", below: controller.view)?.text == "Count: 0" }
        XCTAssertEqual(controller.evaluateScript("typeof __stxNativeBridge")?.toString(), "object")
        // Work queued for the script runs off the main thread (a sync call from
        // main would run on main, so this asks asynchronously).
        var scriptOnMain: Bool?
        CraftNativeScriptThread.queue.async { let onMain = Thread.isMainThread; DispatchQueue.main.async { scriptOnMain = onMain } }
        until("the script thread to answer") { scriptOnMain != nil }
        XCTAssertEqual(scriptOnMain, false)
    }

    func testInitialFocusIsCapturedBeforeLaterMainThreadVisibilityChanges() throws {
        let started = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        CraftNativeScriptThread.queue.async {
            started.signal()
            resume.wait()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 10), .success)
        let controller = CraftNativeScreenController(config: CraftConfig())
        controller.screenVisibilityChanged(false)
        controller.loadViewIfNeeded()
        // The mount is queued with hidden initial focus. A later appearance
        // must be delivered after mounting rather than changing that snapshot.
        controller.screenVisibilityChanged(true)
        resume.signal()
        until("the captured initial focus") {
            controller.evaluateScript("String(globalThis.__stxNativeFocused)")?.toString() == "false"
        }
    }

    func testATapAndTypingReachTheScriptAndItsUpdatesComeBack() throws {
        let controller = mounted()
        until("the first render") { find(UIButton.self, key: "increment", below: controller.view) != nil }
        let button = try XCTUnwrap(find(UIButton.self, key: "increment", below: controller.view))
        for _ in 0..<3 { button.sendActions(for: .touchUpInside) }
        until("three taps counted") { find(UILabel.self, key: "count", below: controller.view)?.text == "Count: 3" }

        let field = try XCTUnwrap(find(UITextField.self, key: "name-input", below: controller.view))
        for typed in ["A", "Ad", "Ada"] {
            field.text = typed
            field.sendActions(for: .editingChanged)
        }
        until("the name") { find(UILabel.self, key: "name", below: controller.view)?.text == "Hello Ada" }
        // What the person typed stays, whatever order the script answered in.
        XCTAssertEqual(field.text, "Ada")

        let toggle = try XCTUnwrap(find(UISwitch.self, key: "native-switch", below: controller.view))
        toggle.setOn(true, animated: false)
        toggle.sendActions(for: .valueChanged)
        until("the switch") { find(UILabel.self, key: "switch-result", below: controller.view)?.text == "Switch on" }
    }

    func testTimersFireOnTheScriptThread() throws {
        let controller = mounted()
        until("the first render") { find(UILabel.self, key: "count", below: controller.view) != nil }
        controller.evaluateScript("globalThis.__fired = 0; setTimeout(function() { __fired += 1 }, 20); var id = setInterval(function() { __fired += 1; if (__fired >= 3) clearInterval(id) }, 20)")
        until("the timers") { controller.evaluateScript("__fired")?.toInt32() == 3 }
        // An interval cleared from inside itself never fires again.
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(controller.evaluateScript("__fired")?.toInt32(), 3)
    }

    func testSnapshotHostFunctionsDoNotOwnTheirScreen() throws {
        for background in [false, true] {
            CraftNativeScriptThread.isBackground = background
            weak var released: CraftNativeScreenController?
            var write: JSValue?
            var clear: JSValue?
            autoreleasepool {
                let controller = mounted()
                until("the first render") { find(UILabel.self, key: "count", below: controller.view) != nil }
                write = controller.evaluateScript("craftNativeSnapshotSet")
                clear = controller.evaluateScript("craftNativeSnapshotClear")
                XCTAssertEqual(write?.isObject, true)
                XCTAssertEqual(clear?.isObject, true)
                released = controller
                window?.rootViewController = nil
                window?.isHidden = true
                window = nil
            }
            CraftNativeScriptThread.queue.sync {}
            until("the snapshot host blocks to release their screen") { released == nil }
            // Keep the exported functions (and their JSContext) alive across
            // the assertion. Their owner must still be able to disappear.
            withExtendedLifetime([write, clear]) {
                XCTAssertNil(released, "host function ownership must not retain the screen in mode \(background)")
            }
        }
    }

    func testAScreenGoneOnTheMainThreadIsReleasedToo() throws {
        CraftNativeScriptThread.isBackground = false
        weak var released: CraftNativeScreenController?
        // Its own pool: what the test autoreleased on the way must not be what
        // keeps the screen.
        autoreleasepool {
            let controller = mounted()
            until("the first render") { find(UILabel.self, key: "count", below: controller.view) != nil }
            released = controller
            window?.rootViewController = nil
            window?.isHidden = true
            window = nil
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNil(released, "the screen is released once its window lets it go")
    }

    func testAScreenGoneWhileItsScriptStillHasWorkGoesQuietly() throws {
        weak var released: CraftNativeScreenController?
        // Its own pool: what the test autoreleased on the way must not be what
        // keeps the screen.
        autoreleasepool {
            let controller = mounted()
            until("the first render") { find(UILabel.self, key: "count", below: controller.view) != nil }
            // Work still queued for the script, and a timer still pending, as
            // the screen goes.
            controller.evaluateScript("setTimeout(function() { globalThis.__late = true }, 50)")
            if let button = find(UIButton.self, key: "increment", below: controller.view) {
                for _ in 0..<5 { button.sendActions(for: .touchUpInside) }
            }
            released = controller
            window?.rootViewController = nil
            window?.isHidden = true
            window = nil
        }
        // Everything the script thread still held runs out, and nothing it
        // sends back has a screen to touch.
        CraftNativeScriptThread.queue.sync {}
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        CraftNativeScriptThread.queue.sync {}
        XCTAssertNil(released, "the screen is released, not kept alive by its script's queue")
    }
}

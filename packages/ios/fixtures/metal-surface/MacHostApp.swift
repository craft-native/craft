import AppKit

@_silgen_name("craft_metal_fixture_open") func metalOpen(_ view: UnsafeMutableRawPointer, _ output: UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
@_silgen_name("craft_metal_fixture_frame") func metalFrame(_ harness: UnsafeMutableRawPointer, _ frame: UInt32) -> Int32
@_silgen_name("craft_metal_fixture_suspend") func metalSuspend(_ harness: UnsafeMutableRawPointer, _ suspended: Int32) -> Int32
@_silgen_name("craft_metal_fixture_close") func metalClose(_ harness: UnsafeMutableRawPointer) -> Int32
@_silgen_name("craft_metal_fixture_error") func metalError(_ value: Int32) -> UnsafePointer<CChar>

// The native surface alone supplies the pixels. No draw override, image view
// or web renderer can supply the four quadrants inspected by XCTest.
@main
struct MacMetalLauncher {
    static func main() {
        let app = NSApplication.shared
        let owner = MacMetalApp()
        app.delegate = owner
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(owner) {}
    }
}

final class MacMetalApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let canvas = NSView()
    private let status = NSTextField(labelWithString: "Waiting for native Metal")
    private var owner: UnsafeMutableRawPointer?
    private var timer: Timer?
    private var frame: UInt32 = 0
    private var suspended = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 520, height: 400),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Craft native Metal acceptance"
        window.identifier = NSUserInterfaceItemIdentifier("metal-window")
        window.isReleasedWhenClosed = false
        let content = window.contentView!
        canvas.frame = NSRect(x: 40, y: 120, width: 256, height: 192)
        canvas.wantsLayer = true
        canvas.setAccessibilityElement(true)
        canvas.setAccessibilityRole(.image)
        canvas.setAccessibilityIdentifier("metal-canvas")
        canvas.setAccessibilityLabel("Native Metal surface")
        content.addSubview(canvas)
        status.frame = NSRect(x: 40, y: 340, width: 440, height: 24)
        status.setAccessibilityIdentifier("metal-status")
        content.addSubview(status)
        let resize = NSButton(title: "Resize surface", target: self, action: #selector(resizeSurface))
        resize.frame = NSRect(x: 40, y: 50, width: 160, height: 32)
        resize.setAccessibilityIdentifier("metal-resize")
        content.addSubview(resize)
        let close = NSButton(title: "Dispose surface", target: self, action: #selector(closeSurface))
        close.frame = NSRect(x: 220, y: 50, width: 160, height: 32)
        close.setAccessibilityIdentifier("metal-close")
        content.addSubview(close)
        let hide = NSButton(title: "Hide for resume test", target: NSApp, action: #selector(NSApplication.hide(_:)))
        hide.frame = NSRect(x: 40, y: 10, width: 200, height: 32)
        hide.setAccessibilityIdentifier("metal-hide")
        content.addSubview(hide)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard accept(metalOpen(Unmanaged.passUnretained(canvas).toOpaque(), &owner)) else { return }
        draw()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.draw() }
    }

    private func accept(_ code: Int32) -> Bool {
        if code == 0 { return true }
        timer?.invalidate()
        status.stringValue = "Native Metal failed: \(String(cString: metalError(code)))"
        return false
    }

    private func draw() {
        guard !suspended, let owner else { return }
        guard accept(metalFrame(owner, frame)) else { return }
        status.stringValue = "Verified frame \(frame)"
        frame &+= 1
        if frame >= 61 { timer?.invalidate() }
    }

    @objc private func resizeSurface() {
        canvas.setFrameSize(NSSize(width: 160, height: 120))
        draw()
    }

    private func pause(_ value: Bool) {
        guard let owner, accept(metalSuspend(owner, value ? 1 : 0)) else { return }
        suspended = value
        if !value { draw() }
    }

    func applicationDidResignActive(_ notification: Notification) { pause(true) }
    func applicationDidBecomeActive(_ notification: Notification) { pause(false) }

    @objc private func closeSurface() {
        timer?.invalidate()
        guard let owner, accept(metalClose(owner)) else { return }
        self.owner = nil
        let count = canvas.layer?.sublayers?.count ?? 0
        status.stringValue = count == 0 ? "Disposed native surface" : "Native Metal failed: retained layer"
    }

    func applicationWillTerminate(_ notification: Notification) { closeSurface() }
}

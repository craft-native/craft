import UIKit

@_silgen_name("craft_metal_fixture_open") func metalOpen(_ view: UnsafeMutableRawPointer, _ output: UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
@_silgen_name("craft_metal_fixture_frame") func metalFrame(_ harness: UnsafeMutableRawPointer, _ frame: UInt32) -> Int32
@_silgen_name("craft_metal_fixture_dimensions") func metalDimensions(_ harness: UnsafeMutableRawPointer, _ width: UnsafeMutablePointer<UInt32>, _ height: UnsafeMutablePointer<UInt32>, _ scale: UnsafeMutablePointer<Double>) -> Int32
@_silgen_name("craft_metal_fixture_suspend") func metalSuspend(_ harness: UnsafeMutableRawPointer, _ suspended: Int32) -> Int32
@_silgen_name("craft_metal_fixture_close") func metalClose(_ harness: UnsafeMutableRawPointer) -> Int32
@_silgen_name("craft_metal_fixture_error") func metalError(_ value: Int32) -> UnsafePointer<CChar>

@MainActor
func checked(_ value: Int32) throws {
    if value != 0 { throw NSError(domain: String(cString: metalError(value)), code: Int(value)) }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = MetalController()
        self.window = window
        window.makeKeyAndVisible()
    }
    func sceneDidEnterBackground(_ scene: UIScene) { (window?.rootViewController as? MetalController)?.pause(true) }
    func sceneWillEnterForeground(_ scene: UIScene) { (window?.rootViewController as? MetalController)?.pause(false) }
    func sceneDidDisconnect(_ scene: UIScene) { (window?.rootViewController as? MetalController)?.close() }
}

final class MetalController: UIViewController {
    let canvas = UIView()
    let status = UILabel()
    private var handle: UnsafeMutableRawPointer?
    private var timer: Timer?
    private var frame: UInt32 = 0
    private var paused = false
    private var small = false
    // Negative UI control only: prove the acknowledgement query rejects a
    // real penultimate frame, then let the resize action submit frame 60.
    private let holdPenultimate = ProcessInfo.processInfo.arguments.contains("--craft-metal-hold-penultimate")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        canvas.isAccessibilityElement = true
        canvas.accessibilityIdentifier = "metal-canvas"
        canvas.accessibilityLabel = "Native Metal surface"
        view.addSubview(canvas)
        status.accessibilityIdentifier = "metal-status"
        status.text = "Waiting for native Metal"
        status.font = .systemFont(ofSize: 13)
        view.addSubview(status)
        let resize = UIButton(type: .system)
        resize.setTitle("Resize surface", for: .normal)
        resize.accessibilityIdentifier = "metal-resize"
        resize.addTarget(self, action: #selector(resizeSurface), for: .touchUpInside)
        resize.frame = CGRect(x: 20, y: 400, width: 220, height: 44)
        view.addSubview(resize)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width: CGFloat = small ? 160 : 256
        let height: CGFloat = small ? 120 : 192
        canvas.frame = CGRect(x: (view.bounds.width - width) / 2, y: view.safeAreaInsets.top + 80, width: width, height: height)
        status.frame = CGRect(x: 20, y: view.safeAreaInsets.top + 20, width: view.bounds.width - 40, height: 40)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard handle == nil else { return }
        do {
            try checked(metalOpen(Unmanaged.passUnretained(canvas).toOpaque(), &handle))
            draw()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.draw() }
        } catch { status.text = "Native Metal failed: \(error)" }
    }
    private func draw() {
        guard !paused, let handle else { return }
        do {
            try checked(metalFrame(handle, frame))
            status.text = "Verified frame \(frame)"
            frame &+= 1
            // Match the finite macOS fixture: complete all 61 native frames,
            // then leave an idle app whose displayed pixels can be inspected.
            if frame == 61 || (holdPenultimate && frame == 60) { timer?.invalidate() }
        } catch {
            timer?.invalidate()
            status.text = "Native Metal failed: \(error)"
        }
    }
    @objc private func resizeSurface() {
        small.toggle()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        draw()
    }
    func pause(_ value: Bool) {
        guard let handle else { return }
        paused = value
        do { try checked(metalSuspend(handle, value ? 1 : 0)) }
        catch { status.text = "Native Metal failed: \(error)" }
        if !value { draw() }
    }
    func close() {
        timer?.invalidate()
        if let handle {
            do { try checked(metalClose(handle)); self.handle = nil }
            catch { status.text = "Native Metal failed: \(error)" }
        }
    }
}

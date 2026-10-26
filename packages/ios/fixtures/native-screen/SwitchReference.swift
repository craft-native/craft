import SwiftUI
import UIKit

/// Test-only comparison for #416. No Craft renderer, authored styling, event
/// handler, or value echo touches this switch. Drive it with the same physical
/// tap as the native-screen fixture: comparing a tap with a Settings drag
/// compares different UIKit tracking animations.
struct SwitchReference: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .black
        let toggle = UISwitch()
        toggle.accessibilityIdentifier = "reference-switch"
        toggle.frame.origin = CGPoint(x: 16, y: 450)
        controller.view.addSubview(toggle)
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

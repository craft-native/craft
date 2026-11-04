import UIKit

@main
final class DriverTextHost: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = DriverTextController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

// Craft's native TextInput controls are UITextView and UITextField. Observe
// those controls directly so the fixture measures native editing events.
final class DriverTextController: UIViewController, UITextViewDelegate {
    private let transcript = UITextView()
    private let name = UITextField()
    private let transcriptCount = UILabel()
    private let nameCount = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        transcript.text = "Dies ist eine synthetische Testnachricht. Bitte kürze meinen nächsten Lauf."
        transcript.font = .preferredFont(forTextStyle: .body)
        transcript.accessibilityIdentifier = "transcript"
        transcript.autocorrectionType = .no
        transcript.autocapitalizationType = .none
        transcript.delegate = self
        name.text = "Original name"
        name.accessibilityIdentifier = "name"
        name.borderStyle = .roundedRect
        name.autocorrectionType = .no
        name.autocapitalizationType = .none
        name.addTarget(self, action: #selector(nameChanged), for: .editingChanged)
        transcriptCount.accessibilityIdentifier = "transcript-count"
        nameCount.accessibilityIdentifier = "name-count"
        let native = UISwitch()
        let solid = CraftNativeSolidSwitch(frame: .zero)
        let frozenNative = UISwitch()
        let frozenSolid = CraftNativeSolidSwitch(frame: .zero)
        // XCTest on iOS 26 recognizes toggleButton as a Switch. Keep a plain
        // boolean-valued Button to exercise the other accessibility shape too.
        let frozenButton = UIButton(type: .system)
        frozenButton.setTitle("Frozen", for: .normal)
        frozenButton.accessibilityValue = "0"
        frozenButton.isEnabled = false
        let controls: [(UIControl, String)] = [(native, "native-switch"), (solid, "solid-switch"),
                                             (frozenNative, "frozen-native"), (frozenSolid, "frozen-solid"),
                                             (frozenButton, "frozen-button")]
        for (control, id) in controls { control.accessibilityIdentifier = id }
        frozenNative.isEnabled = false
        frozenSolid.isEnabled = false
        let toggles = UIStackView(arrangedSubviews: controls.map { $0.0 })
        toggles.axis = .horizontal
        toggles.distribution = .equalSpacing
        let stack = UIStackView(arrangedSubviews: [toggles, transcript, transcriptCount, name, nameCount])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            transcript.heightAnchor.constraint(equalToConstant: 180),
            name.heightAnchor.constraint(equalToConstant: 44),
        ])
        updateCounts()
    }

    func textViewDidChange(_ textView: UITextView) { updateCounts() }
    @objc private func nameChanged() { updateCounts() }
    private func updateCounts() {
        transcriptCount.text = "Transcript characters: \(transcript.text.count)"
        nameCount.text = "Name characters: \(name.text?.count ?? 0)"
    }
}

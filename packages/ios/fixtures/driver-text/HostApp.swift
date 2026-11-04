import UIKit
import WebKit

@main
final class DriverTextHost: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        if ProcessInfo.processInfo.arguments.contains("browser-focus") {
            window.rootViewController = DriverBrowserFocusController()
        } else if ProcessInfo.processInfo.arguments.contains("invalid-toggle-evidence") {
            window.rootViewController = DriverToggleEvidenceController()
        } else {
            window.rootViewController = DriverTextController()
        }
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

/// Enabled buttons receive the gesture but stop reporting a Boolean value.
/// Their independent action counters distinguish missing evidence from a lost tap.
final class DriverToggleEvidenceController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (id, after) in [("missing-value", nil), ("unknown-value", "unavailable"), ("valid-value", "1")] as [(String, String?)] {
            let button = UIButton(type: .system)
            button.setTitle(id, for: .normal)
            button.accessibilityIdentifier = id
            button.accessibilityValue = "0"
            let counter = UILabel()
            counter.accessibilityIdentifier = "\(id)-count"
            counter.text = "Taps: 0"
            var taps = 0
            button.addAction(UIAction { [weak button, weak counter] _ in
                taps += 1
                button?.accessibilityValue = after
                counter?.text = "Taps: \(taps)"
            }, for: .touchUpInside)
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            stack.addArrangedSubview(button)
            stack.addArrangedSubview(counter)
        }
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
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

// Read the receipt on demand. Recording an edit must not publish accessibility
// changes of its own and accidentally refresh the field snapshot under test.
final class DriverFocusEvidenceLabel: UILabel {
    var readEvidence: (() -> String?)?
    override var accessibilityValue: String? {
        get { readEvidence?() ?? super.accessibilityValue }
        set { super.accessibilityValue = newValue }
    }
}

// A real WebKit form makes text entry cross the same process boundary as a
// system-browser checkout. The native field below also exercises delayed and
// refused focus deterministically, independently of keyboard startup speed.
final class DriverBrowserFocusController: UIViewController, UITextFieldDelegate {
    private let delayed = UITextField()
    private let refused = UITextField()
    private let focusEvidence = DriverFocusEvidenceLabel()
    private var focusEvents: [[String: Any]] = []
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private let discardInput = ProcessInfo.processInfo.arguments.contains("discard-input")
    private var scheduledFocus = false
    private var allowFocus = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        delayed.accessibilityIdentifier = "delayed-field"
        delayed.accessibilityLabel = "Delayed field"
        delayed.borderStyle = .roundedRect
        delayed.delegate = self
        refused.accessibilityIdentifier = "refused-field"
        refused.accessibilityLabel = "Refused field"
        refused.borderStyle = .roundedRect
        refused.delegate = self
        focusEvidence.text = "Focus evidence"
        focusEvidence.accessibilityIdentifier = "focus-evidence"
        focusEvidence.readEvidence = { [weak self] in
            guard let self, let data = try? JSONSerialization.data(withJSONObject: self.focusEvents, options: [.sortedKeys]) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        delayed.addTarget(self, action: #selector(focusTextChanged), for: .editingChanged)
        for name in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardDidShowNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: name, object: nil)
        }
        let web = WKWebView()
        web.accessibilityIdentifier = "browser-form"
        let stack = UIStackView(arrangedSubviews: [delayed, refused, focusEvidence, web])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            delayed.heightAnchor.constraint(equalToConstant: 44),
            refused.heightAnchor.constraint(equalToConstant: 44),
        ])
        web.loadHTMLString("""
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <p>Payment details</p>
            <input id="card" aria-label="Card number" autocomplete="off" style="display:block;width:90%;height:44px;font-size:16px">
            <output id="echo" aria-live="polite"></output>
            <script>document.getElementById('card').addEventListener('input', event => {
                document.getElementById('echo').textContent = 'Entered: ' + event.target.value
            })</script>
            """, baseURL: nil)
    }

    private func recordFocus(_ event: String, replacement: String? = nil, range: NSRange? = nil) {
        var entry: [String: Any] = ["event": event, "at": ProcessInfo.processInfo.systemUptime - startedAt,
                                  "focused": delayed.isFirstResponder, "text": delayed.text ?? ""]
        if let replacement { entry["replacement"] = replacement }
        if let range { entry["range"] = [range.location, range.length] }
        focusEvents.append(entry)
    }

    @objc private func focusTextChanged() { recordFocus("editingChanged") }
    @objc private func keyboardChanged(_ notification: Notification) { recordFocus(notification.name.rawValue) }
    func textFieldDidBeginEditing(_ textField: UITextField) { recordFocus("didBeginEditing") }
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        recordFocus(discardInput ? "rejectedChange" : "shouldChangeCharacters", replacement: string, range: range)
        return !discardInput
    }

    func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
        recordFocus(textField === delayed ? "delayedFocusRequested" : "refusedFocusRequested")
        guard textField === delayed else { return false }
        if allowFocus { return true }
        if !scheduledFocus {
            scheduledFocus = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                self?.allowFocus = true
                self?.delayed.becomeFirstResponder()
            }
        }
        return false
    }
}

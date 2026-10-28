import SwiftUI
import UIKit

#if targetEnvironment(simulator)
@_silgen_name("craft_checkpoint_arm")
private func armCheckpointInterruption()

private let checkpointName = "craft-interrupted-checkpoint"
private let checkpointBoundary = Notification.Name("craftTestCheckpointBoundary")

private func checkpointJSON(_ generation: Int) -> String {
    let value: [String: Any] = ["generation": generation, "payload": String(repeating: "\(generation)", count: 262144)]
    return String(decoding: try! JSONSerialization.data(withJSONObject: value, options: .sortedKeys), as: UTF8.self)
}

@_cdecl("craft_checkpoint_before_replace")
func checkpointBeforeReplace(_ source: UnsafePointer<CChar>, _ target: UnsafePointer<CChar>) {
    let stagedURL = URL(fileURLWithPath: String(cString: source))
    let destination = URL(fileURLWithPath: String(cString: target))
    // Read the real files, not Craft's pending-value cache. Reaching a rename
    // alone is insufficient: require the entire new payload and old checkpoint.
    let staged = try? Data(contentsOf: stagedURL)
    let previous = try? Data(contentsOf: destination)
    let valid = stagedURL != destination
        && staged == Data(checkpointJSON(2).utf8)
        && previous == Data(checkpointJSON(1).utf8)
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: checkpointBoundary, object: nil,
            userInfo: ["status": valid ? "Staged 2; disk still 1; replacement blocked" : "Invalid replacement boundary"])
    }
}

/// Test-only UI around the unchanged shipped CraftSnapshots backend. It lets
/// XCTest terminate a process with a confirmed in-flight Foundation write.
struct CheckpointInterruption: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { CheckpointInterruptionController() }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

private final class CheckpointInterruptionController: UIViewController {
    private let status = UILabel()
    private var observer: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        status.accessibilityIdentifier = "interrupted-checkpoint-status"
        status.numberOfLines = 0
        let session = UILabel()
        session.text = UUID().uuidString
        session.accessibilityIdentifier = "interrupted-checkpoint-session"
        let stack = UIStackView(arrangedSubviews: [status, session,
            button("Seed checkpoint 1", id: "checkpoint-seed") { [weak self] in self?.save(1) },
            button("Interrupt checkpoint 2", id: "checkpoint-interrupt") { [weak self] in
                armCheckpointInterruption()
                self?.save(2)
            },
            button("Save checkpoint 3", id: "checkpoint-retry") { [weak self] in self?.save(3) },
        ])
        stack.axis = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
        ])
        observer = NotificationCenter.default.addObserver(forName: checkpointBoundary, object: nil, queue: .main) { [weak self] note in
            self?.status.text = note.userInfo?["status"] as? String
        }
        read()
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private func button(_ title: String, id: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.accessibilityIdentifier = id
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func read() {
        guard let json = CraftSnapshots.read(checkpointName) else { status.text = "Checkpoint absent"; return }
        // Compare the complete JSON, not merely its generation label.
        if let generation = (1...3).first(where: { json == checkpointJSON($0) }) {
            status.text = "Recovered complete checkpoint \(generation)"
        } else { status.text = "Checkpoint corrupt" }
    }

    private func save(_ generation: Int) {
        status.text = "Saving checkpoint \(generation)"
        CraftSnapshots.write(checkpointName, json: checkpointJSON(generation)) { [weak self] ok in
            guard ok else { self?.status.text = "Checkpoint write failed"; return }
            if generation == 2 { self?.status.text = "Interrupted save completed unexpectedly" }
            else { self?.read() }
        }
    }
}
#endif

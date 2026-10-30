import SwiftUI

/// Independent native input receiver: callbacks only run for real button input.
@main
struct HostApp: App {
    @State private var taps: [String] = []
    private let names = ["One", "Two", "Three", "Four"]

    init() { InputReceipt.install() }

    var body: some Scene {
        WindowGroup {
            VStack {
                Text(taps.isEmpty ? "none" : taps.joined(separator: ","))
                    .lineLimit(1)
                    .accessibilityIdentifier("received-taps")
                ScrollView {
                    VStack {
                        Button("Start of scroll fixture") {}
                            .accessibilityIdentifier("driver-scroll-start")
                        Color.clear.frame(height: 1600).accessibilityHidden(true)
                        Button("End of scroll fixture") {}
                            .accessibilityIdentifier("driver-scroll-end")
                    }
                    .frame(maxWidth: .infinity)
                }
                HStack {
                    ForEach(names, id: \.self) { name in
                        Button(name) {
                            let before = taps
                            taps.append(name)
                            InputReceipt.callback(name, before: before, after: taps)
                        }
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .buttonStyle(.borderedProminent)
                            .accessibilityAddTraits(taps.last == name ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .overlay(alignment: .topLeading) {
                InputReceiptView().frame(width: 1, height: 1)
            }
        }
    }
}

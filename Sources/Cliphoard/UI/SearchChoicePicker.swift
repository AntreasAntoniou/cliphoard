import SwiftUI
import AppKit

/// Native menu choices preserve per-item explanations and predictable keyboard
/// selection, including on macOS versions with different SwiftUI Picker hosts.
struct SearchChoicePicker<Value: Equatable>: NSViewRepresentable {
    struct Choice {
        let value: Value
        let title: String
        let detail: String
    }
    let label: String
    @Binding var selection: Value
    let choices: [Choice]
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12)
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        if button.itemTitles != choices.map(\.title) {
            button.removeAllItems()
            button.addItems(withTitles: choices.map(\.title))
        }
        button.menu?.autoenablesItems = false
        for (index, choice) in choices.enumerated() {
            button.item(at: index)?.toolTip = choice.detail
        }
        if let index = choices.firstIndex(where: { $0.value == selection }) {
            button.selectItem(at: index)
            button.toolTip = choices[index].detail
        }
        button.isEnabled = isEnabled
        button.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        button.setAccessibilityLabel(label)
    }
    final class Coordinator: NSObject {
        var parent: SearchChoicePicker
        init(_ parent: SearchChoicePicker) { self.parent = parent }
        @objc func choose(_ sender: NSPopUpButton) {
            guard sender.isEnabled, parent.choices.indices.contains(sender.indexOfSelectedItem) else { return }
            parent.selection = parent.choices[sender.indexOfSelectedItem].value
        }
    }
}

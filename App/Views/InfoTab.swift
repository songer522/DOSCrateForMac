import AppKit
import LibraryKit
import SwiftUI

struct InfoTab: View {
    @Binding var game: Game

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $game.title)
                TextField("Year", value: $game.year, format: .number.grouping(.never))
                TextField("Developer", text: optional($game.developer))
                TextField("Publisher", text: optional($game.publisher))
                TextField("Genre", text: optional($game.genre))
                LabeledContent("Tags") { TokenField(tokens: $game.tags) }
            }
            Section("Notes") {
                TextEditor(text: $game.notes)
                    .frame(minHeight: 100)
            }
        }
        .formStyle(.grouped)
    }

    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}

/// An `NSTokenField` bound to a list of strings.
struct TokenField: NSViewRepresentable {
    @Binding var tokens: [String]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.delegate = context.coordinator
        field.placeholderString = "Add tags"
        field.objectValue = tokens
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.parent = self
        guard field.currentEditor() == nil, (field.objectValue as? [String]) != tokens else { return }
        field.objectValue = tokens
    }

    @MainActor
    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: TokenField
        init(_ parent: TokenField) { self.parent = parent }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTokenField else { return }
            let values = (field.objectValue as? [String]) ?? []
            parent.tokens = values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }
}

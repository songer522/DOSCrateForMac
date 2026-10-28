import AppKit
import LibraryKit
import SwiftUI

struct InfoTab: View {
    @Binding var game: Game
    var onFindMetadata: (() -> Void)? = nil
    @Environment(\.retroTheme) private var retroTheme

    var body: some View {
        ThemedForm {
            ThemedSection {
                ThemedTextField(title: "Title", text: $game.title)
                ThemedOptionalNumberField(title: "Year", value: $game.year)
                ThemedTextField(title: "Developer", text: optional($game.developer))
                ThemedTextField(title: "Publisher", text: optional($game.publisher))
                ThemedTextField(title: "Genre", text: optional($game.genre))
                ThemedLabeledRow("Tags") {
                    if retroTheme {
                        TokenField(tokens: $game.tags, retro: true)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .frame(minWidth: 120, maxWidth: 200)
                            .background(RetroPalette.bevelLight)
                            .retroBevel(.sunken)
                    } else {
                        TokenField(tokens: $game.tags)
                    }
                }
                if game.metadataSource != nil || onFindMetadata != nil {
                    HStack {
                        if let caption = Self.sourceCaption(for: game.metadataSource) {
                            Text(caption)
                                .font(retroTheme ? RetroFont.font() : .caption)
                                .foregroundStyle(retroTheme ? RetroPalette.secondaryText : .secondary)
                        }
                        Spacer()
                        if let onFindMetadata {
                            if retroTheme {
                                Button("Find Metadata…", action: onFindMetadata)
                                    .buttonStyle(RetroButtonStyle())
                            } else {
                                Button("Find Metadata…", action: onFindMetadata)
                            }
                        }
                    }
                }
            }
            ThemedSection("Description") {
                if retroTheme {
                    TextEditor(text: $game.description)
                        .font(RetroFont.font())
                        .foregroundStyle(RetroPalette.shadow)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .frame(minHeight: 80)
                        .background(RetroPalette.bevelLight)
                        .retroBevel(.sunken)
                } else {
                    TextEditor(text: $game.description)
                        .frame(minHeight: 80)
                }
            }
            ThemedSection("Notes") {
                if retroTheme {
                    TextEditor(text: $game.notes)
                        .font(RetroFont.font())
                        .foregroundStyle(RetroPalette.shadow)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .frame(minHeight: 100)
                        .background(RetroPalette.bevelLight)
                        .retroBevel(.sunken)
                } else {
                    TextEditor(text: $game.notes)
                        .frame(minHeight: 100)
                }
            }
        }
    }

    static func sourceCaption(for source: MetadataSource?) -> String? {
        guard let source else { return nil }
        return "From LaunchBox · \(source.fetchedAt.formatted(date: .abbreviated, time: .omitted))"
    }

    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}

/// An `NSTokenField` bound to a list of strings.
struct TokenField: NSViewRepresentable {
    @Binding var tokens: [String]
    var retro = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.delegate = context.coordinator
        field.placeholderString = "Add tags"
        field.objectValue = tokens
        applyStyle(to: field)
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.parent = self
        applyStyle(to: field)
        guard field.currentEditor() == nil, (field.objectValue as? [String]) != tokens else { return }
        field.objectValue = tokens
    }

    private func applyStyle(to field: NSTokenField) {
        if retro {
            field.isBordered = false
            field.isBezeled = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.font = NSFont(name: RetroFont.postScriptName, size: RetroFont.designSize)
                ?? .monospacedSystemFont(ofSize: RetroFont.designSize, weight: .regular)
        }
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

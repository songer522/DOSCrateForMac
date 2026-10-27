import AppKit
import LibraryKit
import SwiftUI

struct GameGridView: View {
    let model: AppModel
    let records: [GameRecord]
    let menu: (GameRecord) -> GameContextMenu
    /// Where a Shift-click range starts.
    @State private var anchor: UUID?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                ForEach(records) { record in
                    VStack(spacing: 6) {
                        CoverView(record: record, isRunning: model.sessions.running.contains(record.id))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.accentColor, lineWidth: model.selectedIDs.contains(record.id) ? 3 : 0)
                            }
                        Text(record.game.title).lineLimit(2).multilineTextAlignment(.center)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.play(record.id) }
                    .onTapGesture { select(record.id, modifiers: NSEvent.modifierFlags) }
                    .contextMenu {
                        menu(record).onAppear {
                            // Right-clicking outside the selection acts on that game alone.
                            if !model.selectedIDs.contains(record.id) { model.selection = record.id }
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func select(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if model.selectedIDs.contains(id) { model.selectedIDs.remove(id) } else { model.selectedIDs.insert(id) }
            anchor = id
        } else if modifiers.contains(.shift), let anchor, let from = records.firstIndex(where: { $0.id == anchor }),
                  let to = records.firstIndex(where: { $0.id == id }) {
            model.selectedIDs = Set(records[min(from, to)...max(from, to)].map(\.id))
        } else {
            model.selection = id
            anchor = id
        }
    }
}

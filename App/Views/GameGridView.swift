import AppKit
import LibraryKit
import SwiftUI

struct GameGridView: View {
    let model: AppModel
    let records: [GameRecord]
    let menu: (GameRecord) -> GameContextMenu
    /// Where a Shift-click range starts.
    @State private var anchor: UUID?
    /// Keeps the grid in the responder chain so Edit › Select All (⌘A) reaches it.
    @FocusState private var isFocused: Bool

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                ForEach(records) { record in
                    VStack(spacing: 6) {
                        CoverView(
                            record: record,
                            isRunning: model.sessions.running.contains(record.id),
                            isStarting: model.startingIDs.contains(record.id),
                            isImporting: model.imports.importingIDs.contains(record.id),
                            isLoadingArt: model.metadata.artLoading.contains(record.id),
                            artRevision: model.metadata.artRevision[record.id, default: 0]
                        )
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.accentColor, lineWidth: model.selectedIDs.contains(record.id) ? 3 : 0)
                            }
                        Text(record.game.title).lineLimit(2).multilineTextAlignment(.center)
                    }
                    .contentShape(Rectangle())
                    // Earlier gestures win, so the modified clicks come before the plain one.
                    .onTapGesture(count: 2) { model.play(record.id) }
                    .gesture(TapGesture().modifiers(.command).onEnded { toggle(record.id) })
                    .gesture(TapGesture().modifiers(.shift).onEnded { extend(to: record.id) })
                    .onTapGesture { selectOnly(record.id) }
                    .contextMenu {
                        menu(record).onAppear {
                            // Right-clicking outside the selection acts on that game alone.
                            if !model.selectedIDs.contains(record.id) { model.selection = record.id }
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { clearSelection() }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { clearSelection() }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onCommand(#selector(NSResponder.selectAll(_:))) {
            model.selectedIDs = Set(records.map(\.id))
        }
    }

    private func clearSelection() {
        GridSelection.clear(selected: &model.selectedIDs, anchor: &anchor)
        isFocused = true
    }

    private func selectOnly(_ id: UUID) {
        model.selection = id
        anchor = id
        isFocused = true
    }

    private func toggle(_ id: UUID) {
        model.selectedIDs = GridSelection.toggle(id, in: model.selectedIDs)
        anchor = id
        isFocused = true
    }

    private func extend(to id: UUID) {
        isFocused = true
        guard let selected = GridSelection.extend(from: anchor, to: id, in: records.map(\.id)) else {
            return selectOnly(id)
        }
        model.selectedIDs = selected
    }
}

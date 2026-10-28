import AppKit
import LibraryKit
import SwiftUI

struct RetroGameGrid: View {
    let model: AppModel
    let records: [GameRecord]
    let commands: LibraryCommands
    @State private var anchor: UUID?
    @FocusState private var isFocused: Bool

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 16)], spacing: 16) {
                ForEach(records) { record in
                    tile(for: record)
                }
            }
            .padding(16)
        }
        .background(RetroPalette.desktop)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onCommand(#selector(NSResponder.selectAll(_:))) {
            model.selectedIDs = Set(records.map(\.id))
        }
        .onDeleteCommand {
            commands.requestRemoval(model.selectedIDs)
        }
    }

    private func tile(for record: GameRecord) -> some View {
        let selected = model.selectedIDs.contains(record.id)
        let badges = RetroBadge.badges(for: record, running: model.sessions.running, starting: model.startingIDs)
        return VStack(spacing: 6) {
            CoverView(record: record)
                .retroBevel(.sunken)
            Text(record.game.title)
                .font(RetroFont.font())
                .foregroundStyle(RetroPalette.highlightText)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(selected ? RetroPalette.highlight : Color.clear)
                .overlay {
                    if selected {
                        Rectangle()
                            .strokeBorder(RetroPalette.highlightText, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    }
                }
            if !badges.isEmpty {
                RetroBadgesView(badges: badges)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.play(record.id) }
        .gesture(TapGesture().modifiers(.command).onEnded { toggle(record.id) })
        .gesture(TapGesture().modifiers(.shift).onEnded { extend(to: record.id) })
        .onTapGesture { selectOnly(record.id) }
        .contextMenu {
            commands.menu(record).onAppear {
                if !model.selectedIDs.contains(record.id) { model.selection = record.id }
            }
        }
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

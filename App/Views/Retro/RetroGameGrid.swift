import AppKit
import LibraryKit
import SwiftUI

struct RetroGameGrid: View {
    let model: AppModel
    let records: [GameRecord]
    let commands: LibraryCommands
    @State private var anchor: UUID?
    @FocusState private var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 16)], spacing: 16) {
                ForEach(records) { record in
                    tile(for: record)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { clearSelection() }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { clearSelection() }
        .background(RetroPalette.desktop)
        .focusable(isEnabled)
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear {
            if isEnabled { isFocused = true }
        }
        .onChange(of: isEnabled) { _, enabled in
            isFocused = enabled
            if enabled {
                DispatchQueue.main.async {
                    isFocused = true
                }
            }
        }
        .onCommand(#selector(NSResponder.selectAll(_:))) {
            guard isEnabled else { return }
            model.selectedIDs = Set(records.map(\.id))
        }
        .onDeleteCommand {
            guard isEnabled else { return }
            commands.requestRemoval(model.selectedIDs)
        }
    }

    private func clearSelection() {
        guard isEnabled else { return }
        GridSelection.clear(selected: &model.selectedIDs, anchor: &anchor)
        isFocused = true
    }

    private func tile(for record: GameRecord) -> some View {
        let selected = model.selectedIDs.contains(record.id)
        let importing = model.imports.importingIDs.contains(record.id)
        let badges = RetroBadge.badges(
            for: record,
            running: model.sessions.running,
            starting: model.startingIDs,
            importing: model.imports.importingIDs
        )
        return VStack(spacing: 6) {
            CoverView(
                record: record,
                isImporting: importing,
                isLoadingArt: model.metadata.artLoading.contains(record.id),
                artRevision: model.metadata.artRevision[record.id, default: 0]
            )
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
        guard isEnabled else { return }
        model.selection = id
        anchor = id
        isFocused = true
    }

    private func toggle(_ id: UUID) {
        guard isEnabled else { return }
        model.selectedIDs = GridSelection.toggle(id, in: model.selectedIDs)
        anchor = id
        isFocused = true
    }

    private func extend(to id: UUID) {
        guard isEnabled else { return }
        isFocused = true
        guard let selected = GridSelection.extend(from: anchor, to: id, in: records.map(\.id)) else {
            return selectOnly(id)
        }
        model.selectedIDs = selected
    }
}

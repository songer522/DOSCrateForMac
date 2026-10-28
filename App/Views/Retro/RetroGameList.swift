import AppKit
import LibraryKit
import SwiftUI

struct RetroGameList: View {
    let model: AppModel
    let records: [GameRecord]
    let commands: LibraryCommands
    @State private var anchor: UUID?
    @State private var cursor: UUID?
    @FocusState private var isFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                headerRow
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(records) { record in
                            row(for: record)
                                .id(record.id)
                        }
                    }
                }
                .background(RetroPalette.desktop)
            }
            .retroBevel(.sunken)
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                let delta = press.key == .upArrow ? -1 : 1
                guard let next = moveSelection(by: delta, extend: press.modifiers.contains(.shift)) else {
                    return .ignored
                }
                proxy.scrollTo(next)
                return .handled
            }
            .onMoveCommand { direction in
                let delta: Int
                switch direction {
                case .up: delta = -1
                case .down: delta = 1
                default: return
                }
                let extend = NSEvent.modifierFlags.contains(.shift)
                if let next = moveSelection(by: delta, extend: extend) {
                    proxy.scrollTo(next)
                }
            }
            .onCommand(#selector(NSResponder.selectAll(_:))) {
                model.selectedIDs = Set(records.map(\.id))
            }
            .onDeleteCommand {
                commands.requestRemoval(model.selectedIDs)
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            Text("Title")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Year")
                .frame(width: 60, alignment: .leading)
            Text("Developer")
                .frame(width: 160, alignment: .leading)
            Text("Last Played")
                .frame(width: 120, alignment: .leading)
            Text("Play Time")
                .frame(width: 100, alignment: .leading)
        }
        .font(RetroFont.font())
        .foregroundStyle(RetroPalette.shadow)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RetroPalette.panel)
        .retroBevel(.raised)
    }

    private func row(for record: GameRecord) -> some View {
        let selected = model.selectedIDs.contains(record.id)
        let badges = RetroBadge.badges(for: record, running: model.sessions.running, starting: model.startingIDs)
        let textColor = selected ? RetroPalette.highlightText : RetroPalette.cyan
        return HStack(spacing: 12) {
            HStack(spacing: 8) {
                Text(record.game.title)
                    .font(RetroFont.font())
                    .foregroundStyle(selected ? RetroPalette.highlightText : RetroPalette.highlightText)
                    .lineLimit(1)
                if !badges.isEmpty {
                    RetroBadgesView(badges: badges)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(record.game.year.map(String.init) ?? "")
                .font(RetroFont.font())
                .foregroundStyle(textColor)
                .lineLimit(1)
                .frame(width: 60, alignment: .leading)

            Text(record.game.developer ?? "")
                .font(RetroFont.font())
                .foregroundStyle(textColor)
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)

            Group {
                if let date = record.game.stats.lastPlayed {
                    Text(date, format: .dateTime.year().month().day())
                } else {
                    Text("")
                }
            }
            .font(RetroFont.font())
            .foregroundStyle(textColor)
            .lineLimit(1)
            .frame(width: 120, alignment: .leading)

            Group {
                let seconds = record.game.stats.totalPlaySeconds
                if seconds > 0 {
                    Text(Duration.seconds(seconds), format: .units(allowed: [.hours, .minutes], width: .abbreviated))
                } else {
                    Text("")
                }
            }
            .font(RetroFont.font())
            .foregroundStyle(textColor)
            .lineLimit(1)
            .frame(width: 100, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(selected ? RetroPalette.highlight : RetroPalette.desktop)
        .overlay {
            if selected {
                Rectangle()
                    .strokeBorder(RetroPalette.highlightText, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
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
        cursor = id
        isFocused = true
    }

    private func toggle(_ id: UUID) {
        model.selectedIDs = GridSelection.toggle(id, in: model.selectedIDs)
        anchor = id
        cursor = id
        isFocused = true
    }

    private func extend(to id: UUID) {
        isFocused = true
        guard let selected = GridSelection.extend(from: anchor, to: id, in: records.map(\.id)) else {
            return selectOnly(id)
        }
        model.selectedIDs = selected
        cursor = id
    }

    private func moveSelection(by delta: Int, extend: Bool) -> UUID? {
        guard let step = GridSelection.step(
            selected: model.selectedIDs,
            anchor: anchor,
            cursor: cursor,
            by: delta,
            extend: extend,
            in: records.map(\.id)
        ) else {
            return nil
        }
        model.selectedIDs = step.selected
        anchor = step.anchor
        cursor = step.cursor
        return step.cursor
    }
}

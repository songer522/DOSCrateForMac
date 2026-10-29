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
    @Environment(\.isEnabled) private var isEnabled

    static let titleMinWidth: CGFloat = 200
    static let columnWidths: [CGFloat] = [60, 160, 120, 100]
    static let columnSpacing: CGFloat = 12
    static let horizontalPadding: CGFloat = 8

    /// The narrowest the header and rows get before the list scrolls sideways.
    static var minimumContentWidth: CGFloat {
        titleMinWidth + columnWidths.reduce(0, +) + columnSpacing * CGFloat(columnWidths.count) + horizontalPadding * 2
    }

    static func contentWidth(available: CGFloat) -> CGFloat {
        max(available, minimumContentWidth)
    }

    var body: some View {
        GeometryReader { geometry in
            // Header and rows scroll sideways together when the window is too narrow for every column.
            ScrollView(.horizontal) {
                list
                    .frame(width: Self.contentWidth(available: geometry.size.width), height: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
    }

    private var list: some View {
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
            .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                guard isEnabled else { return .ignored }
                let delta = press.key == .upArrow ? -1 : 1
                guard let next = moveSelection(by: delta, extend: press.modifiers.contains(.shift)) else {
                    return .ignored
                }
                proxy.scrollTo(next)
                return .handled
            }
            .onKeyPress(.return) {
                guard isEnabled, let id = GridSelection.activationTarget(model.selectedIDs) else { return .ignored }
                model.play(id)
                return .handled
            }
            .onMoveCommand { direction in
                guard isEnabled else { return }
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
                guard isEnabled else { return }
                model.selectedIDs = Set(records.map(\.id))
            }
            .onDeleteCommand {
                guard isEnabled else { return }
                commands.requestRemoval(model.selectedIDs)
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: Self.columnSpacing) {
            Text("Title")
                .frame(minWidth: Self.titleMinWidth, maxWidth: .infinity, alignment: .leading)
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
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, 4)
        .background(RetroPalette.panel)
        .retroBevel(.raised)
    }

    private func row(for record: GameRecord) -> some View {
        let selected = model.selectedIDs.contains(record.id)
        let badges = RetroBadge.badges(for: record, running: model.sessions.running, starting: model.startingIDs)
        let textColor = selected ? RetroPalette.highlightText : RetroPalette.cyan
        return HStack(spacing: Self.columnSpacing) {
            HStack(spacing: 8) {
                Text(record.game.title)
                    .font(RetroFont.font())
                    .foregroundStyle(selected ? RetroPalette.highlightText : RetroPalette.highlightText)
                    .lineLimit(1)
                if !badges.isEmpty {
                    RetroBadgesView(badges: badges)
                }
                if model.metadata.artLoading.contains(record.id) {
                    RetroSpinner()
                }
            }
            .frame(minWidth: Self.titleMinWidth, maxWidth: .infinity, alignment: .leading)

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
        .padding(.horizontal, Self.horizontalPadding)
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
        guard isEnabled else { return }
        model.selection = id
        anchor = id
        cursor = id
        isFocused = true
    }

    private func toggle(_ id: UUID) {
        guard isEnabled else { return }
        model.selectedIDs = GridSelection.toggle(id, in: model.selectedIDs)
        anchor = id
        cursor = id
        isFocused = true
    }

    private func extend(to id: UUID) {
        guard isEnabled else { return }
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

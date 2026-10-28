import LibraryKit
import SwiftUI

struct RetroLibraryView: View {
    @Bindable var model: AppModel
    let records: [GameRecord]
    let commands: LibraryCommands
    @Binding var showsGrid: Bool
    @Binding var showsInspector: Bool
    @Binding var choosingImport: Bool

    static func playTarget(
        selected: Set<UUID>,
        running: Set<UUID>,
        starting: Set<UUID>,
        pendingRemoval: Set<UUID>
    ) -> UUID? {
        guard selected.count == 1, let id = selected.first else { return nil }
        guard !running.contains(id), !starting.contains(id), !pendingRemoval.contains(id) else {
            return nil
        }
        return id
    }

    private var playID: UUID? {
        Self.playTarget(
            selected: model.selectedIDs,
            running: model.sessions.running,
            starting: model.startingIDs,
            pendingRemoval: model.pendingRemovalIDs
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            buttonBar
            HStack(spacing: 0) {
                RetroSidebar(model: model)
                    .frame(width: 180)
                desktop
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showsInspector {
                    inspectorPanel
                        .frame(minWidth: 300, idealWidth: 360, maxWidth: 520)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            RetroStatusBar(model: model)
        }
        .background(RetroPalette.desktop)
        .navigationTitle("DOSCrate")
        .toolbar(.hidden, for: .windowToolbar)
    }

    private var buttonBar: some View {
        HStack(spacing: 8) {
            Button {
                choosingImport = true
            } label: {
                iconLabel("Import", symbol: "plus", color: RetroPalette.green)
            }
            .buttonStyle(RetroButtonStyle(kind: .icon))

            Button {
                if let id = playID { model.play(id) }
            } label: {
                iconLabel("Play", symbol: "play.fill", color: playID != nil ? RetroPalette.green : RetroPalette.bevelDark)
            }
            .buttonStyle(RetroButtonStyle(kind: .icon))
            .disabled(playID == nil)

            Button {
                showsGrid.toggle()
            } label: {
                iconLabel(showsGrid ? "List" : "Grid",
                          symbol: showsGrid ? "list.bullet" : "square.grid.2x2",
                          color: RetroPalette.desktop)
            }
            .buttonStyle(RetroButtonStyle(kind: .icon))

            Menu {
                sortButton("Title", .title)
                sortButton("Year", .year)
                sortButton("Last Played", .lastPlayed)
                sortButton("Play Time", .playTime)
            } label: {
                iconLabel("Sort", symbol: "arrow.up.arrow.down", color: RetroPalette.desktop)
                    .font(RetroFont.font())
                    .foregroundStyle(RetroPalette.shadow)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RetroPalette.panel)
                    .retroBevel(.raised)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                showsInspector.toggle()
            } label: {
                iconLabel("Details", symbol: "sidebar.trailing", color: RetroPalette.desktop)
            }
            .buttonStyle(RetroButtonStyle(kind: .icon))

            SettingsLink {
                iconLabel("Settings", symbol: "gearshape", color: RetroPalette.shadow)
            }
            .buttonStyle(RetroButtonStyle(kind: .icon))

            Spacer()

            HStack(spacing: 6) {
                PixelSymbol("magnifyingglass", color: RetroPalette.bevelDark, pointSize: 16, scale: 1)
                TextField("Search", text: $model.query.search)
                    .textFieldStyle(RetroTextFieldStyle())
                    .frame(width: 200)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RetroPalette.panel)
        .retroBevel(.raised)
    }

    private func iconLabel(_ title: String, symbol: String, color: Color) -> some View {
        VStack(spacing: 2) {
            PixelSymbol(symbol, color: color, pointSize: 16, scale: 2)
            Text(title)
                .font(RetroFont.font())
        }
    }

    private func sortButton(_ title: String, _ key: SortKey) -> some View {
        Button {
            model.query.sort = key
        } label: {
            if model.query.sort == key { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    @ViewBuilder private var desktop: some View {
        if records.isEmpty {
            let isEmptyStore = model.store.records.isEmpty
            ZStack {
                RetroPalette.desktop
                RetroPanel(title: isEmptyStore ? "No Games Yet" : "No Matches") {
                    VStack(spacing: 8) {
                        PixelSymbol("gamecontroller", color: RetroPalette.desktop, pointSize: 16, scale: 2)
                        Text(isEmptyStore
                             ? "Import a game folder, zip or disc image to get started."
                             : "Try a different search or collection.")
                            .font(RetroFont.font())
                            .foregroundStyle(RetroPalette.shadow)
                            .multilineTextAlignment(.center)
                    }
                    .padding(16)
                }
                .frame(maxWidth: 360)
            }
        } else if showsGrid {
            RetroGameGrid(model: model, records: records, commands: commands)
        } else {
            RetroGameList(model: model, records: records, commands: commands)
        }
    }

    private var inspectorTitle: String {
        if let record = model.selection.flatMap(model.store.record) {
            return record.game.title
        } else if model.selectedIDs.count > 1 {
            return "\(model.selectedIDs.count) Games Selected"
        } else {
            return "No Game Selected"
        }
    }

    private var inspectorPanel: some View {
        RetroPanel(title: inspectorTitle) {
            if let record = model.selection.flatMap(model.store.record) {
                GameDetailView(model: model, record: record)
                    .id(record.id)
                    .retroControls()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.selectedIDs.count > 1 {
                VStack(spacing: 8) {
                    PixelSymbol("square.stack", color: RetroPalette.bevelDark, pointSize: 16, scale: 2)
                    Text("\(model.selectedIDs.count) Games Selected")
                        .font(RetroFont.font())
                        .foregroundStyle(RetroPalette.shadow)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    PixelSymbol("gamecontroller", color: RetroPalette.bevelDark, pointSize: 16, scale: 2)
                    Text("No Game Selected")
                        .font(RetroFont.font())
                        .foregroundStyle(RetroPalette.shadow)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

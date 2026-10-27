import AppKit
import LibraryKit
import SwiftUI

/// Play, Show in Finder, Favorite and Remove… for one game.
struct GameContextMenu: View {
    let model: AppModel
    let record: GameRecord
    let onRemove: () -> Void

    var body: some View {
        if model.sessions.running.contains(record.id) {
            Button("Stop") { model.stop(record.id) }
        } else {
            Button("Play") { model.play(record.id) }
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([record.crateURL]) }
        Button(record.game.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
            var game = record.game
            game.isFavorite.toggle()
            do {
                try model.store.save(game)
            } catch {
                model.alert = AppAlert(title: "Can't save \(game.title)", message: error.localizedDescription)
            }
        }
        Divider()
        Button("Remove…", role: .destructive, action: onRemove)
            .disabled(model.sessions.running.contains(record.id))
    }
}

struct LibraryView: View {
    @Bindable var model: AppModel
    @AppStorage("libraryShowsGrid") private var showsGrid = true
    @State private var removing: UUID?
    @State private var showsInspector = true
    @State private var imports = ImportQueue()
    @State private var choosingImport = false

    private var records: [GameRecord] {
        model.query.apply(to: model.store.records, now: Date())
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 160, ideal: 200)
        } detail: {
            content
                .navigationTitle("DOSCrate")
                .searchable(text: $model.query.search)
                .toolbar { toolbar }
                .inspector(isPresented: $showsInspector) {
                    Group {
                        if let record = model.selection.flatMap(model.store.record) {
                            GameDetailView(model: model, record: record).id(record.id)
                        } else {
                            ContentUnavailableView("No Game Selected", systemImage: "gamecontroller")
                        }
                    }
                    .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
                }
        }
        .confirmationDialog("Remove this game?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing.flatMap(model.store.record)) { record in
            Button("Remove from Library") { remove(record, trashFiles: false) }
            if record.game.source == .managed {
                Button("Move Files to Trash", role: .destructive) { remove(record, trashFiles: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { record in
            Text("\"\(record.game.title)\" will be removed from the library.")
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            imports.add(files)
            return true
        }
        .fileImporter(isPresented: $choosingImport, allowedContentTypes: ImportQueue.contentTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { imports.add(urls) }
        }
        .sheet(item: Binding(get: { imports.current }, set: { if $0 == nil { imports.finishCurrent() } })) { item in
            ImportSheet(model: model, url: item.url) { imports.finishCurrent() }
                .interactiveDismissDisabled()
        }
        .onChange(of: model.pendingFix) { _, pending in
            guard let pending else { return }
            model.pendingFix = nil
            handle(pending)
        }
    }

    @ViewBuilder private var content: some View {
        if records.isEmpty {
            ContentUnavailableView(model.store.records.isEmpty ? "No Games Yet" : "No Matches",
                                   systemImage: "gamecontroller",
                                   description: Text(model.store.records.isEmpty
                                                     ? "Import a game folder, zip or disc image to get started."
                                                     : "Try a different search or collection."))
        } else if showsGrid {
            GameGridView(model: model, records: records, menu: menu)
        } else {
            GameListView(model: model, records: records, menu: menu)
        }
    }

    private func menu(_ record: GameRecord) -> GameContextMenu {
        GameContextMenu(model: model, record: record) { removing = record.id }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem {
            Picker("View", selection: $showsGrid) {
                Label("Grid", systemImage: "square.grid.2x2").tag(true)
                Label("List", systemImage: "list.bullet").tag(false)
            }
            .pickerStyle(.segmented)
        }
        ToolbarItem {
            Menu("Sort", systemImage: "arrow.up.arrow.down") {
                sortButton("Title", .title)
                sortButton("Year", .year)
                sortButton("Last Played", .lastPlayed)
                sortButton("Play Time", .playTime)
            }
        }
        ToolbarItem {
            Button("Details", systemImage: "sidebar.trailing") { showsInspector.toggle() }
        }
        ToolbarItem {
            Button("Import", systemImage: "plus") { choosingImport = true }
        }
    }

    private func sortButton(_ title: String, _ key: SortKey) -> some View {
        Button {
            model.query.sort = key
        } label: {
            if model.query.sort == key { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private func remove(_ record: GameRecord, trashFiles: Bool) {
        do {
            try model.store.remove(record.id, trashFiles: trashFiles)
            if model.selection == record.id { model.selection = nil }
        } catch {
            model.alert = AppAlert(title: "Can't remove \(record.game.title)", message: error.localizedDescription)
        }
    }

    // MARK: Fixes that need a file picker

    private func handle(_ pending: PendingFix) {
        guard let record = model.store.record(pending.gameID) else { return }
        var game = record.game
        let panel = NSOpenPanel()
        switch pending.fix {
        case .chooseExecutable:
            guard let cDrive = try? CrateIO().cDriveURL(for: record) else { return }
            panel.directoryURL = cDrive
            panel.prompt = "Use as Program"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let root = cDrive.standardizedFileURL.path + "/"
            let chosen = url.standardizedFileURL.path
            guard chosen.hasPrefix(root) else {
                model.alert = AppAlert(title: "Choose a file inside the game folder",
                                       message: "The program must be in the folder DOSCrate mounts as C:.",
                                       fix: .chooseExecutable, gameID: game.id)
                return
            }
            game.launch.executable = String(chosen.dropFirst(root.count))
        case .locateFolder:
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = "Use Folder"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                game.source = .referenced(path: url.path, bookmark: try CrateIO.makeBookmark(for: url))
            } catch {
                model.alert = AppAlert(title: "Can't use that folder", message: error.localizedDescription)
                return
            }
        case .useFolderAsC, .reinstall:
            return
        }
        do {
            try model.store.save(game)
        } catch {
            model.alert = AppAlert(title: "Can't save \(game.title)", message: error.localizedDescription)
        }
    }
}

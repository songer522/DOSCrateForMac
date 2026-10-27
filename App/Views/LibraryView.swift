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
        if case .needsRepair = record.status {
            Button("Recreate Game Info…") { model.applyFix(.recreate, for: record.id) }
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
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let progress = model.imports.progress {
                        VStack(spacing: 0) {
                            Divider()
                            HStack(spacing: 10) {
                                ProgressView(value: Double(progress.current), total: Double(max(progress.total, 1)))
                                    .progressViewStyle(.linear)
                                    .frame(maxWidth: 180)
                                Text(progress.label)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.bar)
                        }
                    }
                }
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
            let running = model.sessions.running.contains(record.id)
            if case .referenced = record.game.source {
                Button("Remove from Library") { remove(record, trashFiles: false) }.disabled(running)
                Button("Move Files to Trash", role: .destructive) { remove(record, trashFiles: true) }.disabled(running)
            } else {
                Button("Move to Trash", role: .destructive) { remove(record, trashFiles: true) }.disabled(running)
            }
            Button("Cancel", role: .cancel) {}
        } message: { record in
            Text(Self.removalMessage(for: record, running: model.sessions.running.contains(record.id)))
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            model.imports.add(files, model: model)
            return true
        }
        .fileImporter(isPresented: $choosingImport, allowedContentTypes: ImportQueue.contentTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.imports.add(urls, model: model) }
        }
        .sheet(item: Binding(get: { model.imports.current }, set: { _ in })) { item in
            ImportSheet(model: model, url: item.url, defaultMode: item.defaultMode) { model.imports.finishCurrent() }
                .id(item.id)
                .interactiveDismissDisabled()
        }
        .sheet(item: Binding(get: { model.imports.batchPrompt }, set: { _ in })) { prompt in
            BatchImportSheet(model: model, prompt: prompt)
                .id(prompt.id)
                .interactiveDismissDisabled()
        }
        .sheet(item: $model.chooseProgram) { request in
            ChooseProgramSheet(model: model, request: request)
                .id(request.id)
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

    /// What removal does, worded per source: a managed game's files live in its crate, so they always go with it.
    static func removalMessage(for record: GameRecord, running: Bool) -> String {
        if running { return "Stop \"\(record.game.title)\" before removing it." }
        if case .referenced(let path, _) = record.game.source {
            return "\"\(record.game.title)\" will be removed from the library. Its folder at \(path) stays where it is, "
                + "unless you also move its files to the Trash."
        }
        return "\"\(record.game.title)\" and its game files will be moved to the Trash."
    }

    private func remove(_ record: GameRecord, trashFiles: Bool) {
        guard !model.sessions.running.contains(record.id) else {
            model.alert = AppAlert(title: "Can't remove \(record.game.title)", message: "Stop the game before removing it.")
            return
        }
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
        case .locateFolder, .recreate:
            if pending.fix == .locateFolder {
                guard case .referenced = record.game.source else { return }
            } else {
                guard case .needsRepair = record.status else { return }
            }
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
        case .useFolderAsC, .resetCRoot, .reinstall:
            return
        }
        do {
            try model.store.save(game)
        } catch {
            model.alert = AppAlert(title: "Can't save \(game.title)", message: error.localizedDescription)
        }
    }
}

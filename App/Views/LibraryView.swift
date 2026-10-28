import AppKit
import LauncherKit
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
                .disabled(model.pendingRemovalIDs.contains(record.id) || model.startingIDs.contains(record.id))
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
        // Right-clicking a game in a multiple selection removes the whole selection.
        let count = model.selectedIDs.contains(record.id) ? model.selectedIDs.count : 1
        Button(count > 1 ? "Remove \(count) Games…" : "Remove…", role: .destructive, action: onRemove)
            .disabled(count == 1 && model.sessions.running.contains(record.id))
    }
}

struct LibraryView: View {
    @Bindable var model: AppModel
    @AppStorage("libraryShowsGrid") private var showsGrid = true
    @State private var removing: UUID?
    @State private var removingMany: Set<UUID>?
    @State private var showsInspector = true
    @State private var choosingImport = false

    private var records: [GameRecord] {
        model.query.apply(to: model.store.records, now: Date())
    }

    private var controllerStatus: ControllerStatus? {
        ControllerStatus.make(model.gamepads.devices, enabled: model.prefs.useControllers)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 160, ideal: 200)
        } detail: {
            content
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let progress = model.imports.progress {
                        statusBar {
                            ProgressView(value: Double(progress.current), total: Double(max(progress.total, 1)))
                                .progressViewStyle(.linear)
                                .frame(maxWidth: 180)
                            Text(progress.label)
                        }
                    } else if model.isScanningLibrary {
                        statusBar {
                            ProgressView().controlSize(.small)
                            Text("Looking for games…")
                        }
                    } else if model.imports.isCheckingDuplicates {
                        statusBar {
                            ProgressView().controlSize(.small)
                            Text("Checking for duplicates…")
                        }
                    } else if let removal = model.removalProgress {
                        statusBar(cancellable: false) {
                            ProgressView(value: Double(removal.done), total: Double(max(removal.total, 1)))
                                .progressViewStyle(.linear)
                                .frame(maxWidth: 180)
                            Text("Removing \(removal.done) of \(removal.total)…")
                        }
                    } else if controllerStatus != nil {
                        statusBar(cancellable: false) {}
                    }
                }
                .navigationTitle("DOSCrate")
                .searchable(text: $model.query.search)
                .toolbar { toolbar }
                .inspector(isPresented: $showsInspector) {
                    Group {
                        if let record = model.selection.flatMap(model.store.record) {
                            GameDetailView(model: model, record: record).id(record.id)
                        } else if model.selectedIDs.count > 1 {
                            ContentUnavailableView("\(model.selectedIDs.count) Games Selected", systemImage: "square.stack")
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
        .confirmationDialog(removingMany.map { "Remove \($0.count) games?" } ?? "",
                            isPresented: Binding(get: { removingMany != nil }, set: { if !$0 { removingMany = nil } }),
                            titleVisibility: .visible, presenting: removingMany) { ids in
            let targets = ids.compactMap(model.store.record).filter { !model.sessions.running.contains($0.id) }
            if targets.contains(where: { if case .referenced = $0.game.source { true } else { false } }) {
                Button("Remove from Library") { removeMany(ids, trashFolders: false) }
                Button("Also Move Folders to Trash", role: .destructive) { removeMany(ids, trashFolders: true) }
            } else {
                Button("Move to Trash", role: .destructive) { removeMany(ids, trashFolders: false) }
                    .disabled(targets.isEmpty)
            }
            Button("Cancel", role: .cancel) {}
        } message: { ids in
            Text(Self.removalMessage(for: ids.compactMap(model.store.record), running: model.sessions.running))
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

    private func statusBar(cancellable: Bool = true, @ViewBuilder _ items: () -> some View) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                items()
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if let status = controllerStatus {
                    Label(status.label, systemImage: "gamecontroller")
                        .font(.callout)
                        .foregroundStyle(status.enabled ? .secondary : .tertiary)
                        .monospacedDigit()
                }
                if cancellable {
                    Button("Cancel") { model.cancelImport() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
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
                .onDeleteCommand { requestRemoval(model.selectedIDs) }
        } else {
            GameListView(model: model, records: records, menu: menu, onRemove: requestRemoval)
                .onDeleteCommand { requestRemoval(model.selectedIDs) }
        }
    }

    private func menu(_ record: GameRecord) -> GameContextMenu {
        GameContextMenu(model: model, record: record) {
            requestRemoval(model.selectedIDs.contains(record.id) ? model.selectedIDs : [record.id])
        }
    }

    private func requestRemoval(_ ids: Set<UUID>) {
        guard !model.isRemoving else { return }
        // Never remove games the current search or collection hides, even if they are still selected.
        let ids = ids.intersection(records.map(\.id))
        if ids.count == 1 { removing = ids.first } else if ids.count > 1 { removingMany = ids }
    }

    private func removeMany(_ ids: Set<UUID>, trashFolders: Bool) {
        Task { await model.removeGames(ids, trashFolders: trashFolders) }
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
        ToolbarItem {
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings")
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

    /// What removing several games does: copied games always go to the Trash with their files; kept-in-place
    /// folders stay unless the user also trashes them; running games are skipped.
    static func removalMessage(for records: [GameRecord], running: Set<UUID>) -> String {
        let active = records.filter { !running.contains($0.id) }
        let referenced = active.filter { if case .referenced = $0.game.source { true } else { false } }.count
        let copied = active.count - referenced
        func games(_ n: Int) -> String { n == 1 ? "1 game" : "\(n) games" }
        var parts: [String] = []
        if copied > 0 {
            parts.append("\(games(copied)) copied into the library will be moved to the Trash with "
                + (copied == 1 ? "its files." : "their files."))
        }
        if referenced > 0 {
            parts.append("\(games(referenced)) kept in place will be removed from the library. "
                + (referenced == 1 ? "Its folder stays where it is, unless you also move it to the Trash."
                                   : "Their folders stay where they are, unless you also move them to the Trash."))
        }
        let skipped = records.count - active.count
        if skipped > 0 {
            parts.append("\(games(skipped)) still running will be skipped.")
        }
        return parts.joined(separator: " ")
    }

    private func remove(_ record: GameRecord, trashFiles: Bool) {
        model.removeGame(record.id, trashFiles: trashFiles)
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

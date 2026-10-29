import AppKit
import LibraryKit
import SwiftUI

enum LibraryLayout: Equatable, Sendable {
    case standard
    case retro

    init(theme: AppTheme) {
        switch theme {
        case .standard: self = .standard
        case .dos: self = .retro
        }
    }
}

@MainActor
struct LibraryCommands {
    let model: AppModel
    let records: [GameRecord]
    @Binding var removing: UUID?
    @Binding var removingMany: Set<UUID>?
    var showsInspector: Binding<Bool> = .constant(true)

    func edit(_ id: UUID) {
        model.selection = id
        showsInspector.wrappedValue = true
    }

    func requestRemoval(_ ids: Set<UUID>) {
        guard !model.isRemoving else { return }
        // Never remove games the current search or collection hides, even if they are still selected.
        let ids = ids.intersection(records.map(\.id))
        if ids.count == 1 { removing = ids.first } else if ids.count > 1 { removingMany = ids }
    }

    func menu(_ record: GameRecord) -> GameContextMenu {
        GameContextMenu(
            model: model,
            record: record,
            onEdit: { edit(record.id) },
            onRemove: {
                requestRemoval(model.selectedIDs.contains(record.id) ? model.selectedIDs : [record.id])
            }
        )
    }
}

@MainActor
struct LibraryActions: ViewModifier {
    @Bindable var model: AppModel
    let records: [GameRecord]
    @Binding var removing: UUID?
    @Binding var removingMany: Set<UUID>?
    @Binding var choosingImport: Bool

    func body(content: Content) -> some View {
        content
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
                Text(LibraryView.removalMessage(for: record, running: model.isActive(record.id)))
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
                Text(LibraryView.removalMessage(for: ids.compactMap(model.store.record), running: model.sessions.running.union(model.startingIDs)))
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
            .sheet(isPresented: $model.showingUnmatchedMetadata) {
                UnmatchedMetadataSheet(model: model)
            }
            .sheet(
                isPresented: Binding(
                    get: { !model.showingUnmatchedMetadata && model.findMetadataFor != nil },
                    set: { if !$0 { model.findMetadataFor = nil } }
                )
            ) {
                if let id = model.findMetadataFor {
                    FindMetadataSheet(model: model, gameID: id)
                        .id(id)
                }
            }
            .onChange(of: model.pendingFix) { _, pending in
                guard let pending else { return }
                model.pendingFix = nil
                handle(pending)
            }
    }

    private func remove(_ record: GameRecord, trashFiles: Bool) {
        model.removeGame(record.id, trashFiles: trashFiles)
    }

    private func removeMany(_ ids: Set<UUID>, trashFolders: Bool) {
        Task { await model.removeGames(ids, trashFolders: trashFolders) }
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

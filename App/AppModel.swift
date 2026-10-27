import ConfigKit
import Foundation
import ImportKit
import LauncherKit
import LibraryKit
import Observation

struct AppAlert: Identifiable {
    enum Fix: Equatable {
        case chooseExecutable
        /// Point a referenced game at its moved folder. Never offered for managed games.
        case locateFolder
        /// Mount this subpath of the game folder as C: instead.
        case useFolderAsC(String)
        /// Go back to mounting the whole game folder as C: (its `driveCRoot` subfolder is gone).
        case resetCRoot
        /// Write a fresh game.json for a record that needs repair (any `.broken` file is kept).
        case recreate
        case reinstall
    }

    let id = UUID()
    var title: String
    var message: String
    var fix: Fix?
    /// The game the alert concerns, when there is one.
    var gameID: UUID?
}

/// A fix that needs UI (a file picker) to finish; views observe this and present the picker.
/// Views must set `AppModel.pendingFix` back to nil once they have handled it.
struct PendingFix: Equatable {
    var fix: AppAlert.Fix
    var gameID: UUID
}

/// Request to show the ranked "Choose program" sheet for a game before launching.
struct ChooseProgramRequest: Identifiable, Equatable {
    var id: UUID { gameID }
    var gameID: UUID
    var title: String
    var candidates: [ExecutableCandidate]
}

@MainActor @Observable
final class AppModel {
    var query = LibraryQuery()
    /// Selected games. The inspector and single-game actions use `selection`, set when exactly one is selected.
    var selectedIDs: Set<UUID> = []
    var selection: UUID? {
        get { selectedIDs.count == 1 ? selectedIDs.first : nil }
        set { selectedIDs = newValue.map { [$0] } ?? [] }
    }
    /// (done, total) while `removeGames` is trashing.
    private(set) var removalProgress: (done: Int, total: Int)?
    var isRemoving: Bool { removalProgress != nil }
    /// Games `removeGames` hasn't finished with; they can't be launched until it ends.
    private(set) var pendingRemovalIDs: Set<UUID> = []
    var alert: AppAlert?
    var lastResult: [UUID: SessionResult] = [:]
    var pendingFix: PendingFix?
    var chooseProgram: ChooseProgramRequest?
    private(set) var needsLibrarySetup: Bool
    /// True while the first-run scan looks for games, before the batch import (and its progress) starts.
    private(set) var isScanningLibrary = false
    @ObservationIgnored private var scanCancelled = false

    let prefs: Preferences
    let store: LibraryStore
    let sessions: SessionManager
    let importer: Importer
    let imports = ImportQueue()

    @ObservationIgnored private let dosbox: URL
    @ObservationIgnored private let io = CrateIO()
    @ObservationIgnored private let verifyDosbox: @MainActor (URL) throws -> Void
    /// Debounced editor writes not yet on disk, keyed by game; `play` runs them first.
    @ObservationIgnored private var pendingWrites: [UUID: [String: @MainActor () -> Void]] = [:]

    init(prefs: Preferences, store: LibraryStore, sessions: SessionManager, importer: Importer, dosbox: URL,
         verifyDosbox: @escaping @MainActor (URL) throws -> Void = { try StagingLocator.verify($0) }) {
        self.prefs = prefs
        self.store = store
        self.sessions = sessions
        self.importer = importer
        self.dosbox = dosbox
        self.verifyDosbox = verifyDosbox
        self.needsLibrarySetup = !Self.isDirectory(store.library)
        sessions.onEnded = { [weak self] result in self?.sessionEnded(result) }
        do {
            try verifyDosbox(dosbox)
        } catch {
            alert = Self.alert(for: .dosboxMissing)
        }
    }

    // MARK: Library

    @discardableResult
    func chooseLibrary(_ url: URL, create: Bool) -> Task<Void, Never>? {
        let shouldScan = needsLibrarySetup && !create
        if create {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                alert = AppAlert(title: "Can't create the library folder", message: error.localizedDescription)
                return nil
            }
        }
        prefs.libraryPath = url.path
        store.library = url
        needsLibrarySetup = !Self.isDirectory(url)
        guard !needsLibrarySetup else { return nil }
        // Show the spinner right away; the reload before the scan can take a while too.
        if shouldScan { isScanningLibrary = true }
        return Task {
            await store.reload()
            store.startWatching()
            if shouldScan {
                await importExistingLibraryContents(at: url)
            }
        }
    }

    /// Stops the first-run scan, or the running batch import after its current game.
    func cancelImport() {
        if isScanningLibrary {
            scanCancelled = true
            isScanningLibrary = false
        } else {
            imports.cancelBatchImport()
        }
    }

    private func importExistingLibraryContents(at url: URL) async {
        let records = store.records
        let entries = await Task.detached { Self.scanExistingFolder(url, records: records) }.value
        let cancelled = scanCancelled
        isScanningLibrary = false
        scanCancelled = false
        guard !cancelled, !entries.isEmpty else { return }
        await imports.enqueue(entries, model: self)?.value
    }

    nonisolated private static func scanExistingFolder(_ url: URL, records: [GameRecord]) -> [ImportQueue.BatchEntry] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let visible = children.filter {
            let name = $0.lastPathComponent
            return !name.hasPrefix(".") && !name.hasPrefix("._")
        }.sorted {
            let order = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }

        let cueBases = Set(
            visible.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
                    && $0.pathExtension.lowercased() == "cue"
            }.map { $0.deletingPathExtension().lastPathComponent.lowercased() }
        )

        let allowedFiles: Set<String> = ["zip", "iso", "cue", "img", "ima"]
        let duplicates = DuplicateIndex(records)
        var entries: [ImportQueue.BatchEntry] = []

        for child in visible {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            let ext = child.pathExtension.lowercased()
            if values?.isDirectory == true {
                if ext == CrateIO.crateExtension { continue }
                if duplicates.match(for: child)?.kind == .sameSource { continue }
                let candidates = (try? ExecutableRanker.rank(root: child, title: child.lastPathComponent)) ?? []
                if !candidates.isEmpty {
                    entries.append(.init(url: child, mode: .reference))
                }
            } else if allowedFiles.contains(ext) {
                if ext == "iso", cueBases.contains(child.deletingPathExtension().lastPathComponent.lowercased()) {
                    continue
                }
                if duplicates.match(for: child)?.kind == .sameSource { continue }
                entries.append(.init(url: child, mode: .copy))
            }
        }
        return entries
    }

    /// Moves the games' crates to the Trash, and with `trashFolders` the folders kept-in-place games point at.
    /// Running games are skipped; one alert lists what was skipped or failed.
    func removeGames(_ ids: Set<UUID>, trashFolders: Bool) async {
        let running = ids.filter { sessions.running.contains($0) }
        let targets = Array(ids.subtracting(running))
        pendingRemovalIDs.formUnion(targets)
        defer { pendingRemovalIDs.subtract(targets) }
        removalProgress = (0, targets.count)
        let failures = await store.remove(targets, trashFiles: trashFolders) { [weak self] done, total in
            self?.removalProgress = (done, total)
        }
        removalProgress = nil
        selectedIDs = selectedIDs.filter { store.record($0) != nil }
        let skipped = running.compactMap { store.record($0)?.game.title }.sorted()
            .map { "\($0): stop the game before removing it." }
        let problems = skipped + failures
        if !problems.isEmpty {
            alert = AppAlert(
                title: problems.count == 1 ? "Couldn't remove 1 game" : "Couldn't remove \(problems.count) games",
                message: problems.joined(separator: "\n")
            )
        }
    }

    /// Removes one game; see `LibraryStore.remove(_:trashFiles:)`. A running game shows an alert instead.
    func removeGame(_ id: UUID, trashFiles: Bool) {
        guard let record = store.record(id) else { return }
        guard !sessions.running.contains(id) else {
            alert = AppAlert(title: "Can't remove \(record.game.title)", message: "Stop the game before removing it.")
            return
        }
        do {
            try store.remove(id, trashFiles: trashFiles)
            selectedIDs.remove(id)
        } catch {
            alert = AppAlert(title: "Can't remove \(record.game.title)", message: error.localizedDescription)
        }
    }

    // MARK: Launching

    /// Registers (or with nil clears) a write that must finish before `id` launches. Each owner
    /// ("draft", "override", ...) has its own slot, so independent editors don't replace each other.
    func setPendingWrite(_ id: UUID, owner: String, _ write: (@MainActor () -> Void)?) {
        pendingWrites[id, default: [:]][owner] = write
        if pendingWrites[id]?.isEmpty == true { pendingWrites[id] = nil }
    }

    func play(_ id: UUID) {
        let writes = pendingWrites.removeValue(forKey: id) ?? [:]
        for write in writes.values { write() }
        guard !pendingRemovalIDs.contains(id), let record = store.record(id) else { return }
        do {
            try verifyDosbox(dosbox)
            let cDrive = try Preflight.check(record, io: io, dosbox: dosbox)
            let plan = try LaunchPlanner.plan(record, cDrive: cDrive, global: prefs.globalConfig, dosbox: dosbox, io: io)
            try sessions.start(gameID: id, plan: plan)
        } catch let error as LaunchError {
            if error == .executableNotSet, presentChooseProgram(for: record) { return }
            alert = Self.alert(for: error, gameID: id, game: record.game)
        } catch {
            alert = AppAlert(title: "Can't start \(record.game.title)", message: error.localizedDescription)
        }
    }

    func confirmProgram(_ executable: String) {
        guard let request = chooseProgram else { return }
        chooseProgram = nil
        guard var game = store.record(request.gameID)?.game else { return }
        game.launch.executable = executable
        do {
            try store.save(game)
        } catch {
            alert = AppAlert(title: "Can't save \(game.title)", message: error.localizedDescription)
            return
        }
        play(request.gameID)
    }

    func cancelChooseProgram() {
        chooseProgram = nil
    }

    func chooseAnotherProgram() {
        guard let id = chooseProgram?.gameID else { return }
        chooseProgram = nil
        pendingFix = PendingFix(fix: .chooseExecutable, gameID: id)
    }

    func stop(_ id: UUID) {
        sessions.stop(gameID: id)
    }

    func applyFix(_ fix: AppAlert.Fix, for id: UUID) {
        alert = nil
        switch fix {
        case .chooseExecutable:
            if let record = store.record(id), presentChooseProgram(for: record) { return }
            pendingFix = PendingFix(fix: fix, gameID: id)
        case .locateFolder:
            guard let record = store.record(id), case .referenced = record.game.source else { return }
            pendingFix = PendingFix(fix: fix, gameID: id)
        case .reinstall:
            break
        case .recreate:
            guard let record = store.record(id), case .needsRepair = record.status else { return }
            if Self.isDirectory(record.crateURL.appending(path: "files", directoryHint: .isDirectory)) {
                // The stand-in record is already a managed game titled after the crate.
                var game = record.game
                game.source = .managed
                save(game)
            } else {
                // No files/: it was a referenced game, so ask where its folder is.
                pendingFix = PendingFix(fix: .recreate, gameID: id)
            }
        case .resetCRoot:
            guard var game = store.record(id)?.game, !game.launch.driveCRoot.isEmpty else { return }
            // Keep the program pointing at the same file, now relative to the whole game folder.
            if let exe = game.launch.executable, !exe.isEmpty {
                game.launch.executable = game.launch.driveCRoot + "/" + exe
            }
            game.launch.driveCRoot = ""
            save(game)
        case .useFolderAsC(let root):
            guard var game = store.record(id)?.game,
                  Self.isFolderPrefix(root, of: game.launch.executable) else { return }
            let current = game.launch.driveCRoot
            game.launch.driveCRoot = current.isEmpty ? root : current + "/" + root
            if let exe = game.launch.executable {
                game.launch.executable = String(exe.dropFirst(root.count + 1))
            }
            save(game)
        }
    }

    private func presentChooseProgram(for record: GameRecord) -> Bool {
        guard let cDrive = try? io.cDriveURL(for: record),
              let candidates = try? ExecutableRanker.rank(root: cDrive, title: record.game.title),
              !candidates.isEmpty else { return false }
        chooseProgram = ChooseProgramRequest(gameID: record.id, title: record.game.title, candidates: candidates)
        return true
    }

    private func save(_ game: Game) {
        do {
            try store.save(game)
        } catch {
            alert = AppAlert(title: "Can't save \(game.title)", message: error.localizedDescription)
        }
    }

    private func sessionEnded(_ result: SessionResult) {
        if result.unexpected { lastResult[result.gameID] = result } else { lastResult[result.gameID] = nil }
        guard var game = store.record(result.gameID)?.game else { return }
        game.stats.launchCount += 1
        game.stats.totalPlaySeconds += result.duration
        game.stats.lastPlayed = Date()
        do {
            try store.save(game)
        } catch {
            alert = AppAlert(title: "Can't save play time for \(game.title)", message: error.localizedDescription)
        }
    }

    // MARK: Helpers

    /// True when `root` is a folder containing `executable` (never the executable itself).
    private static func isFolderPrefix(_ root: String, of executable: String?) -> Bool {
        guard let executable else { return false }
        return executable.hasPrefix(root + "/")
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func alert(for error: LaunchError, gameID: UUID? = nil, game: Game? = nil) -> AppAlert {
        var alert = makeAlert(for: error, game: game)
        alert.gameID = gameID
        return alert
    }

    private static func makeAlert(for error: LaunchError, game: Game?) -> AppAlert {
        let executable = game?.launch.executable
        switch error {
        case .dosboxMissing:
            return AppAlert(title: "DOSBox Staging is missing or damaged",
                     message: "The bundled DOSBox Staging can't be used. Reinstall DOSCrate to restore it.")
        case .executableNotSet:
            return AppAlert(title: "No program to run", message: "Choose which file starts this game.", fix: .chooseExecutable)
        case .executableMissing(let path):
            return AppAlert(title: "Program not found", message: "\(path) is no longer in the game folder.", fix: .chooseExecutable)
        case .sourceUnreachable(let path):
            var isReferenced = false
            if case .referenced = game?.source { isReferenced = true }
            return AppAlert(title: "Game folder unavailable", message: "DOSCrate can't reach \(path).",
                            fix: isReferenced ? .locateFolder : nil)
        case .cRootMissing(let path):
            if let root = game?.launch.driveCRoot, !root.isEmpty {
                return AppAlert(title: "C: folder not found",
                                message: "\"\(root)\", the folder used as C:, is no longer in the game folder (\(path)).",
                                fix: .resetCRoot)
            }
            return AppAlert(title: "Game files not found", message: "DOSCrate can't find this game's files at \(path).")
        case .mediaMissing(let path):
            return AppAlert(title: "Disc image missing",
                            message: "\((path as NSString).lastPathComponent) is no longer in the game's media folder.")
        case .launchFailed(let detail):
            return AppAlert(title: "DOSBox didn't start", message: detail)
        case .nonDOSPath(let component, let root):
            guard Self.isFolderPrefix(root, of: executable) else {
                return AppAlert(title: "Name not usable in DOS",
                                message: "\"\(component)\" isn't a valid DOS name. Rename the file to an 8.3 name, or choose another program.",
                                fix: .chooseExecutable)
            }
            return AppAlert(title: "Name not usable in DOS",
                     message: "\"\(component)\" isn't a valid DOS name. Use \"\(root)\" as the C: drive instead.",
                     fix: .useFolderAsC(root))
        case .unsupportedPath(let path):
            return AppAlert(title: "Unsupported path", message: "\(path) contains characters DOSBox can't mount.")
        case .needsRepair:
            return AppAlert(title: "Game needs repair",
                            message: "This game's game.json is missing or unreadable. Recreate it to play the game again; "
                                + "its title, settings and play stats start fresh.",
                            fix: .recreate)
        case .readOnly(let reason):
            return AppAlert(title: "Game is read-only", message: reason)
        case .alreadyRunning:
            return AppAlert(title: "Already running", message: "This game is already running.")
        }
    }
}

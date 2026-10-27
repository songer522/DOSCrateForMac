import ConfigKit
import Foundation
import ImportKit
import LauncherKit
import LibraryKit
import Observation

struct AppAlert: Identifiable {
    enum Fix: Equatable {
        case chooseExecutable
        case locateFolder
        /// Mount this subpath of the game folder as C: instead.
        case useFolderAsC(String)
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

@MainActor @Observable
final class AppModel {
    var query = LibraryQuery()
    var selection: UUID?
    var alert: AppAlert?
    var lastResult: [UUID: SessionResult] = [:]
    var pendingFix: PendingFix?
    private(set) var needsLibrarySetup: Bool

    let prefs: Preferences
    let store: LibraryStore
    let sessions: SessionManager
    let importer: Importer

    @ObservationIgnored private let dosbox: URL
    @ObservationIgnored private let io = CrateIO()
    @ObservationIgnored private let verifyDosbox: @MainActor (URL) throws -> Void

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

    func chooseLibrary(_ url: URL, create: Bool) {
        if create {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                alert = AppAlert(title: "Can't create the library folder", message: error.localizedDescription)
                return
            }
        }
        prefs.libraryPath = url.path
        store.library = url
        needsLibrarySetup = !Self.isDirectory(url)
        guard !needsLibrarySetup else { return }
        Task {
            await store.reload()
            store.startWatching()
        }
    }

    // MARK: Launching

    func play(_ id: UUID) {
        guard let record = store.record(id) else { return }
        do {
            try verifyDosbox(dosbox)
            let cDrive = try Preflight.check(record, io: io, dosbox: dosbox)
            let plan = try LaunchPlanner.plan(record, cDrive: cDrive, global: prefs.globalConfig, dosbox: dosbox, io: io)
            try sessions.start(gameID: id, plan: plan)
        } catch let error as LaunchError {
            alert = Self.alert(for: error, gameID: id, executable: record.game.launch.executable)
        } catch {
            alert = AppAlert(title: "Can't start \(record.game.title)", message: error.localizedDescription)
        }
    }

    func stop(_ id: UUID) {
        sessions.stop(gameID: id)
    }

    func applyFix(_ fix: AppAlert.Fix, for id: UUID) {
        alert = nil
        switch fix {
        case .chooseExecutable, .locateFolder:
            pendingFix = PendingFix(fix: fix, gameID: id)
        case .reinstall:
            break
        case .useFolderAsC(let root):
            guard var game = store.record(id)?.game,
                  Self.isFolderPrefix(root, of: game.launch.executable) else { return }
            let current = game.launch.driveCRoot
            game.launch.driveCRoot = current.isEmpty ? root : current + "/" + root
            if let exe = game.launch.executable {
                game.launch.executable = String(exe.dropFirst(root.count + 1))
            }
            do {
                try store.save(game)
            } catch {
                alert = AppAlert(title: "Can't save \(game.title)", message: error.localizedDescription)
            }
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

    static func alert(for error: LaunchError, gameID: UUID? = nil, executable: String? = nil) -> AppAlert {
        var alert = makeAlert(for: error, executable: executable)
        alert.gameID = gameID
        return alert
    }

    private static func makeAlert(for error: LaunchError, executable: String?) -> AppAlert {
        switch error {
        case .dosboxMissing:
            return AppAlert(title: "DOSBox Staging is missing or damaged",
                     message: "The bundled DOSBox Staging can't be used. Reinstall DOSCrate to restore it.")
        case .executableNotSet:
            return AppAlert(title: "No program to run", message: "Choose which file starts this game.", fix: .chooseExecutable)
        case .executableMissing(let path):
            return AppAlert(title: "Program not found", message: "\(path) is no longer in the game folder.", fix: .chooseExecutable)
        case .sourceUnreachable(let path):
            return AppAlert(title: "Game folder unavailable", message: "DOSCrate can't reach \(path).", fix: .locateFolder)
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
            return AppAlert(title: "Game needs repair", message: "This game's data file is unreadable.")
        case .alreadyRunning:
            return AppAlert(title: "Already running", message: "This game is already running.")
        }
    }
}

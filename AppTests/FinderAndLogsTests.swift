import Foundation
import LibraryKit
import Testing
@testable import DOSCrate

@MainActor
struct FinderAndLogsTests {
    @Test func cDriveFolderURLResolvesManagedGameAndRejectsMissingOrTraversal() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cdrive-managed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let io = CrateIO()
        let crate = try io.makeCrate(title: "Keen", in: root)
        let filesDir = crate.appending(path: "files", directoryHint: .isDirectory)

        var record = GameRecord(game: Game(title: "Keen", source: .managed), crateURL: crate)
        // Missing `files` directory on disk returns nil.
        #expect(GameContextMenu.cDriveFolderURL(for: record, io: io) == nil)

        try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        #expect(GameContextMenu.cDriveFolderURL(for: record, io: io) == filesDir)

        // Valid driveCRoot that does not yet exist on disk returns nil; once created, returns the subfolder.
        record.game.launch.driveCRoot = "KEEN4"
        let subDir = filesDir.appending(path: "KEEN4", directoryHint: .isDirectory)
        #expect(GameContextMenu.cDriveFolderURL(for: record, io: io) == nil)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        #expect(GameContextMenu.cDriveFolderURL(for: record, io: io) == subDir)

        // Path traversal or absolute driveCRoot is rejected even if the target directory exists.
        record.game.launch.driveCRoot = ".."
        #expect(GameContextMenu.cDriveFolderURL(for: record, io: io) == nil)
        record.game.launch.driveCRoot = "../" + crate.lastPathComponent
        #expect(GameContextMenu.cDriveFolderURL(for: record, io: io) == nil)
        record.game.launch.driveCRoot = "/tmp"
        #expect(GameContextMenu.cDriveFolderURL(for: record, io: io) == nil)
    }

    @Test func cDriveFolderURLResolvesReferencedGameAndHandlesMissingSource() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cdrive-ref-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let io = CrateIO()
        let crate = try io.makeCrate(title: "Doom", in: root)
        let externalDir = root.appending(path: "ExternalDoom", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)

        let bookmark = try CrateIO.makeBookmark(for: externalDir)
        var record = GameRecord(
            game: Game(title: "Doom", source: .referenced(path: externalDir.path, bookmark: bookmark)),
            crateURL: crate
        )
        #expect(GameContextMenu.cDriveFolderURL(for: record, io: io)?.standardizedFileURL == externalDir.standardizedFileURL)

        // Subfolder inside referenced game
        record.game.launch.driveCRoot = "DOOM2"
        let subDir = externalDir.appending(path: "DOOM2", directoryHint: .isDirectory)
        #expect(GameContextMenu.cDriveFolderURL(for: record, io: io) == nil)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        #expect(GameContextMenu.cDriveFolderURL(for: record, io: io)?.standardizedFileURL == subDir.standardizedFileURL)

        // Removing the referenced folder makes cDriveFolderURL return nil.
        record.game.launch.driveCRoot = ""
        try FileManager.default.removeItem(at: externalDir)
        #expect(GameContextMenu.cDriveFolderURL(for: record, io: io) == nil)
    }

    @Test func latestLogURLReturnsNilWhenAbsentAndLogFileWhenPresent() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "logs-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let io = CrateIO()
        let crate = try io.makeCrate(title: "Quake", in: root)

        #expect(AdvancedTab.latestLogURL(for: crate, io: io) == nil)

        let logsDir = io.logsURL(crate)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        #expect(AdvancedTab.latestLogURL(for: crate, io: io) == nil)

        // Timestamped session logs return the newest one when dosbox.log is not present.
        let olderLog = logsDir.appending(path: "20260101-100000.log", directoryHint: .notDirectory)
        let newerLog = logsDir.appending(path: "20260102-100000.log", directoryHint: .notDirectory)
        try Data("older".utf8).write(to: olderLog)
        try Data("newer".utf8).write(to: newerLog)
        #expect(AdvancedTab.latestLogURL(for: crate, io: io) == newerLog)

        // Explicit dosbox.log in logsURL is returned when present.
        let dosboxLog = logsDir.appending(path: "dosbox.log", directoryHint: .notDirectory)
        try Data("dosbox log output".utf8).write(to: dosboxLog)
        #expect(AdvancedTab.latestLogURL(for: crate, io: io) == dosboxLog)
    }
}

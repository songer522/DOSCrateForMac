import Foundation
import ImportKit
import LauncherKit
import LibraryKit
import os
import Testing
@testable import DOSCrate

@MainActor
@Suite struct AppCommandsTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "appcommands-\(UUID().uuidString)")
    let io = CrateIO()
    let runner = FakeRunner()

    func makeModel(
        executable: String? = "GAME.EXE",
        setupExecutable: String? = nil,
        files: [String] = ["GAME.EXE"],
        libraryExists: Bool = true,
        verify: @escaping @Sendable (URL) throws -> Void = { _ in }
    ) async throws -> (AppModel, UUID) {
        let fm = FileManager.default
        let lib = root.appending(path: "Library")
        if libraryExists { try fm.createDirectory(at: lib, withIntermediateDirectories: true) }
        var id = UUID()
        if libraryExists {
            let crate = try io.makeCrate(title: "Test Game", in: lib)
            var game = Game(title: "Test Game", source: .managed)
            game.launch.executable = executable
            game.launch.setupExecutable = setupExecutable
            id = game.id
            try io.save(game, extra: [:], to: crate)
            for f in files {
                let url = crate.appending(path: "files/" + f)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("x".utf8).write(to: url)
            }
        }
        let dosbox = root.appending(path: "dosbox")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: dosbox)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dosbox.path)
        let suite = "doscrate-cmd-test-\(UUID().uuidString)"
        let prefs = Preferences(defaults: UserDefaults(suiteName: suite)!)
        let store = LibraryStore(library: lib)
        await store.reload()
        let model = AppModel(
            prefs: prefs,
            store: store,
            sessions: SessionManager(runner: runner),
            importer: Importer(),
            dosbox: dosbox,
            verifyDosbox: verify
        )
        await model.startupVerify?.value
        return (model, id)
    }

    @Test func importCommandEnablementAndTrigger() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _) = try await makeModel(libraryExists: false)
        #expect(model.needsLibrarySetup)
        #expect(!AppCommands.canImport(model))
        AppCommands.triggerImport(model)
        #expect(!model.isChoosingImport)

        await model.chooseLibrary(root.appending(path: "Library"), create: true)?.value
        #expect(!model.needsLibrarySetup)
        #expect(AppCommands.canImport(model))
        AppCommands.triggerImport(model)
        #expect(model.isChoosingImport)
    }

    @Test func viewAndSortCommandsState() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _) = try await makeModel()
        #expect(AppCommands.detailsButtonTitle(showsInspector: true) == "Hide Details")
        #expect(AppCommands.detailsButtonTitle(showsInspector: false) == "Show Details")

        #expect(model.query.sort == .title)
        model.query.sort = .year
        #expect(model.query.sort == .year)
        model.query.sort = .lastPlayed
        #expect(model.query.sort == .lastPlayed)
        model.query.sort = .playTime
        #expect(model.query.sort == .playTime)
    }

    @Test func playSetupAndStopEnablementAcrossSelectionAndLifecycle() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let release = DispatchSemaphore(value: 0)
        let state = OSAllocatedUnfairLock(initialState: (armed: false, entered: false))
        let (model, id) = try await makeModel(
            executable: "GAME.EXE",
            setupExecutable: "SETUP.EXE",
            files: ["GAME.EXE", "SETUP.EXE"]
        ) { _ in
            let shouldBlock = state.withLock { s -> Bool in
                guard s.armed else { return false }
                s.entered = true
                return true
            }
            if shouldBlock { release.wait() }
        }

        let secondCrate = try io.makeCrate(title: "Second Game", in: model.store.library)
        let secondGame = Game(title: "Second Game", source: .managed)
        try io.save(secondGame, extra: [:], to: secondCrate)
        await model.store.reload()

        // No selection
        #expect(!AppCommands.canPlay(model))
        #expect(!AppCommands.canRunSetup(model))
        #expect(!AppCommands.canStop(model))

        // Multi-selection
        model.selectedIDs = [id, secondGame.id]
        #expect(!AppCommands.canPlay(model))
        #expect(!AppCommands.canRunSetup(model))
        #expect(!AppCommands.canStop(model))

        // Single selection without setupExecutable
        model.selection = secondGame.id
        #expect(AppCommands.canPlay(model))
        #expect(!AppCommands.canRunSetup(model))
        #expect(!AppCommands.canStop(model))

        // Single selection with setupExecutable while idle
        model.selection = id
        #expect(AppCommands.canPlay(model))
        #expect(AppCommands.canRunSetup(model))
        #expect(!AppCommands.canStop(model))

        // While starting
        state.withLock { $0.armed = true }
        let playTask = model.play(id)
        await waitUntil { state.withLock { $0.entered } }
        #expect(model.startingIDs.contains(id))
        #expect(!AppCommands.canPlay(model))
        #expect(!AppCommands.canRunSetup(model))
        #expect(!AppCommands.canStop(model))

        // While running
        state.withLock { $0.armed = false }
        release.signal()
        await playTask?.value
        #expect(model.sessions.running.contains(id))
        #expect(!AppCommands.canPlay(model))
        #expect(!AppCommands.canRunSetup(model))
        #expect(AppCommands.canStop(model))

        // Stop returns to idle
        model.stop(id)
        await waitUntil { !model.sessions.running.contains(id) }
        #expect(AppCommands.canPlay(model))
        #expect(AppCommands.canRunSetup(model))
        #expect(!AppCommands.canStop(model))
    }

    @Test func favoriteAndFindMetadataEnablementAndActions() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel()

        // No selection
        #expect(!AppCommands.canEdit(model))
        #expect(AppCommands.favoriteButtonTitle(for: model) == "Add to Favorites")
        AppCommands.toggleFavorite(model)
        AppCommands.findMetadata(model)
        #expect(model.findMetadataFor == nil)

        // Single writable selection
        model.selection = id
        #expect(AppCommands.canEdit(model))
        #expect(AppCommands.favoriteButtonTitle(for: model) == "Add to Favorites")

        AppCommands.toggleFavorite(model)
        #expect(model.store.record(id)?.game.isFavorite == true)
        #expect(AppCommands.favoriteButtonTitle(for: model) == "Remove from Favorites")

        AppCommands.toggleFavorite(model)
        #expect(model.store.record(id)?.game.isFavorite == false)
        #expect(AppCommands.favoriteButtonTitle(for: model) == "Add to Favorites")

        AppCommands.findMetadata(model)
        #expect(model.findMetadataFor == id)
        model.findMetadataFor = nil

        // Read-only record disables editing
        if var record = model.store.record(id) {
            record.status = .readOnly(reason: "Future schema")
            model.store.upsert(record)
        }
        #expect(!AppCommands.canEdit(model))
        AppCommands.toggleFavorite(model)
        #expect(model.store.record(id)?.game.isFavorite == false)
        AppCommands.findMetadata(model)
        #expect(model.findMetadataFor == nil)
    }

    @Test func finderCommandsEnablement() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(files: [])
        let crate = try #require(model.store.record(id)).crateURL
        let filesDir = crate.appending(path: "files", directoryHint: .isDirectory)

        #expect(!AppCommands.canShowInFinder(model))
        #expect(!AppCommands.canShowCDriveInFinder(model, io: io))

        model.selection = id
        #expect(AppCommands.canShowInFinder(model))
        #expect(!AppCommands.canShowCDriveInFinder(model, io: io))

        try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        #expect(AppCommands.canShowCDriveInFinder(model, io: io))
        #expect(AppCommands.selectedCDriveURL(for: model, io: io) == filesDir)
    }
}

import ConfigKit
import Foundation
import ImportKit
import LauncherKit
import LibraryKit
import os
import Testing
@testable import DOSCrate

final class FakeProcess: RunningProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int32, Never>?
    private var exitCode: Int32?

    func terminate() { finish(0) }
    func kill() { finish(137) }
    func finish(_ code: Int32) {
        let c: CheckedContinuation<Int32, Never>? = lock.withLock {
            guard exitCode == nil else { return nil }
            exitCode = code
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: code)
    }
    func waitForExit() async -> Int32 {
        await withCheckedContinuation { (c: CheckedContinuation<Int32, Never>) in
            let done: Int32? = lock.withLock {
                if let e = exitCode { return e }
                continuation = c
                return nil
            }
            if let done { c.resume(returning: done) }
        }
    }
}

final class FakeRunner: ProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _processes: [FakeProcess] = []
    var processes: [FakeProcess] { lock.withLock { _processes } }
    func start(_ plan: LaunchPlan, logURL: URL) throws -> any RunningProcess {
        let p = FakeProcess()
        lock.withLock { _processes.append(p) }
        return p
    }
}

@MainActor
func waitUntil(_ cond: @MainActor () -> Bool) async {
    for _ in 0..<500 where !cond() { try? await Task.sleep(for: .milliseconds(10)) }
}

@MainActor
@Suite struct AppModelTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "appmodel-\(UUID().uuidString)")
    let io = CrateIO()
    let runner = FakeRunner()

    /// Creates a library holding one managed game; returns the model and the game id.
    func makeModel(executable: String?, files: [String] = [], libraryExists: Bool = true,
                   launchTimeout: Duration? = nil,
                   configure: (inout Game) -> Void = { _ in },
                   verify: @escaping @Sendable (URL) throws -> Void = { _ in }) async throws -> (AppModel, UUID) {
        let fm = FileManager.default
        let lib = root.appending(path: "Library")
        if libraryExists { try fm.createDirectory(at: lib, withIntermediateDirectories: true) }
        var id = UUID()
        if libraryExists {
            let crate = try io.makeCrate(title: "Test Game", in: lib)
            var game = Game(title: "Test Game", source: .managed)
            game.launch.executable = executable
            configure(&game)
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
        let suite = "doscrate-test-\(UUID().uuidString)"
        let prefs = Preferences(defaults: UserDefaults(suiteName: suite)!)
        let store = LibraryStore(library: lib)
        await store.reload()
        let model = if let launchTimeout {
            AppModel(prefs: prefs, store: store, sessions: SessionManager(runner: runner),
                     importer: Importer(), dosbox: dosbox, verifyDosbox: verify,
                     launchTimeout: launchTimeout)
        } else {
            AppModel(prefs: prefs, store: store, sessions: SessionManager(runner: runner),
                     importer: Importer(), dosbox: dosbox, verifyDosbox: verify)
        }
        await model.startupVerify?.value
        return (model, id)
    }

    @Test func playSuccessUpdatesStatsOnEnd() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: "GAME.EXE", files: ["GAME.EXE"])
        await model.play(id)?.value
        #expect(model.alert == nil)
        #expect(model.sessions.running.contains(id))
        runner.processes[0].finish(0)
        await waitUntil { !model.sessions.running.contains(id) }
        let stats = try #require(model.store.record(id)).game.stats
        #expect(stats.launchCount == 1)
        #expect(stats.lastPlayed != nil)
        #expect(stats.totalPlaySeconds >= 0)
        #expect(model.lastResult[id] == nil)
        await model.store.reload()
        #expect(model.store.record(id)?.game.stats.launchCount == 1)
    }

    @Test func removeGamesSkipsRunningGameAndUpdatesSelection() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: "GAME.EXE", files: ["GAME.EXE"])
        let other = try io.makeCrate(title: "Other", in: model.store.library)
        let otherGame = Game(title: "Other", source: .managed)
        try io.save(otherGame, extra: [:], to: other)
        await model.store.reload()

        await model.play(id)?.value
        #expect(model.sessions.running.contains(id))
        model.selectedIDs = [id, otherGame.id]
        #expect(model.selection == nil)

        await model.removeGames([id, otherGame.id], trashFolders: false)

        #expect(model.store.records.map(\.id) == [id])
        #expect(model.selectedIDs == [id])
        #expect(model.selection == id)
        #expect(model.alert?.title == "Couldn't remove 1 game")
        #expect(model.alert?.message.contains("Test Game") == true)
        #expect(!model.isRemoving)
        runner.processes[0].finish(0)
        await waitUntil { !model.sessions.running.contains(id) }
    }

    @Test func gamesPendingRemovalCannotLaunchAndShowAlert() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: "GAME.EXE", files: ["GAME.EXE"])
        var others: [UUID] = []
        for n in 1...5 {
            let crate = try io.makeCrate(title: "Other \(n)", in: model.store.library)
            let game = Game(title: "Other \(n)", source: .managed)
            try io.save(game, extra: [:], to: crate)
            others.append(game.id)
        }
        await model.store.reload()

        let state = OSAllocatedUnfairLock(initialState: (entered: false, released: false))
        model.store.itemRemovalHook = { _ in
            state.withLock { $0.entered = true }
            while !state.withLock({ $0.released }) {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        let removal = Task { await model.removeGames(Set(others + [id]), trashFolders: false) }
        await waitUntil { state.withLock { $0.entered } }
        #expect(model.pendingRemovalIDs.contains(id))
        #expect(LibraryView.showsRemovalCancel(for: model))
        #expect(RetroStatusBar.showsRemovalCancel(for: model))

        var flushedWrite = false
        model.setPendingWrite(id, owner: "draft") { flushedWrite = true }
        #expect(model.play(id) == nil)
        #expect(!flushedWrite)
        #expect(!model.sessions.running.contains(id))
        #expect(runner.processes.isEmpty)
        let alert = try #require(model.alert)
        #expect(alert.title == "Can't start Test Game")
        #expect(alert.message == "This game is being removed from the library. Cancel the removal to play it.")
        #expect(alert.gameID == id)

        model.store.itemRemovalHook = nil
        state.withLock { $0.released = true }
        await removal.value
        #expect(model.pendingRemovalIDs.isEmpty)
        #expect(model.store.records.isEmpty)
    }

    @Test func cancelRemovalStopsBatchAndKeepsRemainingGames() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: "GAME.EXE", files: ["GAME.EXE"])
        var allIDs: [UUID] = [id]
        for n in 1...4 {
            let crate = try io.makeCrate(title: "Other \(n)", in: model.store.library)
            let game = Game(title: "Other \(n)", source: .managed)
            try io.save(game, extra: [:], to: crate)
            allIDs.append(game.id)
        }
        await model.store.reload()
        model.selectedIDs = Set(allIDs)

        let count = OSAllocatedUnfairLock(initialState: 0)
        model.store.itemRemovalHook = { _ in
            let current = count.withLock {
                $0 += 1
                return $0
            }
            if current == 2 {
                await MainActor.run { model.cancelRemoval() }
            }
        }

        await model.removeGames(Set(allIDs), trashFolders: false)
        model.store.itemRemovalHook = nil

        #expect(!model.isRemoving)
        #expect(model.removalProgress == nil)
        #expect(model.pendingRemovalIDs.isEmpty)
        #expect(model.store.records.count == 4)
        #expect(model.selectedIDs == Set(model.store.records.map(\.id)))
    }

    @Test func removeGameDropsItFromAMultipleSelection() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: "GAME.EXE", files: ["GAME.EXE"])
        let other = try io.makeCrate(title: "Other", in: model.store.library)
        let otherGame = Game(title: "Other", source: .managed)
        try io.save(otherGame, extra: [:], to: other)
        await model.store.reload()
        model.selectedIDs = [id, otherGame.id]

        model.removeGame(otherGame.id, trashFiles: true)

        #expect(model.store.records.map(\.id) == [id])
        #expect(model.selectedIDs == [id])
        #expect(model.selection == id)
        #expect(model.alert == nil)
    }

    @Test func batchRemovalMessageDescribesEachKind() {
        let copied = GameRecord(game: Game(title: "A", source: .managed), crateURL: URL(filePath: "/tmp/A.doscrate"))
        let kept = GameRecord(game: Game(title: "B", source: .referenced(path: "/tmp/B", bookmark: Data())),
                              crateURL: URL(filePath: "/tmp/B.doscrate"))
        let running = GameRecord(game: Game(title: "C", source: .managed), crateURL: URL(filePath: "/tmp/C.doscrate"))
        let message = LibraryView.removalMessage(for: [copied, kept, running], running: [running.id])
        #expect(message == "1 game copied into the library will be moved to the Trash with its files. "
            + "1 game kept in place will be removed from the library. Its folder stays where it is, "
            + "unless you also move it to the Trash. 1 game still running will be skipped.")
        let two = LibraryView.removalMessage(for: [kept, kept], running: [])
        #expect(two == "2 games kept in place will be removed from the library. Their folders stay where they are, "
            + "unless you also move them to the Trash.")
    }

    @Test func playRunsPendingWriteBeforeLaunchingOnce() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: "GAME.EXE", files: ["GAME.EXE"])
        var launchedBeforeWrite: [Bool] = []
        model.setPendingWrite(id, owner: "a") { launchedBeforeWrite.append(!self.runner.processes.isEmpty) }
        await model.play(id)?.value
        #expect(launchedBeforeWrite == [false])
        #expect(model.sessions.running.contains(id))
        runner.processes[0].finish(0)
        await waitUntil { !model.sessions.running.contains(id) }
        await model.play(id)?.value
        #expect(launchedBeforeWrite == [false])
    }

    @Test func playRunsEveryOwnersPendingWriteAndSkipsClearedOnes() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: "GAME.EXE", files: ["GAME.EXE"])
        var ran: [String] = []
        model.setPendingWrite(id, owner: "draft") { ran.append("draft") }
        model.setPendingWrite(id, owner: "override") { ran.append("override") }
        model.setPendingWrite(id, owner: "cleared") { ran.append("cleared") }
        model.setPendingWrite(id, owner: "cleared", nil)
        await model.play(id)?.value
        #expect(Set(ran) == ["draft", "override"] && ran.count == 2)
        #expect(model.sessions.running.contains(id))
    }

    @Test func playDoesNotRunAnotherGamesPendingWrites() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: "GAME.EXE", files: ["GAME.EXE"])
        var ran = false
        model.setPendingWrite(UUID(), owner: "draft") { ran = true }
        await model.play(id)?.value
        #expect(!ran)
    }

    @Test func playNonDOSPathRaisesAlertWithUseFolderFix() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: "Long Name/GAME.EXE", files: ["Long Name/GAME.EXE"])
        await model.play(id)?.value
        #expect(model.alert?.fix == .useFolderAsC("Long Name"))
        #expect(model.alert?.gameID == id)
        #expect(runner.processes.isEmpty)
    }

    @Test func useFolderAsCFixSetsDriveCRootAndSaves() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: "Long Name/GAME.EXE", files: ["Long Name/GAME.EXE"])
        model.applyFix(.useFolderAsC("Long Name"), for: id)
        let game = try #require(model.store.record(id)).game
        #expect(game.launch.driveCRoot == "Long Name")
        #expect(game.launch.executable == "GAME.EXE")
        await model.store.reload()
        #expect(model.store.record(id)?.game.launch.driveCRoot == "Long Name")
        await model.play(id)?.value
        #expect(model.alert == nil)
        #expect(model.sessions.running.contains(id))
    }

    @Test func nonDOSExecutableItselfOffersNoFolderFix() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: "KEEN/Long Name.exe", files: ["KEEN/Long Name.exe"])
        await model.play(id)?.value
        #expect(model.alert?.fix == .chooseExecutable)
        model.applyFix(.useFolderAsC("KEEN/Long Name.exe"), for: id)
        let game = try #require(model.store.record(id)).game
        #expect(game.launch.driveCRoot == "")
        #expect(game.launch.executable == "KEEN/Long Name.exe")
    }

    @Test func missingDriveCRootOffersResetNotLocate() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: "GAME.EXE", files: ["GAME.EXE"]) { $0.launch.driveCRoot = "GONE" }
        await model.play(id)?.value
        #expect(model.alert?.fix == .resetCRoot)
        #expect(runner.processes.isEmpty)
        model.applyFix(.resetCRoot, for: id)
        let game = try #require(model.store.record(id)).game
        #expect(game.launch.driveCRoot == "")
        #expect(game.launch.executable == "GONE/GAME.EXE")
    }

    @Test func missingMediaIsNotAFolderProblem() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: nil) {
            $0.media = [MediaImage(relativePath: "media/gone.iso", kind: .cdrom)]
        }
        try FileManager.default.createDirectory(at: try #require(model.store.record(id)).crateURL.appending(path: "files"),
                                                withIntermediateDirectories: true)
        await model.play(id)?.value
        #expect(model.alert?.title == "Disc image missing")
        #expect(model.alert?.fix == nil)
    }

    @Test func locateFolderIsNeverOfferedForManagedGames() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: "GAME.EXE")
        await model.play(id)?.value
        #expect(model.alert?.fix == nil)
        model.applyFix(.locateFolder, for: id)
        #expect(model.pendingFix == nil)
        #expect(AppModel.alert(for: .sourceUnreachable(path: "/x"), game: nil).fix == nil)
    }

    /// Breaks the game's game.json and reloads, leaving a needs-repair record.
    func breakGameJSON(_ model: AppModel, _ id: UUID) async throws -> URL {
        let crate = try #require(model.store.record(id)).crateURL
        try Data("{".utf8).write(to: crate.appending(path: "game.json"))
        await model.store.reload()
        return crate
    }

    func brokenFiles(_ crate: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: crate.path).filter { $0.hasSuffix(".broken") }
    }

    @Test func recreateWritesManagedGameAndKeepsBrokenFile() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, oldID) = try await makeModel(executable: "GAME.EXE", files: ["GAME.EXE"])
        let crate = try await breakGameJSON(model, oldID)
        let record = try #require(model.store.records.first)
        guard case .needsRepair = record.status else { Issue.record("expected needsRepair"); return }
        await model.play(record.id)?.value
        #expect(model.alert?.fix == .recreate)
        model.applyFix(.recreate, for: record.id)
        #expect(model.store.record(record.id)?.status == .ok)
        await model.store.reload()
        let fresh = try #require(model.store.records.first)
        #expect(fresh.status == .ok)
        #expect(fresh.game.source == .managed)
        #expect(try brokenFiles(crate).count == 1)
    }

    @Test func recreateWithoutFilesAsksForTheFolder() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, oldID) = try await makeModel(executable: nil)
        _ = try await breakGameJSON(model, oldID)
        let record = try #require(model.store.records.first)
        model.applyFix(.recreate, for: record.id)
        #expect(model.pendingFix == PendingFix(fix: .recreate, gameID: record.id))
    }

    @Test func removalWordingIsHonestPerSource() {
        let managed = GameRecord(game: Game(title: "M", source: .managed), crateURL: URL(filePath: "/l/M.doscrate"))
        #expect(LibraryView.removalMessage(for: managed, running: false).contains("moved to the Trash"))
        let referenced = GameRecord(game: Game(title: "R", source: .referenced(path: "/games/r", bookmark: Data())),
                                    crateURL: URL(filePath: "/l/R.doscrate"))
        #expect(LibraryView.removalMessage(for: referenced, running: false).contains("/games/r stays"))
        #expect(LibraryView.removalMessage(for: managed, running: true).hasPrefix("Stop"))
    }

    @Test func missingLibrarySetsNeedsSetup() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _) = try await makeModel(executable: nil, libraryExists: false)
        #expect(model.needsLibrarySetup)
        model.chooseLibrary(root.appending(path: "Library"), create: true)
        #expect(!model.needsLibrarySetup)
        #expect(model.prefs.libraryPath == root.appending(path: "Library").path)
    }

    @Test func unexpectedExitStoredInLastResult() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: "GAME.EXE", files: ["GAME.EXE"])
        await model.play(id)?.value
        runner.processes[0].finish(3)
        await waitUntil { model.lastResult[id] != nil }
        #expect(model.lastResult[id]?.exitCode == 3)
        #expect(model.lastResult[id]?.unexpected == true)
        #expect(model.store.record(id)?.game.stats.launchCount == 1)
    }

    @Test func dosboxVerifyFailureRaisesReinstallAlert() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let ranOffMain = OSAllocatedUnfairLock(initialState: false)
        let (model, _) = try await makeModel(executable: nil, verify: { _ in
            ranOffMain.withLock { $0 = !Thread.isMainThread }
            throw LaunchError.dosboxMissing
        })
        #expect(ranOffMain.withLock { $0 })
        #expect(model.alert != nil)
        #expect(model.alert?.fix == nil)
    }

    @Test func chooseLibraryStopsRunningSessionsAndSavesStatsToOldLibrary() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: "GAME.EXE", files: ["GAME.EXE"])
        let oldCrate = try #require(model.store.record(id)).crateURL
        await model.play(id)?.value
        #expect(model.sessions.running.contains(id))

        let newLib = root.appending(path: "SecondLibrary", directoryHint: .isDirectory)
        await model.chooseLibrary(newLib, create: true)?.value

        #expect(model.sessions.running.isEmpty)
        let savedInOldLib = io.loadRecord(at: oldCrate)
        #expect(savedInOldLib.game.stats.launchCount == 1)
        #expect(savedInOldLib.game.stats.lastPlayed != nil)
    }

    @Test func preferencesRoundTripAndBuildGlobalConfig() {
        let defaults = UserDefaults(suiteName: "doscrate-prefs-\(UUID().uuidString)")!
        let a = Preferences(defaults: defaults)
        #expect(a.libraryPath.hasSuffix("Documents/DOSCrate Library"))
        #expect(a.importLocation == .ask)
        a.defaultPreset = .pc486
        a.importLocation = .reference
        a.globalOverrides = GameSettings(fullscreen: true)
        a.rawGlobalOverrides = "[sdl]\n"
        a.soundfontPath = "/sf.sf2"
        let b = Preferences(defaults: defaults)
        #expect(b.defaultPreset == .pc486)
        #expect(b.importLocation == .reference)
        #expect(b.globalOverrides.fullscreen == true)
        let cfg = b.globalConfig
        #expect(cfg.rawOverrides == "[sdl]\n")
        #expect(cfg.env.soundfontPath == "/sf.sf2")
        #expect(cfg.env.mt32RomDir == nil)
    }

    @Test func playWithNoExecutableAndCandidatesPresentsChooseProgramAndDoesNotLaunch() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: nil, files: ["SETUP.EXE", "TESTGAME.EXE"])
        await model.play(id)?.value
        #expect(model.alert == nil)
        #expect(runner.processes.isEmpty)
        let prompt = try #require(model.chooseProgram)
        #expect(prompt.gameID == id)
        #expect(prompt.title == "Test Game")
        #expect(prompt.candidates.map(\.relativePath) == ["TESTGAME.EXE", "SETUP.EXE"])
    }

    @Test func confirmProgramSavesPreservingExtraAndLaunches() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: nil, files: ["SETUP.EXE", "TESTGAME.EXE"]) {
            $0.notes = "Keep me"
        }
        let crate = try #require(model.store.record(id)).crateURL
        let game = try #require(model.store.record(id)).game
        try io.save(game, extra: ["futureKey": .string("preserved")], to: crate)
        await model.store.reload()

        await model.play(id)?.value
        #expect(model.chooseProgram?.gameID == id)
        #expect(runner.processes.isEmpty)

        await model.confirmProgram("TESTGAME.EXE")?.value
        #expect(model.chooseProgram == nil)
        #expect(model.alert == nil)
        #expect(model.sessions.running.contains(id))
        #expect(runner.processes.count == 1)
        #expect(model.store.record(id)?.game.launch.executable == "TESTGAME.EXE")

        await model.store.reload()
        let saved = try #require(model.store.record(id))
        #expect(saved.game.launch.executable == "TESTGAME.EXE")
        #expect(saved.game.notes == "Keep me")
        #expect(saved.extra["futureKey"] == .string("preserved"))
    }

    @Test func cancelChooseProgramChangesNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: nil, files: ["GAME.EXE"])
        await model.play(id)?.value
        #expect(model.chooseProgram != nil)
        model.cancelChooseProgram()
        #expect(model.chooseProgram == nil)
        #expect(model.alert == nil)
        #expect(runner.processes.isEmpty)
        #expect(model.store.record(id)?.game.launch.executable == nil)
    }

    @Test func imageImportGameLaunchesWithoutPrompt() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: nil) {
            $0.media = [MediaImage(relativePath: "media/disc.iso", kind: .cdrom)]
        }
        let crate = try #require(model.store.record(id)).crateURL
        try FileManager.default.createDirectory(at: crate.appending(path: "files"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: crate.appending(path: "media"), withIntermediateDirectories: true)
        try Data("iso".utf8).write(to: crate.appending(path: "media/disc.iso"))

        await model.play(id)?.value
        #expect(model.chooseProgram == nil)
        #expect(model.alert == nil)
        #expect(model.sessions.running.contains(id))
    }

    @Test func playWithNoExecutableAndNoCandidatesFallsBackToAlert() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: nil, files: ["README.TXT"])
        await model.play(id)?.value
        #expect(model.chooseProgram == nil)
        #expect(model.alert?.title == "No program to run")
        #expect(model.alert?.fix == .chooseExecutable)
        #expect(runner.processes.isEmpty)

        model.applyFix(.chooseExecutable, for: id)
        #expect(model.chooseProgram == nil)
        #expect(model.pendingFix == PendingFix(fix: .chooseExecutable, gameID: id))
    }

    @Test func missingExecutableFixUsesRankedChooseProgramSheet() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: "GONE.EXE", files: ["SETUP.EXE", "TESTGAME.EXE"])
        await model.play(id)?.value
        #expect(model.chooseProgram == nil)
        #expect(model.alert?.title == "Program not found")
        #expect(model.alert?.fix == .chooseExecutable)

        model.applyFix(.chooseExecutable, for: id)
        #expect(model.alert == nil)
        #expect(model.pendingFix == nil)
        let prompt = try #require(model.chooseProgram)
        #expect(prompt.gameID == id)
        #expect(prompt.candidates.map(\.relativePath) == ["TESTGAME.EXE", "SETUP.EXE"])

        model.chooseAnotherProgram()
        #expect(model.chooseProgram == nil)
        #expect(model.pendingFix == PendingFix(fix: .chooseExecutable, gameID: id))
    }

    @Test func cancellingFirstRunScanImportsNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let existingLib = root.appending(path: "ExistingLib", directoryHint: .isDirectory)
        let exe = existingLib.appending(path: "keen/KEEN1.EXE", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: exe)

        let (model, _) = try await makeModel(executable: nil, libraryExists: false)
        let scan = model.chooseLibrary(existingLib, create: false)
        model.cancelImport()
        #expect(!model.isScanningLibrary)
        await scan?.value

        #expect(model.store.records.isEmpty)
        #expect(model.imports.progress == nil)
    }

    @Test func firstRunExistingFolderScanImportsFoldersReferencedAndArchivesCopiedWithoutDuplicates() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let existingLib = root.appending(path: "ExistingLib", directoryHint: .isDirectory)
        try fm.createDirectory(at: existingLib, withIntermediateDirectories: true)

        @discardableResult
        func write(_ dir: URL, _ path: String, _ text: String = "x") throws -> URL {
            let url = dir.appending(path: path, directoryHint: .notDirectory)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            return url
        }

        // Subfolder already referenced by an existing crate in the library.
        let alreadyRef = existingLib.appending(path: "already_ref", directoryHint: .isDirectory)
        try write(alreadyRef, "REF.EXE")
        let existingCrate = try io.makeCrate(title: "Existing", in: existingLib)
        var existingGame = Game(
            title: "Existing",
            source: .referenced(path: alreadyRef.path, bookmark: try CrateIO.makeBookmark(for: alreadyRef))
        )
        existingGame.launch.executable = "REF.EXE"
        try io.save(existingGame, extra: [:], to: existingCrate)

        // Two game subfolders (one with 1 candidate, one with 2 candidates).
        let keen = existingLib.appending(path: "keen", directoryHint: .isDirectory)
        try write(keen, "KEEN1.EXE")
        let doom = existingLib.appending(path: "doom", directoryHint: .isDirectory)
        try write(doom, "DOOM.EXE")
        try write(doom, "SETUP.EXE")

        // One subfolder without DOS programs, plus hidden/AppleDouble entries.
        let emptySub = existingLib.appending(path: "empty_sub", directoryHint: .isDirectory)
        try write(emptySub, "README.TXT")
        try write(existingLib, ".hidden/HIDE.EXE")
        try write(existingLib, "._ghost.zip")

        // A zip archive (built outside existingLib, then placed inside existingLib).
        let wolfSrc = root.appending(path: "wolf-src", directoryHint: .isDirectory)
        try write(wolfSrc, "WOLF3D.EXE")
        let wolfZip = existingLib.appending(path: "wolf.zip", directoryHint: .notDirectory)
        let ditto = Process()
        ditto.executableURL = URL(filePath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", wolfSrc.path, wolfZip.path]
        try ditto.run()
        ditto.waitUntilExit()
        #expect(ditto.terminationStatus == 0)

        // A cue+bin pair and a same-name iso (only the cue must be imported).
        try write(existingLib, "track1.bin")
        try write(existingLib, "disc.cue", "FILE \"track1.bin\" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n")
        try write(existingLib, "disc.iso")

        let (model, _) = try await makeModel(executable: nil, libraryExists: false)
        #expect(model.needsLibrarySetup)
        #expect(model.prefs.importLocation == .ask)

        let scan = model.chooseLibrary(existingLib, create: false)
        #expect(model.isScanningLibrary)
        await scan?.value

        #expect(!model.needsLibrarySetup)
        #expect(!model.isScanningLibrary)
        #expect(model.imports.batchPrompt == nil)
        #expect(model.imports.progress == nil)
        #expect(model.alert == nil)
        #expect(model.store.records.map(\.game.title) == ["Disc", "Doom", "Existing", "Keen", "Wolf"])

        let keenRec = try #require(model.store.records.first { $0.game.title == "Keen" })
        if case .referenced = keenRec.game.source {} else { Issue.record("Expected Keen to be referenced") }
        #expect(keenRec.game.launch.executable == "KEEN1.EXE")

        let doomRec = try #require(model.store.records.first { $0.game.title == "Doom" })
        if case .referenced = doomRec.game.source {} else { Issue.record("Expected Doom to be referenced") }
        #expect(doomRec.game.launch.executable == nil)

        let wolfRec = try #require(model.store.records.first { $0.game.title == "Wolf" })
        #expect(wolfRec.game.source == .managed)
        #expect(wolfRec.game.launch.executable == "WOLF3D.EXE")

        let discRec = try #require(model.store.records.first { $0.game.title == "Disc" })
        #expect(discRec.game.source == .managed)
        #expect(discRec.game.media == [MediaImage(relativePath: "media/disc.cue", kind: .cdrom)])
        #expect(model.selection == discRec.id)
    }

    @Test func chooseLibraryWithCreateTrueOrAfterFirstRunDoesNotScan() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let newLib = root.appending(path: "NewLib", directoryHint: .isDirectory)
        let keen = newLib.appending(path: "keen", directoryHint: .isDirectory)
        try fm.createDirectory(at: keen, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: keen.appending(path: "KEEN1.EXE"))

        let (model, _) = try await makeModel(executable: nil, libraryExists: false)
        #expect(model.needsLibrarySetup)
        await model.chooseLibrary(newLib, create: true)?.value
        #expect(!model.needsLibrarySetup)
        #expect(model.store.records.isEmpty)

        // Switching to another existing folder after first run does not scan either.
        let laterLib = root.appending(path: "LaterLib", directoryHint: .isDirectory)
        let doom = laterLib.appending(path: "doom", directoryHint: .isDirectory)
        try fm.createDirectory(at: doom, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: doom.appending(path: "DOOM.EXE"))

        await model.chooseLibrary(laterLib, create: false)?.value
        #expect(model.store.records.isEmpty)
    }

    @Test func firstRunScanSkipsOriginMatchButImportsTitleOnlyMatch() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let existingLib = root.appending(path: "OriginScanLib", directoryHint: .isDirectory)
        try fm.createDirectory(at: existingLib, withIntermediateDirectories: true)

        // 1. A folder in existingLib that was previously copied into a managed crate (matches by origin).
        let copiedFolder = existingLib.appending(path: "keen_src", directoryHint: .isDirectory)
        try fm.createDirectory(at: copiedFolder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: copiedFolder.appending(path: "KEEN1.EXE"))

        let importer = Importer()
        let pKeen = try await importer.prepare(copiedFolder)
        _ = try await importer.commit(pKeen, mode: .copy, title: "Commander Keen", executable: "KEEN1.EXE", into: existingLib)

        // 2. A zip in existingLib that was previously copied into a managed crate (matches by origin path+size+mtime).
        let wolfSrc = root.appending(path: "wolf-src", directoryHint: .isDirectory)
        try fm.createDirectory(at: wolfSrc, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: wolfSrc.appending(path: "WOLF3D.EXE"))
        let wolfZip = existingLib.appending(path: "wolf.zip", directoryHint: .notDirectory)
        let ditto = Process()
        ditto.executableURL = URL(filePath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", wolfSrc.path, wolfZip.path]
        try ditto.run()
        ditto.waitUntilExit()
        let pWolf = try await importer.prepare(wolfZip)
        _ = try await importer.commit(pWolf, mode: .copy, title: "Wolfenstein", executable: "WOLF3D.EXE", into: existingLib)
        importer.discard(pWolf)

        // 3. Another folder whose suggested title ("Wolfenstein") matches an existing title, but has a different origin.
        let sameTitleDifferentOrigin = existingLib.appending(path: "wolfenstein", directoryHint: .isDirectory)
        try fm.createDirectory(at: sameTitleDifferentOrigin, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: sameTitleDifferentOrigin.appending(path: "WOLF.EXE"))

        let (model, _) = try await makeModel(executable: nil, libraryExists: false)
        await model.chooseLibrary(existingLib, create: false)?.value

        // keen_src and wolf.zip were skipped via .sameSource origin match; wolfenstein (title-only match) was imported.
        #expect(model.store.records.count == 3)
        #expect(model.store.records.filter { $0.game.title == "Commander Keen" }.count == 1)
        #expect(model.store.records.filter { $0.game.title == "Wolfenstein" }.count == 2)
    }

    @Test func defaultLaunchTimeoutIsTwentySeconds() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _) = try await makeModel(executable: nil)
        #expect(model.launchTimeout == .seconds(20))
    }

    @Test func playRunsOffMainTracksStartingAndIgnoresDuplicatePlay() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let release = DispatchSemaphore(value: 0)
        let state = OSAllocatedUnfairLock(initialState: (armed: false, calls: 0, ranOffMain: false))
        let (model, id) = try await makeModel(executable: "GAME.EXE", files: ["GAME.EXE"]) { _ in } verify: { _ in
            let shouldBlock = state.withLock { s -> Bool in
                guard s.armed else { return false }
                s.calls += 1
                s.ranOffMain = !Thread.isMainThread
                return true
            }
            if shouldBlock {
                release.wait()
            }
        }
        state.withLock { $0.armed = true }

        let first = model.play(id)
        #expect(first != nil)
        #expect(model.startingIDs == [id])
        #expect(model.sessions.running.isEmpty)
        #expect(runner.processes.isEmpty)

        await waitUntil { state.withLock { $0.calls == 1 } }
        #expect(state.withLock { $0.ranOffMain })
        #expect(model.play(id) == nil)
        #expect(state.withLock { $0.calls } == 1)

        release.signal()
        await first?.value
        #expect(model.startingIDs.isEmpty)
        #expect(model.sessions.running == [id])
        #expect(runner.processes.count == 1)

        // A second Play while already running also does nothing.
        #expect(model.play(id) == nil)
        #expect(model.alert == nil)
        #expect(runner.processes.count == 1)
    }

    @Test func playTimeoutShowsAlertKeepsStartingUntilWorkEndsAndIgnoresLateCompletion() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let release = DispatchSemaphore(value: 0)
        let state = OSAllocatedUnfairLock(initialState: (armed: false, entered: false))
        let (model, id) = try await makeModel(
            executable: "GAME.EXE", files: ["GAME.EXE"], launchTimeout: .milliseconds(100)
        ) { _ in } verify: { _ in
            let shouldBlock = state.withLock { s -> Bool in
                guard s.armed else { return false }
                s.entered = true
                return true
            }
            if shouldBlock { release.wait() }
        }
        state.withLock { $0.armed = true }

        let first = model.play(id)
        #expect(model.startingIDs == [id])
        await waitUntil { state.withLock { $0.entered } }

        await waitUntil { model.alert != nil }
        #expect(model.sessions.running.isEmpty)
        #expect(runner.processes.isEmpty)
        let alert = try #require(model.alert)
        #expect(alert.title == "Can't start Test Game")
        #expect(alert.message.contains("library volume"))
        #expect(alert.message.contains("isn't responding"))

        // The expired attempt may still write launch files into the crate, so the game stays
        // starting: no second Play and no removal until that work ends.
        model.alert = nil
        #expect(model.startingIDs == [id])
        #expect(model.play(id) == nil)
        model.removeGame(id, trashFiles: true)
        #expect(model.store.record(id) != nil)
        model.alert = nil

        release.signal()
        await first?.value
        #expect(model.startingIDs.isEmpty)
        #expect(model.sessions.running.isEmpty)
        #expect(runner.processes.isEmpty)
        #expect(model.alert == nil)

        // A later Play of the same game after the timeout is allowed.
        state.withLock { $0.armed = false }
        await model.play(id)?.value
        #expect(model.sessions.running == [id])
        #expect(runner.processes.count == 1)
    }

    @Test func removingAGameThatIsStartingIsRefused() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let release = DispatchSemaphore(value: 0)
        let state = OSAllocatedUnfairLock(initialState: (armed: false, entered: false))
        let (model, id) = try await makeModel(executable: "GAME.EXE", files: ["GAME.EXE"]) { _ in } verify: { _ in
            let shouldBlock = state.withLock { s -> Bool in
                guard s.armed else { return false }
                s.entered = true
                return true
            }
            if shouldBlock { release.wait() }
        }
        state.withLock { $0.armed = true }

        let task = model.play(id)
        #expect(model.startingIDs == [id])
        await waitUntil { state.withLock { $0.entered } }

        // The background start may still write into the crate, so removal must wait for it.
        model.removeGame(id, trashFiles: true)
        #expect(model.store.record(id) != nil)
        #expect(model.alert?.title == "Can't remove Test Game")
        model.alert = nil

        await model.removeGames([id], trashFolders: true)
        #expect(model.store.record(id) != nil)
        #expect(model.alert?.title == "Couldn't remove 1 game")
        model.alert = nil

        release.signal()
        await task?.value
        #expect(model.startingIDs.isEmpty)
        #expect(model.sessions.running.contains(id))
        runner.processes[0].finish(0)
        await waitUntil { !model.sessions.running.contains(id) }
    }

    @Test func appTerminationDelegateWaitsForLiveProcessesBeforeReplying() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let release = DispatchSemaphore(value: 0)
        let state = OSAllocatedUnfairLock(initialState: (armed: false, entered: false))
        let (model, id) = try await makeModel(executable: "GAME.EXE", files: ["GAME.EXE"]) { _ in } verify: { _ in
            let shouldBlock = state.withLock { s -> Bool in
                guard s.armed else { return false }
                s.entered = true
                return true
            }
            if shouldBlock { release.wait() }
        }
        let delegate = AppTerminationDelegate()
        delegate.model = model

        // Add a second game to test an in-flight launch during termination.
        let lib = model.store.library
        let crate2 = try io.makeCrate(title: "Second Game", in: lib)
        var game2 = Game(title: "Second Game", source: .managed)
        game2.launch.executable = "GAME.EXE"
        try io.save(game2, extra: [:], to: crate2)
        let exe2 = crate2.appending(path: "files/GAME.EXE")
        try FileManager.default.createDirectory(at: exe2.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: exe2)
        await model.store.reload()

        // Start game 1 normally, then start game 2 blocked in preparation.
        await model.play(id)?.value
        #expect(model.sessions.running.contains(id))
        state.withLock { $0.armed = true }
        let pendingTask = model.play(game2.id)
        await waitUntil { state.withLock { $0.entered } }
        #expect(model.startingIDs.contains(game2.id))

        var replied = false
        let replyDecision = delegate.prepareForTermination { replied = $0 }
        #expect(replyDecision == .terminateLater)
        #expect(model.sessions.running.isEmpty)
        #expect(model.isTerminating)

        // Release the in-flight launch preparation; it must be discarded and not launch DOSBox.
        release.signal()
        await pendingTask?.value
        #expect(runner.processes.count == 1)
        #expect(model.play(id) == nil)

        await waitUntil { replied }
        #expect(!model.sessions.hasLiveProcesses)
    }

    @Test func addMediaPersistsToTargetGameWhenSelectionChangesDuringCopy() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: "GAME.EXE", files: ["GAME.EXE"]) { _ in }
        let lib = model.store.library
        let crate2 = try io.makeCrate(title: "Second Game", in: lib)
        var game2 = Game(title: "Second Game", source: .managed)
        game2.launch.executable = "GAME.EXE"
        try io.save(game2, extra: [:], to: crate2)
        await model.store.reload()

        let discSource = root.appending(path: "DISC.ISO")
        try Data("iso-bytes".utf8).write(to: discSource)

        model.selection = id
        var editedDraft = try #require(model.store.record(id)?.game)
        editedDraft.title = "Renamed Before Selection Change"
        _ = GameDetailView.scheduleDraftSave(draft: editedDraft, in: model)

        let state = OSAllocatedUnfairLock(initialState: (entered: false, released: false))

        let addTask = Task {
            await model.addMedia(from: discSource, to: id) {
                state.withLock { $0.entered = true }
                while !state.withLock({ $0.released }) {
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
        }

        await waitUntil { state.withLock { $0.entered } }
        // Switch selection to the second game while the disc copy is still in flight.
        model.selection = game2.id
        state.withLock { $0.released = true }

        let added = await addTask.value
        #expect(added == MediaImage(relativePath: "media/DISC.ISO", kind: .cdrom))

        let updatedRecord = try #require(model.store.record(id))
        #expect(updatedRecord.game.title == "Renamed Before Selection Change")
        #expect(updatedRecord.game.media == [MediaImage(relativePath: "media/DISC.ISO", kind: .cdrom)])
        #expect(FileManager.default.fileExists(atPath: updatedRecord.crateURL.appending(path: "media/DISC.ISO").path))

        // Adding a second image with the same filename numbers it without colliding.
        let secondAdded = await model.addMedia(from: discSource, to: id)
        #expect(secondAdded == MediaImage(relativePath: "media/DISC 2.ISO", kind: .cdrom))
        #expect(model.store.record(id)?.game.media.count == 2)
        #expect(model.store.record(game2.id)?.game.media.isEmpty == true)
    }

    @Test func addMediaCleansUpCopiedFileIfGameRemovedDuringCopy() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: "GAME.EXE", files: ["GAME.EXE"]) { _ in }
        let crateURL = try #require(model.store.record(id)?.crateURL)

        let floppySource = root.appending(path: "DISK1.IMG")
        try Data("floppy-bytes".utf8).write(to: floppySource)

        let state = OSAllocatedUnfairLock(initialState: (entered: false, released: false))

        let addTask = Task {
            await model.addMedia(from: floppySource, to: id) {
                state.withLock { $0.entered = true }
                while !state.withLock({ $0.released }) {
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
        }

        await waitUntil { state.withLock { $0.entered } }
        // Simulate the record being removed from the store while the copy is in flight,
        // while keeping the crate folder on disk to verify the copied file in media/ is cleaned up.
        let backupURL = root.appending(path: "CrateBackup.doscrate")
        try FileManager.default.copyItem(at: crateURL, to: backupURL)
        try model.store.remove(id, trashFiles: false)
        try FileManager.default.moveItem(at: backupURL, to: crateURL)
        state.withLock { $0.released = true }

        let added = await addTask.value
        #expect(added == nil)
        #expect(!FileManager.default.fileExists(atPath: crateURL.appending(path: "media/DISK1.IMG").path))
    }

    @Test func runSetupFlushesPendingWritesAndLaunchesSetupExecutableWithoutArguments() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(
            executable: "GAME.EXE",
            files: ["GAME.EXE", "SETUP.EXE"]
        ) {
            $0.launch.arguments = "-warp 2"
        }

        // Register a pending draft write that sets setupExecutable before runSetup is called.
        model.setPendingWrite(id, owner: "draft") {
            guard var g = model.store.record(id)?.game else { return }
            g.launch.setupExecutable = "SETUP.EXE"
            try? model.store.save(g)
        }

        await model.runSetup(id)?.value
        #expect(model.alert == nil)
        #expect(model.sessions.running.contains(id))
        let record = try #require(model.store.record(id))
        #expect(record.game.launch.setupExecutable == "SETUP.EXE")
        let conf = try String(contentsOf: record.crateURL.appending(path: ".cache/launch.conf"), encoding: .utf8)
        #expect(conf.contains("SETUP.EXE\n"))
        #expect(!conf.contains("GAME.EXE"))
        #expect(!conf.contains("-warp"))

        runner.processes[0].finish(0)
        await waitUntil { !model.sessions.running.contains(id) }
    }

    @Test func runSetupWithMissingSetupExecutableShowsAlertAndDoesNotPresentChooseProgramSheet() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: "GAME.EXE", files: ["GAME.EXE"])
        await model.runSetup(id)?.value
        #expect(model.chooseProgram == nil)
        #expect(model.alert?.title == "No program to run")
        #expect(runner.processes.isEmpty)
    }
}

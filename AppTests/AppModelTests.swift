import ConfigKit
import Foundation
import ImportKit
import LauncherKit
import LibraryKit
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
private func waitUntil(_ cond: @MainActor () -> Bool) async {
    for _ in 0..<500 where !cond() { try? await Task.sleep(for: .milliseconds(10)) }
}

@MainActor
@Suite struct AppModelTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "appmodel-\(UUID().uuidString)")
    let io = CrateIO()
    let runner = FakeRunner()

    /// Creates a library holding one managed game; returns the model and the game id.
    func makeModel(executable: String?, files: [String] = [], libraryExists: Bool = true,
                   configure: (inout Game) -> Void = { _ in },
                   verify: @escaping @MainActor (URL) throws -> Void = { _ in }) async throws -> (AppModel, UUID) {
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
        let model = AppModel(prefs: prefs, store: store, sessions: SessionManager(runner: runner),
                             importer: Importer(), dosbox: dosbox, verifyDosbox: verify)
        return (model, id)
    }

    @Test func playSuccessUpdatesStatsOnEnd() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: "GAME.EXE", files: ["GAME.EXE"])
        model.play(id)
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

    @Test func playRunsPendingWriteBeforeLaunchingOnce() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: "GAME.EXE", files: ["GAME.EXE"])
        var launchedBeforeWrite: [Bool] = []
        model.setPendingWrite(id, owner: "a") { launchedBeforeWrite.append(!self.runner.processes.isEmpty) }
        model.play(id)
        #expect(launchedBeforeWrite == [false])
        #expect(model.sessions.running.contains(id))
        runner.processes[0].finish(0)
        await waitUntil { !model.sessions.running.contains(id) }
        model.play(id)
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
        model.play(id)
        #expect(Set(ran) == ["draft", "override"] && ran.count == 2)
        #expect(model.sessions.running.contains(id))
    }

    @Test func playDoesNotRunAnotherGamesPendingWrites() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: "GAME.EXE", files: ["GAME.EXE"])
        var ran = false
        model.setPendingWrite(UUID(), owner: "draft") { ran = true }
        model.play(id)
        #expect(!ran)
    }

    @Test func playNonDOSPathRaisesAlertWithUseFolderFix() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: "Long Name/GAME.EXE", files: ["Long Name/GAME.EXE"])
        model.play(id)
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
        model.play(id)
        #expect(model.alert == nil)
        #expect(model.sessions.running.contains(id))
    }

    @Test func nonDOSExecutableItselfOffersNoFolderFix() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: "KEEN/Long Name.exe", files: ["KEEN/Long Name.exe"])
        model.play(id)
        #expect(model.alert?.fix == .chooseExecutable)
        model.applyFix(.useFolderAsC("KEEN/Long Name.exe"), for: id)
        let game = try #require(model.store.record(id)).game
        #expect(game.launch.driveCRoot == "")
        #expect(game.launch.executable == "KEEN/Long Name.exe")
    }

    @Test func missingDriveCRootOffersResetNotLocate() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: "GAME.EXE", files: ["GAME.EXE"]) { $0.launch.driveCRoot = "GONE" }
        model.play(id)
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
        model.play(id)
        #expect(model.alert?.title == "Disc image missing")
        #expect(model.alert?.fix == nil)
    }

    @Test func locateFolderIsNeverOfferedForManagedGames() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: "GAME.EXE")
        model.play(id)
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
        model.play(record.id)
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
        model.play(id)
        runner.processes[0].finish(3)
        await waitUntil { model.lastResult[id] != nil }
        #expect(model.lastResult[id]?.exitCode == 3)
        #expect(model.lastResult[id]?.unexpected == true)
        #expect(model.store.record(id)?.game.stats.launchCount == 1)
    }

    @Test func dosboxVerifyFailureRaisesReinstallAlert() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _) = try await makeModel(executable: nil, verify: { _ in throw LaunchError.dosboxMissing })
        #expect(model.alert != nil)
        #expect(model.alert?.fix == nil)
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
        model.play(id)
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

        model.play(id)
        #expect(model.chooseProgram?.gameID == id)
        #expect(runner.processes.isEmpty)

        model.confirmProgram("TESTGAME.EXE")
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
        model.play(id)
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

        model.play(id)
        #expect(model.chooseProgram == nil)
        #expect(model.alert == nil)
        #expect(model.sessions.running.contains(id))
    }

    @Test func playWithNoExecutableAndNoCandidatesFallsBackToAlert() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, id) = try await makeModel(executable: nil, files: ["README.TXT"])
        model.play(id)
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
        model.play(id)
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
}

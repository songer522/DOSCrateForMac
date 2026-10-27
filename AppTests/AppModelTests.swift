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
                   verify: @escaping @MainActor (URL) throws -> Void = { _ in }) async throws -> (AppModel, UUID) {
        let fm = FileManager.default
        let lib = root.appending(path: "Library")
        if libraryExists { try fm.createDirectory(at: lib, withIntermediateDirectories: true) }
        var id = UUID()
        if libraryExists {
            let crate = try io.makeCrate(title: "Test Game", in: lib)
            var game = Game(title: "Test Game", source: .managed)
            game.launch.executable = executable
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
        #expect(model.alert?.fix == .reinstall)
    }

    @Test func preferencesRoundTripAndBuildGlobalConfig() {
        let defaults = UserDefaults(suiteName: "doscrate-prefs-\(UUID().uuidString)")!
        let a = Preferences(defaults: defaults)
        #expect(a.libraryPath.hasSuffix("Documents/DOSCrate Library"))
        a.defaultPreset = .pc486
        a.globalOverrides = GameSettings(fullscreen: true)
        a.rawGlobalOverrides = "[sdl]\n"
        a.soundfontPath = "/sf.sf2"
        let b = Preferences(defaults: defaults)
        #expect(b.defaultPreset == .pc486)
        #expect(b.globalOverrides.fullscreen == true)
        let cfg = b.globalConfig
        #expect(cfg.rawOverrides == "[sdl]\n")
        #expect(cfg.env.soundfontPath == "/sf.sf2")
        #expect(cfg.env.mt32RomDir == nil)
    }
}

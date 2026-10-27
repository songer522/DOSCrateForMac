import Foundation
import ImportKit
import LauncherKit
import LibraryKit
import Testing
@testable import DOSCrate

@discardableResult
private func touchFile(_ root: URL, _ path: String) throws -> URL {
    let url = root.appending(path: path, directoryHint: .notDirectory)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: url)
    return url
}

private func makeZip(_ folder: URL, to name: String, in dir: URL) throws -> URL {
    let out = dir.appending(path: name, directoryHint: .notDirectory)
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/ditto")
    p.arguments = ["-c", "-k", folder.path, out.path]
    try p.run()
    p.waitUntilExit()
    #expect(p.terminationStatus == 0)
    return out
}

@MainActor
@Suite struct ImportQueueTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "importqueue-\(UUID().uuidString)")

    func makeModel(stagingParent: URL? = nil) async throws -> AppModel {
        let fm = FileManager.default
        let lib = root.appending(path: "Library")
        try fm.createDirectory(at: lib, withIntermediateDirectories: true)
        let dosbox = root.appending(path: "dosbox")
        try Data("#!/bin/sh\n".utf8).write(to: dosbox)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dosbox.path)
        let prefs = Preferences(defaults: UserDefaults(suiteName: "doscrate-iq-\(UUID().uuidString)")!)
        let store = LibraryStore(library: lib)
        await store.reload()
        let importer = stagingParent.map { Importer(stagingParent: $0) } ?? Importer()
        return AppModel(prefs: prefs, store: store, sessions: SessionManager(runner: FakeRunner()),
                        importer: importer, dosbox: dosbox, verifyDosbox: { _ in })
    }

    @Test func singleItemOpensSheetAndAdvances() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeModel()
        let queue = ImportQueue()
        #expect(queue.current == nil)
        let a = URL(filePath: "/tmp/a.zip")
        queue.add([a], model: model)
        #expect(queue.current?.url == a)
        #expect(queue.progress == nil)
        queue.finishCurrent()
        #expect(queue.current == nil)
    }

    @Test func batchImportsWithoutSheetAndSetsExecutableOnlyForSingleCandidate() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeModel()
        let queue = ImportQueue()

        let one = root.appending(path: "keen_one", directoryHint: .isDirectory)
        try touchFile(one, "KEEN1.EXE")

        let several = root.appending(path: "doom_two", directoryHint: .isDirectory)
        try touchFile(several, "DOOM.EXE")
        try touchFile(several, "SETUP.EXE")

        let disc = try touchFile(root, "myst_disc.iso")

        let task = queue.add([one, several, disc], model: model)
        #expect(queue.current == nil)
        #expect(queue.progress == ImportQueue.Progress(current: 1, total: 3))
        #expect(queue.progress?.label == "Importing 1 of 3…")

        await task?.value
        #expect(queue.current == nil)
        #expect(queue.progress == nil)
        #expect(model.alert == nil)
        #expect(model.store.records.count == 3)

        let keen = try #require(model.store.records.first { $0.game.title == "Keen One" })
        #expect(keen.game.source == .managed)
        #expect(keen.game.launch.executable == "KEEN1.EXE")
        #expect(model.selection == keen.id)

        let doom = try #require(model.store.records.first { $0.game.title == "Doom Two" })
        #expect(doom.game.source == .managed)
        #expect(doom.game.launch.executable == nil)

        let myst = try #require(model.store.records.first { $0.game.title == "Myst Disc" })
        #expect(myst.game.launch.executable == nil)
        #expect(myst.game.media == [MediaImage(relativePath: "media/myst_disc.iso", kind: .cdrom)])
    }

    @Test func batchFailureDoesNotStopRestAndReportsSummaryOnce() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let model = try await makeModel(stagingParent: staging)
        let queue = ImportQueue()

        let empty = root.appending(path: "empty", directoryHint: .isDirectory)
        try touchFile(empty, "README.TXT")

        let keen = root.appending(path: "keen", directoryHint: .isDirectory)
        try touchFile(keen, "KEEN1.EXE")

        let bad = try touchFile(root, "archive.rar")

        let wolfTree = root.appending(path: "wolf-tree", directoryHint: .isDirectory)
        try touchFile(wolfTree, "WOLF3D.EXE")
        let wolfZip = try makeZip(wolfTree, to: "wolf.zip", in: root)

        await queue.add([empty, keen, bad, wolfZip], model: model)?.value

        #expect(queue.current == nil)
        #expect(queue.progress == nil)
        #expect(model.store.records.map(\.game.title) == ["Keen", "Wolf"])
        #expect(model.selection == model.store.records.first { $0.game.title == "Keen" }?.id)

        let alert = try #require(model.alert)
        let expected = [
            "empty: \(importErrorMessage(ImportError.noExecutables))",
            "archive.rar: \(importErrorMessage(ImportError.unsupportedType("rar")))",
        ].joined(separator: "\n")
        #expect(alert.message == expected)
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    @Test func batchDiscardsPreparedStagingWhenCommitFails() async throws {
        let staging = root.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let model = try await makeModel(stagingParent: staging)
        let lib = model.store.library
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lib.path)
            try? FileManager.default.removeItem(at: root)
        }
        let tree = root.appending(path: "tree", directoryHint: .isDirectory)
        try touchFile(tree, "GAME.EXE")
        let z1 = try makeZip(tree, to: "one.zip", in: root)
        let z2 = try makeZip(tree, to: "two.zip", in: root)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lib.path)
        let queue = ImportQueue()
        await queue.add([z1, z2], model: model)?.value
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lib.path)

        #expect(model.alert != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    @Test func secondBatchAddedWhileRunningSerializesGrowsProgressAndCombinesSummary() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeModel()
        let queue = ImportQueue()

        let g1 = root.appending(path: "alpha", directoryHint: .isDirectory)
        try touchFile(g1, "ALPHA.EXE")
        let g2 = root.appending(path: "beta", directoryHint: .isDirectory)
        try touchFile(g2, "BETA.EXE")
        let bad1 = try touchFile(root, "fail1.rar")

        let g3 = root.appending(path: "gamma", directoryHint: .isDirectory)
        try touchFile(g3, "GAMMA.EXE")
        let bad2 = try touchFile(root, "fail2.7z")

        let single = URL(filePath: "/tmp/single.zip")

        final class ConcurrencyProbe: @unchecked Sendable {
            private let lock = NSLock()
            private var inFlight = 0
            private(set) var maxInFlight = 0
            func enter() {
                lock.withLock {
                    inFlight += 1
                    if inFlight > maxInFlight { maxInFlight = inFlight }
                }
            }
            func leave() {
                lock.withLock { inFlight -= 1 }
            }
        }

        let probe = ConcurrencyProbe()
        var observedLabels: [String] = []
        var secondTask: Task<Void, Never>?

        queue.itemHook = { url in
            probe.enter()
            defer { probe.leave() }
            await MainActor.run {
                if let label = queue.progress?.label { observedLabels.append(label) }
                if url == g2 {
                    secondTask = queue.add([g3, bad2], model: model)
                    if let label = queue.progress?.label { observedLabels.append(label) }
                    queue.add([single], model: model)
                }
            }
            try? await Task.sleep(for: .milliseconds(20))
        }

        let firstTask = queue.add([g1, g2, bad1], model: model)
        await firstTask?.value
        await secondTask?.value

        #expect(probe.maxInFlight == 1)
        #expect(observedLabels == [
            "Importing 1 of 3…",
            "Importing 2 of 3…",
            "Importing 2 of 5…",
            "Importing 3 of 5…",
            "Importing 4 of 5…",
            "Importing 5 of 5…",
        ])
        #expect(queue.progress == nil)
        #expect(queue.current?.url == single)
        #expect(model.store.records.map(\.game.title) == ["Alpha", "Beta", "Gamma"])
        #expect(model.selection == model.store.records.first { $0.game.title == "Alpha" }?.id)

        let alert = try #require(model.alert)
        let expected = [
            "fail1.rar: \(importErrorMessage(ImportError.unsupportedType("rar")))",
            "fail2.7z: \(importErrorMessage(ImportError.unsupportedType("7z")))",
        ].joined(separator: "\n")
        #expect(alert.message == expected)
    }
}

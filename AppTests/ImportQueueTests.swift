import Foundation
import os
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

    func makeModel(stagingParent: URL? = nil, importLocation: ImportLocationPreference = .copy,
                   verify: @escaping @Sendable (URL) throws -> Void = { _ in }) async throws -> AppModel {
        let fm = FileManager.default
        let lib = root.appending(path: "Library")
        try fm.createDirectory(at: lib, withIntermediateDirectories: true)
        let dosbox = root.appending(path: "dosbox")
        try Data("#!/bin/sh\n".utf8).write(to: dosbox)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dosbox.path)
        let prefs = Preferences(defaults: UserDefaults(suiteName: "doscrate-iq-\(UUID().uuidString)")!)
        prefs.importLocation = importLocation
        let store = LibraryStore(library: lib)
        await store.reload()
        let importer = stagingParent.map { Importer(stagingParent: $0) } ?? Importer()
        return AppModel(prefs: prefs, store: store, sessions: SessionManager(runner: FakeRunner()),
                        importer: importer, dosbox: dosbox, verifyDosbox: verify)
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
                    model.prefs.importLocation = .ask
                    #expect(queue.add([g3, bad2], model: model) == nil)
                    #expect(queue.batchPrompt?.urls == [g3, bad2])
                    secondTask = queue.confirmBatch(mode: .reference, remember: false, model: model)
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
        #expect(model.store.records.first { $0.game.title == "Alpha" }?.game.source == .managed)
        if case .referenced = model.store.records.first(where: { $0.game.title == "Gamma" })?.game.source {} else {
            Issue.record("Expected Gamma from second batch to be referenced")
        }
        #expect(model.selection == model.store.records.first { $0.game.title == "Alpha" }?.id)

        let alert = try #require(model.alert)
        let expected = [
            "fail1.rar: \(importErrorMessage(ImportError.unsupportedType("rar")))",
            "fail2.7z: \(importErrorMessage(ImportError.unsupportedType("7z")))",
        ].joined(separator: "\n")
        #expect(alert.message == expected)
    }

    @Test func preferenceDefaultIsAskAndSingleItemSheetDefaultFollowsPreference() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: "doscrate-pref-default-\(UUID().uuidString)")!
        let freshPrefs = Preferences(defaults: defaults)
        #expect(freshPrefs.importLocation == .ask)
        #expect(freshPrefs.importLocation.defaultMode == .copy)

        let model = try await makeModel(importLocation: .ask)
        let queue = ImportQueue()
        let a = URL(filePath: "/tmp/a.zip")

        queue.add([a], model: model)
        #expect(queue.current?.defaultMode == .copy)
        queue.finishCurrent()

        model.prefs.importLocation = .reference
        queue.add([a], model: model)
        #expect(queue.current?.defaultMode == .reference)
        queue.finishCurrent()

        model.prefs.importLocation = .copy
        queue.add([a], model: model)
        #expect(queue.current?.defaultMode == .copy)
        queue.finishCurrent()
    }

    @Test func batchWithAskPresentsPromptImportsNothingUntilConfirmedAndCancelImportsNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeModel(importLocation: .ask)
        let queue = ImportQueue()

        let one = root.appending(path: "keen", directoryHint: .isDirectory)
        try touchFile(one, "KEEN1.EXE")
        let two = root.appending(path: "doom", directoryHint: .isDirectory)
        try touchFile(two, "DOOM.EXE")

        let task = queue.add([one, two], model: model)
        #expect(task == nil)
        #expect(queue.current == nil)
        #expect(queue.progress == nil)
        #expect(queue.batchPrompt?.urls == [one, two])
        #expect(queue.batchPrompt?.title == "Import 2 items")
        #expect(model.store.records.isEmpty)

        queue.cancelBatch()
        #expect(queue.batchPrompt == nil)
        #expect(queue.progress == nil)
        #expect(model.store.records.isEmpty)
    }

    @Test func batchConfirmKeepInPlaceReferencesFoldersCopiesZipAndRemembersChoice() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeModel(importLocation: .ask)
        let queue = ImportQueue()

        let folder = root.appending(path: "keen", directoryHint: .isDirectory)
        try touchFile(folder, "KEEN1.EXE")

        let wolfTree = root.appending(path: "wolf-tree", directoryHint: .isDirectory)
        try touchFile(wolfTree, "WOLF3D.EXE")
        let wolfZip = try makeZip(wolfTree, to: "wolf.zip", in: root)

        let disc = try touchFile(root, "myst.iso")

        queue.add([folder, wolfZip, disc], model: model)
        #expect(queue.batchPrompt?.title == "Import 3 items")
        #expect(model.store.records.isEmpty)

        await queue.confirmBatch(mode: .reference, remember: true, model: model)?.value
        #expect(queue.batchPrompt == nil)
        #expect(queue.progress == nil)
        #expect(model.alert == nil)
        #expect(model.prefs.importLocation == .reference)
        #expect(model.store.records.count == 3)

        let keen = try #require(model.store.records.first { $0.game.title == "Keen" })
        if case .referenced = keen.game.source {} else { Issue.record("Expected Keen to be referenced") }

        let wolf = try #require(model.store.records.first { $0.game.title == "Wolf" })
        #expect(wolf.game.source == .managed)

        let myst = try #require(model.store.records.first { $0.game.title == "Myst" })
        #expect(myst.game.source == .managed)

        // With the preference now remembered as .reference, the next batch imports directly without a prompt.
        let extra1 = root.appending(path: "duke", directoryHint: .isDirectory)
        try touchFile(extra1, "DUKE.EXE")
        let extra2 = root.appending(path: "quake", directoryHint: .isDirectory)
        try touchFile(extra2, "QUAKE.EXE")

        let nextTask = queue.add([extra1, extra2], model: model)
        #expect(queue.batchPrompt == nil)
        await nextTask?.value

        let duke = try #require(model.store.records.first { $0.game.title == "Duke" })
        if case .referenced = duke.game.source {} else { Issue.record("Expected Duke to be referenced") }
    }

    @Test func batchOf25ItemsThrottlesReloadsAndSelectsFirstGame() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeModel(importLocation: .copy)
        model.store.startWatching()
        defer { model.store.stopWatching() }

        var reloadCount = 0
        model.store.onReload = { reloadCount += 1 }

        var urls: [URL] = []
        for i in 1...25 {
            let name = String(format: "game%02d", i)
            let dir = root.appending(path: name, directoryHint: .isDirectory)
            try touchFile(dir, "G\(i).EXE")
            urls.append(dir)
        }

        let queue = ImportQueue()
        await queue.add(urls, model: model)?.value

        #expect(reloadCount <= 5)
        #expect(model.store.records.count == 25)
        let first = try #require(model.store.records.first { $0.game.title == "Game01" })
        #expect(model.selection == first.id)
    }

    @Test func cancelStopsBatchAfterCurrentItemAndKeepsImportedGames() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeModel(importLocation: .copy)

        var urls: [URL] = []
        for i in 1...6 {
            let dir = root.appending(path: "game\(i)", directoryHint: .isDirectory)
            try touchFile(dir, "G\(i).EXE")
            urls.append(dir)
        }

        let queue = model.imports
        queue.itemHook = { url in
            if url.lastPathComponent == "game2" {
                await MainActor.run { model.cancelImport() }
            }
        }
        await queue.add(urls, model: model)?.value

        #expect(model.store.records.map(\.game.title).sorted() == ["Game1", "Game2"])
        #expect(queue.progress == nil)

        // The queue still works after a cancel.
        queue.itemHook = nil
        await queue.add(Array(urls[4...]), model: model)?.value
        #expect(model.store.records.count == 4)
    }

    @Test func batchEnqueuedDuringFinalReloadIsImported() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeModel(importLocation: .copy)

        var urls: [URL] = []
        for i in 1...3 {
            let dir = root.appending(path: "game\(i)", directoryHint: .isDirectory)
            try touchFile(dir, "G\(i).EXE")
            urls.append(dir)
        }

        let queue = model.imports
        let lateURL = urls[2]
        var enqueuedLate = false
        model.store.onReload = {
            // The first reload is the batch's final one; a new batch arrives while it runs.
            guard !enqueuedLate else { return }
            enqueuedLate = true
            queue.enqueue([.init(url: lateURL, mode: .copy)], model: model)
        }
        await queue.add(Array(urls[0...1]), model: model)?.value

        #expect(enqueuedLate)
        #expect(model.store.records.map(\.game.title).sorted() == ["Game1", "Game2", "Game3"])
        #expect(queue.progress == nil)
    }

    @Test func multipleAskBatchesQueuePromptsAndPreserveOthersOnConfirmOrCancel() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeModel(importLocation: .ask)
        let queue = ImportQueue()

        let a = root.appending(path: "a", directoryHint: .isDirectory); try touchFile(a, "A.EXE")
        let b = root.appending(path: "b", directoryHint: .isDirectory); try touchFile(b, "B.EXE")
        let c = root.appending(path: "c", directoryHint: .isDirectory); try touchFile(c, "C.EXE")
        let d = root.appending(path: "d", directoryHint: .isDirectory); try touchFile(d, "D.EXE")
        let e = root.appending(path: "e", directoryHint: .isDirectory); try touchFile(e, "E.EXE")
        let f = root.appending(path: "f", directoryHint: .isDirectory); try touchFile(f, "F.EXE")

        queue.add([a, b], model: model)
        queue.add([c, d], model: model)
        queue.add([e, f], model: model)
        #expect(queue.batchPrompt?.urls == [a, b])

        let t1 = queue.confirmBatch(mode: .copy, model: model)
        #expect(queue.batchPrompt?.urls == [c, d])

        queue.cancelBatch()
        #expect(queue.batchPrompt?.urls == [e, f])

        let t3 = queue.confirmBatch(mode: .reference, model: model)
        #expect(queue.batchPrompt == nil)

        await t1?.value
        await t3?.value

        #expect(model.store.records.map(\.game.title) == ["A", "B", "E", "F"])
    }

    @Test func batchWithDuplicatesSkipReplaceAndKeepBoth() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeModel(importLocation: .copy)
        let queue = ImportQueue()
        let io = CrateIO()

        // Seed library with "Keen" (managed, with a save file and launchCount = 5).
        let keenV1 = root.appending(path: "keen", directoryHint: .isDirectory)
        try touchFile(keenV1, "KEEN1.EXE")
        try Data("old-keen".utf8).write(to: keenV1.appending(path: "DATA.DAT"))
        let pSeed = try await model.importer.prepare(keenV1)
        var seeded = try await model.importer.commit(
            pSeed, mode: .copy, title: "Keen", executable: "KEEN1.EXE", into: model.store.library
        )
        seeded.game.stats.launchCount = 5
        try io.save(seeded.game, extra: [:], to: seeded.crateURL)
        let saveURL = seeded.crateURL.appending(path: "files/SAVES/GAME1.SAV")
        try FileManager.default.createDirectory(at: saveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("my-save".utf8).write(to: saveURL)
        await model.store.reload()
        let keenID = seeded.id

        // Prepare batch items: an updated "keen" folder + a new "doom" folder.
        try Data("new-keen".utf8).write(to: keenV1.appending(path: "DATA.DAT"))
        let doom = root.appending(path: "doom", directoryHint: .isDirectory)
        try touchFile(doom, "DOOM.EXE")

        // 1. Skip: even with importLocation == .copy, duplicate triggers prompt; Skip imports only Doom.
        let check1 = queue.add([keenV1, doom], model: model)
        #expect(queue.isCheckingDuplicates)
        await check1?.value
        #expect(!queue.isCheckingDuplicates)
        let prompt1 = try #require(queue.batchPrompt)
        #expect(prompt1.title == "1 of 2 items are already in your library")
        #expect(prompt1.duplicateTitles == ["Keen"])
        #expect(prompt1.matches[keenV1]?.record.id == keenID)

        await queue.confirmBatch(duplicateAction: .skip, model: model)?.value
        #expect(model.store.records.map(\.game.title) == ["Doom", "Keen"])
        #expect(try String(contentsOf: seeded.crateURL.appending(path: "files/DATA.DAT"), encoding: .utf8) == "old-keen")

        // 2. Replace: updates Keen in place (keeping id, stats, and SAVES/GAME1.SAV; no "Keen 2" crate), and adds Wolf.
        let wolf = root.appending(path: "wolf", directoryHint: .isDirectory)
        try touchFile(wolf, "WOLF3D.EXE")

        await queue.add([keenV1, wolf], model: model)?.value
        #expect(queue.batchPrompt?.duplicateTitles == ["Keen"])
        await queue.confirmBatch(duplicateAction: .replace, model: model)?.value

        #expect(model.store.records.map(\.game.title) == ["Doom", "Keen", "Wolf"])
        let keenAfterReplace = try #require(model.store.record(keenID))
        #expect(keenAfterReplace.crateURL.lastPathComponent == "Keen.doscrate")
        #expect(keenAfterReplace.game.stats.launchCount == 5)
        #expect(try String(contentsOf: keenAfterReplace.crateURL.appending(path: "files/DATA.DAT"), encoding: .utf8) == "new-keen")
        #expect(try String(contentsOf: keenAfterReplace.crateURL.appending(path: "files/SAVES/GAME1.SAV"), encoding: .utf8) == "my-save")

        // 3. Keep Both: creates a second crate ("Keen 2.doscrate").
        let quake = root.appending(path: "quake", directoryHint: .isDirectory)
        try touchFile(quake, "QUAKE.EXE")

        await queue.add([keenV1, quake], model: model)?.value
        await queue.confirmBatch(duplicateAction: .keepBoth, model: model)?.value

        let keenRecords = model.store.records.filter { $0.game.title == "Keen" }
        #expect(keenRecords.count == 2)
        #expect(Set(keenRecords.map { $0.crateURL.lastPathComponent }) == ["Keen.doscrate", "Keen 2.doscrate"])
    }

    @Test func replaceRefusesRunningGameInBatchAndSingleImport() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeModel(importLocation: .copy)
        let queue = ImportQueue()

        let keen = root.appending(path: "keen", directoryHint: .isDirectory)
        try touchFile(keen, "KEEN1.EXE")
        let pSeed = try await model.importer.prepare(keen)
        let seeded = try await model.importer.commit(
            pSeed, mode: .copy, title: "Keen", executable: "KEEN1.EXE", into: model.store.library
        )
        await model.store.reload()

        // Start Keen so it is running.
        await model.play(seeded.id)?.value
        #expect(model.sessions.running.contains(seeded.id))

        // Single-item duplicate notice check + running refusal on Replace.
        let pSingle = try await model.importer.prepare(keen)
        let match = try #require(DuplicateIndex(model.store.records).match(for: pSingle))
        #expect(ImportSheet.duplicateNotice(for: match) == "\"Keen\" is already in your library.")
        let titleMatch = DuplicateMatch(record: seeded, kind: .sameTitle)
        #expect(ImportSheet.duplicateNotice(for: titleMatch) == "A game named \"Keen\" is already in your library.")

        let replacedSingle = try await queue.finishSingleImport(
            pSingle, action: .replace, replacing: seeded, mode: .copy, title: "Keen", executable: "KEEN1.EXE", model: model
        )
        #expect(replacedSingle == nil)
        #expect(model.alert?.title == "Already running")
        model.alert = nil

        // Batch Replace while Keen is running counts Keen as a failure and still imports Duke.
        let duke = root.appending(path: "duke", directoryHint: .isDirectory)
        try touchFile(duke, "DUKE.EXE")
        await queue.add([keen, duke], model: model)?.value
        await queue.confirmBatch(duplicateAction: .replace, model: model)?.value

        #expect(model.store.records.map(\.game.title) == ["Duke", "Keen"])
        let alert = try #require(model.alert)
        #expect(alert.title == "Couldn't import 1 item")
        #expect(alert.message.contains("already running"))
    }

    @Test func replaceRefusesStartingGameInBatchAndSingleImport() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let release = DispatchSemaphore(value: 0)
        let state = OSAllocatedUnfairLock(initialState: (armed: false, entered: false))
        let model = try await makeModel(importLocation: .copy) { _ in
            let shouldBlock = state.withLock { s -> Bool in
                guard s.armed else { return false }
                s.entered = true
                return true
            }
            if shouldBlock { release.wait() }
        }
        let queue = ImportQueue()

        let keen = root.appending(path: "keen", directoryHint: .isDirectory)
        try touchFile(keen, "KEEN1.EXE")
        let pSeed = try await model.importer.prepare(keen)
        let seeded = try await model.importer.commit(
            pSeed, mode: .copy, title: "Keen", executable: "KEEN1.EXE", into: model.store.library
        )
        await model.store.reload()

        // Keen's start is still preparing in the background, reading its files.
        state.withLock { $0.armed = true }
        let start = model.play(seeded.id)
        await waitUntil { state.withLock { $0.entered } }
        #expect(model.startingIDs == [seeded.id])

        let pSingle = try await model.importer.prepare(keen)
        let replacedSingle = try await queue.finishSingleImport(
            pSingle, action: .replace, replacing: seeded, mode: .copy, title: "Keen", executable: "KEEN1.EXE", model: model
        )
        #expect(replacedSingle == nil)
        #expect(model.alert?.title == "Already running")
        model.alert = nil

        // Batch Replace counts Keen as a failure and still imports Duke.
        let duke = root.appending(path: "duke", directoryHint: .isDirectory)
        try touchFile(duke, "DUKE.EXE")
        await queue.add([keen, duke], model: model)?.value
        await queue.confirmBatch(duplicateAction: .replace, model: model)?.value
        #expect(model.store.records.map(\.game.title) == ["Duke", "Keen"])
        let alert = try #require(model.alert)
        #expect(alert.title == "Couldn't import 1 item")
        #expect(alert.message.contains("already running"))
        model.alert = nil

        release.signal()
        await start?.value
        #expect(model.sessions.running.contains(seeded.id))
    }

    @Test func subfolderScanAndImportSubfoldersRespectsChosenModeAndDuplicateAction() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeModel(importLocation: .copy)
        let queue = ImportQueue()
        let io = CrateIO()

        // Seed library with "Keen" (managed, launchCount = 3).
        let parent = root.appending(path: "pack", directoryHint: .isDirectory)
        let keen = parent.appending(path: "keen", directoryHint: .isDirectory)
        try touchFile(keen, "KEEN1.EXE")
        try Data("v1".utf8).write(to: keen.appending(path: "DATA.DAT"))
        let pSeed = try await model.importer.prepare(keen)
        var seeded = try await model.importer.commit(
            pSeed, mode: .copy, title: "Keen", executable: "KEEN1.EXE", into: model.store.library
        )
        seeded.game.stats.launchCount = 3
        try io.save(seeded.game, extra: [:], to: seeded.crateURL)
        await model.store.reload()

        // Update Keen's file so it is detected as a duplicate by title, plus add Doom subfolder,
        // a zip archive, a cue+iso pair, a non-game subfolder, a .doscrate folder, and hidden files.
        try Data("v2".utf8).write(to: keen.appending(path: "DATA.DAT"))
        let doom = parent.appending(path: "doom", directoryHint: .isDirectory)
        try touchFile(doom, "DOOM.EXE")
        let docs = parent.appending(path: "docs", directoryHint: .isDirectory)
        try touchFile(docs, "README.TXT")
        let fakeCrate = parent.appending(path: "SkipMe.doscrate", directoryHint: .isDirectory)
        try touchFile(fakeCrate, "GAME.EXE")
        try touchFile(parent, ".hidden/HIDE.EXE")
        try touchFile(parent, "._ghost.zip")

        let wolfSrc = root.appending(path: "wolf-src", directoryHint: .isDirectory)
        try touchFile(wolfSrc, "WOLF3D.EXE")
        _ = try makeZip(wolfSrc, to: "wolf.zip", in: parent)

        try touchFile(parent, "track1.bin")
        let cueURL = try touchFile(parent, "disc.cue")
        try Data("FILE \"track1.bin\" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n".utf8).write(to: cueURL)
        try touchFile(parent, "disc.iso")

        let scan1 = ImportQueue.scanFolder(parent, in: model.store.records)
        #expect(scan1.urls.map(\.lastPathComponent) == ["disc.cue", "doom", "keen", "wolf.zip"])
        #expect(scan1.hasDuplicates)
        #expect(scan1.duplicateCount == 1)
        #expect(scan1.duplicateTitles == ["Keen"])
        let scannedKeen = try #require(scan1.urls.first { $0.lastPathComponent == "keen" })
        #expect(scan1.matches[scannedKeen]?.record.id == seeded.id)

        // 1. Import subfolders with mode = .reference and duplicateAction = .skip:
        //    - Doom subfolder is referenced in place
        //    - wolf.zip and disc.cue are copied into the library
        //    - Keen duplicate is skipped
        await queue.importSubfolders(scan1, mode: .reference, duplicateAction: .skip, model: model)?.value

        #expect(model.store.records.map(\.game.title) == ["Disc", "Doom", "Keen", "Wolf"])
        let doomRec = try #require(model.store.records.first { $0.game.title == "Doom" })
        if case .referenced = doomRec.game.source {} else { Issue.record("Expected Doom to be referenced") }
        let wolfRec = try #require(model.store.records.first { $0.game.title == "Wolf" })
        #expect(wolfRec.game.source == .managed)
        let discRec = try #require(model.store.records.first { $0.game.title == "Disc" })
        #expect(discRec.game.source == .managed)
        #expect(try String(contentsOf: seeded.crateURL.appending(path: "files/DATA.DAT"), encoding: .utf8) == "v1")

        // 2. Re-scan and import with duplicateAction = .replace (replacing Keen with v2 while keeping launchCount = 3).
        let scan2 = ImportQueue.scanFolder(parent, in: model.store.records)
        #expect(scan2.duplicateCount == 4)
        let keenOnlyScan = ImportQueue.SubfolderScan(
            urls: [scannedKeen],
            matches: [scannedKeen: try #require(scan2.matches[scannedKeen])]
        )
        await queue.importSubfolders(keenOnlyScan, mode: .copy, duplicateAction: .replace, model: model)?.value

        let keenAfter = try #require(model.store.record(seeded.id))
        #expect(keenAfter.game.stats.launchCount == 3)
        #expect(try String(contentsOf: keenAfter.crateURL.appending(path: "files/DATA.DAT"), encoding: .utf8) == "v2")
    }

    @Test func batchReplaceBlocksPlayWhileInProgress() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeModel()
        let queue = model.imports

        let keen = root.appending(path: "keen", directoryHint: .isDirectory)
        try touchFile(keen, "KEEN1.EXE")
        let pSeed = try await model.importer.prepare(keen)
        let seeded = try await model.importer.commit(
            pSeed, mode: .copy, title: "Keen", executable: "KEEN1.EXE", into: model.store.library
        )
        await model.store.reload()

        let state = OSAllocatedUnfairLock(initialState: (entered: false, released: false))
        queue.itemHook = { _ in
            state.withLock { $0.entered = true }
            while !state.withLock({ $0.released }) {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        let task = queue.enqueue(
            [ImportQueue.BatchEntry(url: keen, mode: .copy, replacing: seeded.id)],
            model: model
        )
        await waitUntil { state.withLock { $0.entered } }

        #expect(queue.replacingIDs.contains(seeded.id))
        #expect(model.play(seeded.id) == nil)
        #expect(
            RetroLibraryView.playTarget(
                selected: [seeded.id],
                running: [],
                starting: [],
                pendingRemoval: [],
                replacing: queue.replacingIDs
            ) == nil
        )

        state.withLock { $0.released = true }
        await task?.value
        #expect(queue.replacingIDs.isEmpty)
    }

    @Test func singleAndBatchImportsRevealAndSelectGameWhenHiddenBySearchOrFilters() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeModel(importLocation: .copy)
        let queue = model.imports

        // 1. Single import while sidebar filter (.favorites), metadata filters, and non-matching search are active.
        model.query.filter = .favorites
        model.query.genre = "RPG"
        model.query.year = 1993
        model.query.publisher = "Origin"
        model.query.developer = "Looking Glass"
        model.query.search = "Ultima"
        model.query.sort = .year

        let keen = root.appending(path: "keen", directoryHint: .isDirectory)
        try touchFile(keen, "KEEN1.EXE")
        let pKeen = try await model.importer.prepare(keen)
        let keenRecord = try #require(
            try await queue.finishSingleImport(
                pKeen, action: .keepBoth, mode: .copy, title: "Commander Keen", executable: "KEEN1.EXE", model: model
            )
        )

        #expect(model.selection == keenRecord.id)
        #expect(model.query.filter == .all)
        #expect(model.query.genre == nil)
        #expect(model.query.year == nil)
        #expect(model.query.publisher == nil)
        #expect(model.query.developer == nil)
        #expect(model.query.search.isEmpty)
        #expect(model.query.sort == .year)
        #expect(model.query.apply(to: model.store.records, now: Date()).map(\.id).contains(keenRecord.id))

        // 2. Single import when search matches the newly imported game: matching search is preserved,
        //    while hiding sidebar filter (.recent) is cleared.
        model.query.filter = .recent
        model.query.search = "Doom"
        let doom = root.appending(path: "doom", directoryHint: .isDirectory)
        try touchFile(doom, "DOOM.EXE")
        let pDoom = try await model.importer.prepare(doom)
        let doomRecord = try #require(
            try await queue.finishSingleImport(
                pDoom, action: .keepBoth, mode: .copy, title: "Doom", executable: "DOOM.EXE", model: model
            )
        )

        #expect(model.selection == doomRecord.id)
        #expect(model.query.filter == .all)
        #expect(model.query.search == "Doom")
        #expect(model.query.apply(to: model.store.records, now: Date()).map(\.id) == [doomRecord.id])

        // 3. Batch import while tag filter and non-matching search hide the first imported game.
        model.query.filter = .tag("Sci-Fi")
        model.query.search = "Nonexistent"
        let wolf = root.appending(path: "wolf", directoryHint: .isDirectory)
        try touchFile(wolf, "WOLF3D.EXE")
        let duke = root.appending(path: "duke", directoryHint: .isDirectory)
        try touchFile(duke, "DUKE.EXE")

        await queue.add([wolf, duke], model: model)?.value
        let wolfRecord = try #require(model.store.records.first { $0.game.title == "Wolf" })
        #expect(model.selection == wolfRecord.id)
        #expect(model.query.filter == .all)
        #expect(model.query.search.isEmpty)
        #expect(model.query.apply(to: model.store.records, now: Date()).map(\.id).contains(wolfRecord.id))
    }

    @Test func startSingleImportAddsGameImmediatelyShowsSpinnerStateAndPopulatesInBackground() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeModel()
        let queue = model.imports

        let folder = root.appending(path: "keen", directoryHint: .isDirectory)
        try touchFile(folder, "KEEN1.EXE")
        try Data("episode-1".utf8).write(to: folder.appending(path: "DATA.DAT"))

        let prepared = try await model.importer.prepare(folder)
        let state = OSAllocatedUnfairLock(initialState: (entered: false, released: false))
        queue.singlePopulateHook = { _ in
            state.withLock { $0.entered = true }
            while !state.withLock({ $0.released }) {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        let started = try #require(
            try queue.startSingleImport(
                prepared,
                action: .keepBoth,
                mode: .copy,
                title: "Commander Keen",
                executable: "KEEN1.EXE",
                model: model
            )
        )
        let id = started.record.id

        // Record is added to the library and selected right away before the background copy finishes.
        #expect(model.store.record(id)?.game.title == "Commander Keen")
        #expect(model.selection == id)
        #expect(queue.importingIDs.contains(id))
        #expect(model.isActive(id))
        #expect(model.play(id) == nil)
        #expect(LibraryView.statusBarLeadingText(for: model) == "Importing Commander Keen…")
        #expect(RetroStatusBar.leadingText(for: model) == "Importing Commander Keen…")
        #expect(
            RetroBadge.badges(
                for: started.record,
                running: [],
                starting: [],
                importing: queue.importingIDs
            ) == [.importing]
        )
        #expect(
            RetroLibraryView.playTarget(
                selected: [id],
                running: [],
                starting: [],
                pendingRemoval: [],
                replacing: [],
                importing: queue.importingIDs
            ) == nil
        )

        await waitUntil { state.withLock { $0.entered } }
        state.withLock { $0.released = true }
        await started.task.value

        #expect(!queue.importingIDs.contains(id))
        #expect(!model.isActive(id))
        #expect(LibraryView.statusBarLeadingText(for: model) == nil)
        #expect(
            try String(
                contentsOf: started.record.crateURL.appending(path: "files/DATA.DAT"),
                encoding: .utf8
            ) == "episode-1"
        )
        #expect(!CrateIO().isIncompleteImport(started.record.crateURL))

        // Automatic metadata fetch runs after the background copy finishes and importingIDs is cleared.
        await waitUntil { model.metadata.unmatched.contains(id) }
        #expect(model.metadata.unmatched.contains(id))
    }

    @Test func terminationWaitsForActiveSingleImportAndCrashMarkerIsCleanedOnScan() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeModel()
        let queue = model.imports
        let delegate = AppTerminationDelegate()
        delegate.model = model

        let folder = root.appending(path: "keen", directoryHint: .isDirectory)
        try touchFile(folder, "KEEN1.EXE")
        try Data("full-copy".utf8).write(to: folder.appending(path: "DATA.DAT"))

        let prepared = try await model.importer.prepare(folder)
        let state = OSAllocatedUnfairLock(initialState: (entered: false, released: false))
        queue.singlePopulateHook = { _ in
            state.withLock { $0.entered = true }
            while !state.withLock({ $0.released }) {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        let started = try #require(
            try queue.startSingleImport(
                prepared,
                action: .keepBoth,
                mode: .copy,
                title: "Commander Keen",
                executable: "KEEN1.EXE",
                model: model
            )
        )
        #expect(CrateIO().isIncompleteImport(started.record.crateURL))
        #expect(!CrateIO().isAbandonedImport(started.record.crateURL))
        await waitUntil { state.withLock { $0.entered } }

        // A store.reload() while the current process's import is still active keeps the active crate intact.
        await model.store.reload()
        #expect(model.store.record(started.record.id) != nil)
        #expect(FileManager.default.fileExists(atPath: started.record.crateURL.path))

        var terminated = false
        let reply = delegate.prepareForTermination { ok in
            terminated = ok
        }
        #expect(reply == .terminateLater)
        #expect(!terminated)

        state.withLock { $0.released = true }
        await waitUntil { terminated }
        #expect(terminated)
        #expect(!CrateIO().isIncompleteImport(started.record.crateURL))

        // If a crash in a previous process leaves an unfinished placeholder crate on disk, scan cleans it up.
        let orphanSource = root.appending(path: "orphan", directoryHint: .isDirectory)
        try touchFile(orphanSource, "ORPHAN.EXE")
        let pOrphan = try await model.importer.prepare(orphanSource)
        let orphanPlaceholder = try model.importer.createCratePlaceholder(
            pOrphan, mode: .copy, title: "Orphan", executable: "ORPHAN.EXE", into: model.store.library
        )
        model.importer.discard(pOrphan)
        try Data("stale-session".utf8).write(
            to: orphanPlaceholder.crateURL.appending(path: CrateIO.importingMarkerFileName),
            options: .atomic
        )
        #expect(CrateIO().isAbandonedImport(orphanPlaceholder.crateURL))

        let scanned = await CrateIO().scan(library: model.store.library)
        #expect(!scanned.map(\.id).contains(orphanPlaceholder.id))
        #expect(!FileManager.default.fileExists(atPath: orphanPlaceholder.crateURL.path))

        // Disc image import persists media to the destination crate even if the active library changes mid-copy.
        let iso = root.appending(path: "disc.iso")
        try Data("iso-bytes".utf8).write(to: iso)
        let pISO = try await model.importer.prepare(iso)
        let isoState = OSAllocatedUnfairLock(initialState: (entered: false, released: false))
        queue.singlePopulateHook = { _ in
            isoState.withLock { $0.entered = true }
            while !isoState.withLock({ $0.released }) {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        let isoStarted = try #require(
            try queue.startSingleImport(
                pISO, action: .keepBoth, mode: .copy, title: "Disc Game", executable: nil, model: model
            )
        )
        await waitUntil { isoState.withLock { $0.entered } }
        let otherLib = root.appending(path: "other-lib", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: otherLib, withIntermediateDirectories: true)
        model.store.library = otherLib
        isoState.withLock { $0.released = true }
        await isoStarted.task.value

        let reloadedFromOriginalCrate = CrateIO().loadRecord(at: isoStarted.record.crateURL)
        #expect(reloadedFromOriginalCrate.game.media == [MediaImage(relativePath: "media/disc.iso", kind: .cdrom)])
    }

    @Test func backgroundReplacePreservesPendingAndConcurrentEdits() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeModel()
        let queue = model.imports

        let folder = root.appending(path: "keen", directoryHint: .isDirectory)
        try touchFile(folder, "KEEN1.EXE")
        try Data("v1".utf8).write(to: folder.appending(path: "DATA.DAT"))

        let p1 = try await model.importer.prepare(folder)
        let initial = try #require(
            try await queue.finishSingleImport(
                p1, action: .keepBoth, mode: .copy, title: "Keen", executable: "KEEN1.EXE", model: model
            )
        )

        // Register a pending draft write before starting replacement.
        model.setPendingWrite(initial.id, owner: "draft") {
            guard var g = model.store.record(initial.id)?.game else { return }
            g.notes = "Pending note"
            try? model.store.save(g)
        }

        try Data("v2".utf8).write(to: folder.appending(path: "DATA.DAT"))
        let p2 = try await model.importer.prepare(folder)
        let state = OSAllocatedUnfairLock(initialState: (entered: false, released: false))
        queue.singlePopulateHook = { _ in
            state.withLock { $0.entered = true }
            while !state.withLock({ $0.released }) {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        let started = try #require(
            try queue.startSingleImport(
                p2,
                action: .replace,
                replacing: initial,
                mode: .copy,
                title: "Keen",
                executable: "KEEN1.EXE",
                model: model
            )
        )
        await waitUntil { state.withLock { $0.entered } }

        // Mutate and save favorite while the background replacement is copying files.
        var concurrent = try #require(model.store.record(initial.id)?.game)
        #expect(concurrent.notes == "Pending note")
        concurrent.isFavorite = true
        try model.store.save(concurrent)

        state.withLock { $0.released = true }
        await started.task.value

        let finalGame = try #require(model.store.record(initial.id)?.game)
        #expect(finalGame.notes == "Pending note")
        #expect(finalGame.isFavorite == true)
        #expect(
            try String(
                contentsOf: initial.crateURL.appending(path: "files/DATA.DAT"),
                encoding: .utf8
            ) == "v2"
        )
    }
}

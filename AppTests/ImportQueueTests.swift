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

    func makeModel(stagingParent: URL? = nil, importLocation: ImportLocationPreference = .copy) async throws -> AppModel {
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
        model.play(seeded.id)
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
}

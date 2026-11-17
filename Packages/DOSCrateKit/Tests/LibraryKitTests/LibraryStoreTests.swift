import Foundation
import Testing
@testable import LibraryKit

@MainActor
struct LibraryStoreTests {
    let io = CrateIO()

    func makeLibrary(titles: [String]) throws -> (URL, [URL]) {
        let lib = try makeTempDir()
        var crates: [URL] = []
        for title in titles {
            let crate = try io.makeCrate(title: title, in: lib)
            try io.save(Game(title: title, source: .managed), extra: [:], to: crate)
            crates.append(crate)
        }
        return (lib, crates)
    }

    func rewrite(_ crate: URL, _ edit: (inout [String: Any]) -> Void) throws {
        let file = crate.appending(path: "game.json")
        var obj = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        edit(&obj)
        try JSONSerialization.data(withJSONObject: obj).write(to: file)
    }

    @Test func saveThenReload() async throws {
        let (lib, _) = try makeLibrary(titles: ["Keen"])
        defer { try? FileManager.default.removeItem(at: lib) }
        let store = LibraryStore(library: lib)
        await store.reload()
        var game = try #require(store.records.first).game
        game.title = "Keen 2"
        game.isFavorite = true
        try store.save(game)
        #expect(store.record(game.id)?.game.title == "Keen 2")
        await store.reload()
        #expect(store.records.first?.game == game)
    }

    @Test func reloadPicksUpExternalEdit() async throws {
        let (lib, crates) = try makeLibrary(titles: ["Keen"])
        defer { try? FileManager.default.removeItem(at: lib) }
        let store = LibraryStore(library: lib)
        await store.reload()
        try rewrite(crates[0]) { $0["title"] = "Renamed" }
        await store.reload()
        #expect(store.records.first?.game.title == "Renamed")
    }

    @Test func saveKeepsExtraAfterExternalEdit() async throws {
        let (lib, crates) = try makeLibrary(titles: ["Keen"])
        defer { try? FileManager.default.removeItem(at: lib) }
        let store = LibraryStore(library: lib)
        await store.reload()
        try rewrite(crates[0]) { $0["futureField"] = ["a": 1] }
        var game = try #require(store.records.first).game
        game.notes = "edited"
        try store.save(game)
        let onDisk = try GameFileCodec.decode(Data(contentsOf: crates[0].appending(path: "game.json")))
        #expect(onDisk.extra["futureField"] == .object(["a": .number(1)]))
        #expect(onDisk.game.notes == "edited")
    }

    @Test func removedCrateDisappearsOnReload() async throws {
        let (lib, crates) = try makeLibrary(titles: ["A", "B"])
        defer { try? FileManager.default.removeItem(at: lib) }
        let store = LibraryStore(library: lib)
        await store.reload()
        #expect(store.records.count == 2)
        try FileManager.default.removeItem(at: crates[0])
        await store.reload()
        #expect(store.records.map(\.game.title) == ["B"])
    }

    @Test func removeTrashesManagedFiles() async throws {
        let (lib, crates) = try makeLibrary(titles: ["Gone \(UUID().uuidString)"])
        defer { try? FileManager.default.removeItem(at: lib) }
        let store = LibraryStore(library: lib)
        await store.reload()
        let id = try #require(store.records.first).id
        try store.remove(id, trashFiles: true)
        #expect(!FileManager.default.fileExists(atPath: crates[0].path))
        #expect(store.records.isEmpty)
    }

    @Test func watcherReloadsAfterExternalChange() async throws {
        let (lib, _) = try makeLibrary(titles: ["A"])
        defer { try? FileManager.default.removeItem(at: lib) }
        let store = LibraryStore(library: lib)
        await store.reload()
        store.startWatching()
        defer { store.stopWatching() }
        try await Task.sleep(for: .milliseconds(500))
        let crate = try io.makeCrate(title: "B", in: lib)
        try io.save(Game(title: "B", source: .managed), extra: [:], to: crate)
        for _ in 0..<50 where store.records.count < 2 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(store.records.count == 2)
    }

    @Test func changesIgnoredWhileSuppressedReloadOnceResumed() async throws {
        let (lib, _) = try makeLibrary(titles: ["A"])
        defer { try? FileManager.default.removeItem(at: lib) }
        let store = LibraryStore(library: lib)
        await store.reload()
        store.startWatching()
        defer { store.stopWatching() }
        try await Task.sleep(for: .milliseconds(500))

        store.suppressWatcher()
        let crate = try io.makeCrate(title: "B", in: lib)
        try io.save(Game(title: "B", source: .managed), extra: [:], to: crate)
        try await Task.sleep(for: .milliseconds(1000))
        #expect(store.records.count == 1)

        // The change was ignored, so resuming reloads without waiting for another event.
        store.resumeWatcher()
        for _ in 0..<50 where store.records.count < 2 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(store.records.count == 2)
    }

    @Test func saveRefusesReadOnlyRecords() async throws {
        let (lib, crates) = try makeLibrary(titles: ["Future"])
        defer { try? FileManager.default.removeItem(at: lib) }
        try rewrite(crates[0]) { $0["schemaVersion"] = 2 }
        let before = try Data(contentsOf: crates[0].appending(path: "game.json"))
        let store = LibraryStore(library: lib)
        await store.reload()
        var game = try #require(store.records.first).game
        game.notes = "edited"
        #expect(throws: LibraryError.readOnly) { try store.save(game) }
        #expect(try Data(contentsOf: crates[0].appending(path: "game.json")) == before)
    }

    func makeReferenced(in lib: URL) throws -> (crate: URL, source: URL) {
        let source = lib.deletingLastPathComponent().appending(path: "src-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: source.appending(path: "GAME.EXE"))
        let crate = try io.makeCrate(title: "Ref \(UUID().uuidString)", in: lib)
        try io.save(Game(title: "Ref", source: .referenced(path: source.path, bookmark: CrateIO.makeBookmark(for: source))),
                    extra: [:], to: crate)
        return (crate, source)
    }

    @Test func removeReferencedFromLibraryKeepsSourceAndTrashesCrate() async throws {
        let lib = try makeTempDir()
        let (crate, source) = try makeReferenced(in: lib)
        defer { try? FileManager.default.removeItem(at: lib); try? FileManager.default.removeItem(at: source) }
        let store = LibraryStore(library: lib)
        await store.reload()
        try store.remove(try #require(store.records.first).id, trashFiles: false)
        #expect(!FileManager.default.fileExists(atPath: crate.path))
        #expect(FileManager.default.fileExists(atPath: source.appending(path: "GAME.EXE").path))
        #expect(store.records.isEmpty)
    }

    @Test func removeReferencedWithFilesTrashesSourceToo() async throws {
        let lib = try makeTempDir()
        let (crate, source) = try makeReferenced(in: lib)
        defer { try? FileManager.default.removeItem(at: lib); try? FileManager.default.removeItem(at: source) }
        let store = LibraryStore(library: lib)
        await store.reload()
        try store.remove(try #require(store.records.first).id, trashFiles: true)
        #expect(!FileManager.default.fileExists(atPath: crate.path))
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test func removeSeveralKeepsReferencedFoldersUnlessAskedAndReportsFailures() async throws {
        let (lib, _) = try makeLibrary(titles: ["Keen", "Doom"])
        let (refCrate, source) = try makeReferenced(in: lib)
        let (refCrate2, source2) = try makeReferenced(in: lib)
        defer {
            for url in [lib, source, source2] { try? FileManager.default.removeItem(at: url) }
        }
        let store = LibraryStore(library: lib)
        await store.reload()
        let keen = try #require(store.records.first { $0.game.title == "Keen" })
        let refs = store.records.filter { if case .referenced = $0.game.source { true } else { false } }
        #expect(refs.count == 2)
        let ref1 = try #require(refs.first { $0.crateURL.standardizedFileURL == refCrate.standardizedFileURL })
        let ref2 = try #require(refs.first { $0.crateURL.standardizedFileURL == refCrate2.standardizedFileURL })

        // Without trashFiles: crates go, the referenced folder stays; an unknown id is ignored.
        var steps: [String] = []
        let failures = await store.remove([keen.id, ref1.id, UUID()], trashFiles: false) { done, total in
            steps.append("\(done)/\(total)")
        }
        #expect(failures.isEmpty)
        #expect(steps == ["2/2"])
        #expect(!store.isWatcherSuppressed)
        #expect(store.records.map(\.game.title).sorted() == ["Doom", "Ref"])
        #expect(!FileManager.default.fileExists(atPath: refCrate.path))
        #expect(FileManager.default.fileExists(atPath: source.appending(path: "GAME.EXE").path))

        // With trashFiles the referenced folder goes too.
        let more = await store.remove([ref2.id], trashFiles: true)
        #expect(more.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: source2.path))
        #expect(store.records.map(\.game.title) == ["Doom"])
    }

    @Test func overlappingSuppressionsKeepTheWatcherOffUntilTheLastEnds() async throws {
        let (lib, _) = try makeLibrary(titles: ["Keen", "Doom"])
        defer { try? FileManager.default.removeItem(at: lib) }
        let store = LibraryStore(library: lib)
        await store.reload()
        let keen = try #require(store.records.first { $0.game.title == "Keen" })

        // A batch import is running when a removal starts, and ends before the removal does.
        store.suppressWatcher()
        var importEnded = false
        let failures = await store.remove([keen.id], trashFiles: false) { _, _ in
            store.resumeWatcher()
            importEnded = true
            #expect(store.isWatcherSuppressed)
        }
        #expect(failures.isEmpty)
        #expect(importEnded)
        #expect(!store.isWatcherSuppressed)

        // An unmatched resume can't drive the count below zero.
        store.resumeWatcher()
        store.suppressWatcher()
        #expect(store.isWatcherSuppressed)
        store.resumeWatcher()
        #expect(!store.isWatcherSuppressed)
    }

    @Test func scanStartedBeforeASaveCannotOverwriteIt() async throws {
        let (lib, _) = try makeLibrary(titles: ["Keen"])
        defer { try? FileManager.default.removeItem(at: lib) }
        let gate = Gate()
        let io = self.io
        let store = LibraryStore(library: lib, io: io) { library in
            let records = await io.scan(library: library)
            await gate.arriveAndWait()
            return records
        }
        let initial = Task { await store.reload() }
        await gate.waitForArrival()
        await gate.open()
        await initial.value
        var game = try #require(store.records.first).game

        let stale = Task { await store.reload() }
        await gate.waitForArrival()
        game.title = "Saved While Scanning"
        try store.save(game)
        await gate.open()
        await stale.value
        #expect(store.records.first?.game.title == "Saved While Scanning")
    }

    @Test func cacheAndFilesChangesAreIgnored() throws {
        let lib = URL(filePath: "/Users/x/DOSCrate Library", directoryHint: .isDirectory)
        #expect(!LibraryStore.isRelevantChange("/Users/x/DOSCrate Library/Keen.doscrate/.cache/logs/a.log", library: lib))
        #expect(!LibraryStore.isRelevantChange("/Users/x/DOSCrate Library/Keen.doscrate/files/SAVE.DAT", library: lib))
        #expect(LibraryStore.isRelevantChange("/Users/x/DOSCrate Library/Keen.doscrate/game.json", library: lib))
        #expect(LibraryStore.isRelevantChange("/Users/x/DOSCrate Library/New.doscrate", library: lib))
        #expect(LibraryStore.isRelevantChange("/Users/x/DOSCrate Library", library: lib))
        #expect(LibraryStore.isRelevantChange("/Users/x/DOSCrate Library/Keen.doscrate/media/files", library: lib))

        let refs: Set<String> = ["/Volumes/Games/DOOM"]
        #expect(LibraryStore.isHealthRelevantChange("/Users/x/DOSCrate Library/Keen.doscrate/files/KEEN.EXE", library: lib, referencedRoots: refs))
        #expect(LibraryStore.isHealthRelevantChange("/Volumes/Games/DOOM/DOOM.EXE", library: lib, referencedRoots: refs))
        #expect(LibraryStore.isHealthRelevantChange("/Volumes/Games/DOOM", library: lib, referencedRoots: refs))
        #expect(!LibraryStore.isHealthRelevantChange("/Users/x/DOSCrate Library/Keen.doscrate/.cache/logs/a.log", library: lib, referencedRoots: refs))
        #expect(!LibraryStore.isHealthRelevantChange("/Volumes/Games/Other/OTHER.EXE", library: lib, referencedRoots: refs))
    }

    @Test func watcherRefreshesHealthWhenManagedOrReferencedFilesChange() async throws {
        let lib = try makeTempDir()
        let extSource = lib.deletingLastPathComponent().appending(path: "ext-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: lib)
            try? FileManager.default.removeItem(at: extSource)
        }

        let managedCrate = try io.makeCrate(title: "Keen", in: lib)
        let managedFiles = managedCrate.appending(path: "files", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: managedFiles, withIntermediateDirectories: true)
        let managedExe = managedFiles.appending(path: "KEEN.EXE")
        try Data("exe".utf8).write(to: managedExe)
        var managedGame = Game(title: "Keen", source: .managed)
        managedGame.launch.executable = "KEEN.EXE"
        try io.save(managedGame, extra: [:], to: managedCrate)

        try FileManager.default.createDirectory(at: extSource, withIntermediateDirectories: true)
        let refExe = extSource.appending(path: "DOOM.EXE")
        try Data("exe".utf8).write(to: refExe)
        let refCrate = try io.makeCrate(title: "Doom", in: lib)
        var refGame = Game(title: "Doom", source: .referenced(path: extSource.path, bookmark: try CrateIO.makeBookmark(for: extSource)))
        refGame.launch.executable = "DOOM.EXE"
        try io.save(refGame, extra: [:], to: refCrate)

        let store = LibraryStore(library: lib)
        await store.reload()
        #expect(store.record(managedGame.id)?.needsAttention == false)
        #expect(store.record(refGame.id)?.needsAttention == false)

        var reloads = 0
        store.onReload = { reloads += 1 }
        store.startWatching()
        defer { store.stopWatching() }
        try await Task.sleep(for: .milliseconds(500))

        // Deleting a managed game's executable inside `files/` updates needsAttention without a full library reload.
        try FileManager.default.removeItem(at: managedExe)
        for _ in 0..<50 where store.record(managedGame.id)?.needsAttention == false {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(store.record(managedGame.id)?.needsAttention == true)
        #expect(reloads == 0)

        // Restoring the managed executable clears needsAttention.
        try Data("exe".utf8).write(to: managedExe)
        for _ in 0..<50 where store.record(managedGame.id)?.needsAttention == true {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(store.record(managedGame.id)?.needsAttention == false)
        #expect(reloads == 0)

        // Deleting and restoring a referenced game's folder updates status and needsAttention in the background.
        try FileManager.default.removeItem(at: extSource)
        for _ in 0..<50 where store.record(refGame.id)?.needsAttention == false {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(store.record(refGame.id)?.status == .missingSource)
        #expect(store.record(refGame.id)?.needsAttention == true)

        try FileManager.default.createDirectory(at: extSource, withIntermediateDirectories: true)
        try Data("exe".utf8).write(to: refExe)
        for _ in 0..<50 where store.record(refGame.id)?.needsAttention == true {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(store.record(refGame.id)?.status == .ok)
        #expect(store.record(refGame.id)?.needsAttention == false)
    }
}

/// Lets a test hold a scan open until it says so.
actor Gate {
    private var arrivals = 0
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        arrivals += 1
        arrivalWaiters.forEach { $0.resume() }
        arrivalWaiters = []
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitForArrival() async {
        if arrivals > 0 { arrivals -= 1; return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
        arrivals -= 1
    }

    func open() {
        openWaiters.forEach { $0.resume() }
        openWaiters = []
    }
}

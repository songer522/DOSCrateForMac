import Foundation
import ImportKit
import LauncherKit
import LibraryKit
import MetadataKit
import Testing
@testable import DOSCrate

final class StubMetadataProvider: MetadataProviding, @unchecked Sendable {
    private let lock = NSLock()
    var records: [LaunchBoxRecord]
    var storedDownloadedAt: Date?
    var shouldFailEnsureReady = false
    var artAllFailed = false
    var ensureReadyGate: (@Sendable () async -> Void)?
    var downloadGate: (@Sendable (URL) async -> Void)?
    private(set) var ensureReadyCalls = 0
    private(set) var refreshCalls = 0
    private(set) var downloadCalls = 0

    init(records: [LaunchBoxRecord] = [], downloadedAt: Date? = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.records = records
        self.storedDownloadedAt = downloadedAt
    }

    var downloadedAt: Date? {
        get async {
            lock.withLock { storedDownloadedAt }
        }
    }

    func ensureReady(onPhase: @escaping @Sendable (LaunchBoxIndexStore.Phase) -> Void) async throws -> [LaunchBoxRecord] {
        let gate = lock.withLock { () -> (@Sendable () async -> Void)? in
            ensureReadyCalls += 1
            return ensureReadyGate
        }
        if let gate {
            await gate()
        }
        let fail = lock.withLock { shouldFailEnsureReady }
        if fail {
            onPhase(.failed("network down"))
            throw LaunchBoxError.download("network down")
        }
        onPhase(.ready)
        return lock.withLock { records }
    }

    func refresh(onPhase: @escaping @Sendable (LaunchBoxIndexStore.Phase) -> Void) async throws -> [LaunchBoxRecord] {
        lock.withLock { refreshCalls += 1 }
        return try await ensureReady(onPhase: onPhase)
    }

    func download(_ art: [ArtKind: URL], into crate: URL, mode: ApplyMode) async -> ArtResult {
        let gate = lock.withLock { () -> (@Sendable (URL) async -> Void)? in
            downloadCalls += 1
            return downloadGate
        }
        if let gate {
            await gate(crate)
        }
        if Task.isCancelled {
            return ArtResult()
        }
        let forceFail = lock.withLock { artAllFailed }
        if forceFail || !FileManager.default.isWritableFile(atPath: crate.path) {
            return ArtResult(written: [], failed: Set(art.keys))
        }
        let io = CrateIO()
        var written = Set<ArtKind>()
        var failed = Set<ArtKind>()
        for kind in art.keys {
            let dest = kind.fileURL(in: crate, io: io)
            if mode == .fillEmpty, FileManager.default.fileExists(atPath: dest.path) {
                continue
            }
            do {
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("png".utf8).write(to: dest)
                written.insert(kind)
            } catch {
                failed.insert(kind)
            }
        }
        return ArtResult(written: written, failed: failed)
    }
}

@MainActor
@Suite struct MetadataCoordinatorTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "metacoord-\(UUID().uuidString)")
    let io = CrateIO()
    let runner = FakeRunner()

    static let sampleRecords: [LaunchBoxRecord] = [
        LaunchBoxRecord(
            id: 101,
            name: "Doom",
            releaseYear: 1993,
            developer: "id Software",
            publisher: "id Software",
            genres: ["Shooter"],
            overview: "Fight demons on Mars.",
            images: [
                LaunchBoxImage(type: "Box - Front", fileName: "doom-front.png"),
                LaunchBoxImage(type: "Box - Back", fileName: "doom-back.png"),
            ]
        ),
        LaunchBoxRecord(
            id: 201,
            name: "Gold Box Companion",
            releaseYear: 1992
        ),
        LaunchBoxRecord(
            id: 202,
            name: "Gold Box Collection",
            releaseYear: 1992
        ),
    ]

    func makeEnv(
        title: String = "Doom",
        records: [LaunchBoxRecord] = Self.sampleRecords,
        fetchOnImport: Bool = true
    ) async throws -> (AppModel, StubMetadataProvider, UUID) {
        let fm = FileManager.default
        let lib = root.appending(path: "Library", directoryHint: .isDirectory)
        try fm.createDirectory(at: lib, withIntermediateDirectories: true)

        let crate = try io.makeCrate(title: title, in: lib)
        var game = Game(title: title, source: .managed)
        game.launch.executable = "GAME.EXE"
        try io.save(game, extra: [:], to: crate)
        let exeURL = crate.appending(path: "files/GAME.EXE")
        try fm.createDirectory(at: exeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: exeURL)

        let dosbox = root.appending(path: "dosbox")
        try Data("#!/bin/sh\n".utf8).write(to: dosbox)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dosbox.path)

        let prefs = Preferences(defaults: UserDefaults(suiteName: "doscrate-mc-\(UUID().uuidString)")!)
        prefs.fetchMetadataOnImport = fetchOnImport
        let store = LibraryStore(library: lib)
        await store.reload()

        let provider = StubMetadataProvider(records: records)
        let coordinator = MetadataCoordinator(provider: provider, prefs: prefs)
        let model = AppModel(
            prefs: prefs,
            store: store,
            sessions: SessionManager(runner: runner),
            importer: Importer(),
            dosbox: dosbox,
            verifyDosbox: { _ in },
            metadata: coordinator
        )
        return (model, provider, game.id)
    }

    @Test func importedGameAutoFillsAboveThreshold() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _, id) = try await makeEnv(title: "Doom")

        model.metadata.importedGame(id)
        await waitUntil { model.store.record(id)?.game.metadataSource != nil }

        let record = try #require(model.store.record(id))
        #expect(record.game.year == 1993)
        #expect(record.game.developer == "id Software")
        #expect(record.game.publisher == "id Software")
        #expect(record.game.genre == "Shooter")
        #expect(record.game.description == "Fight demons on Mars.")
        #expect(record.game.metadataSource?.id == 101)
        #expect(FileManager.default.fileExists(atPath: io.coverURL(record.crateURL).path))
        #expect(FileManager.default.fileExists(atPath: io.backURL(record.crateURL).path))
    }

    @Test func importedGameBelowThresholdUnchanged() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, provider, id) = try await makeEnv(title: "Gold Box")

        model.metadata.importedGame(id)
        await waitUntil { provider.ensureReadyCalls == 1 }
        try await Task.sleep(for: .milliseconds(30))

        let record = try #require(model.store.record(id))
        #expect(record.game.year == nil)
        #expect(record.game.metadataSource == nil)
        #expect(provider.downloadCalls == 0)
    }

    @Test func prefOffDoesNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, provider, id) = try await makeEnv(title: "Doom", fetchOnImport: false)

        model.metadata.importedGame(id)
        try await Task.sleep(for: .milliseconds(30))

        #expect(provider.ensureReadyCalls == 0)
        #expect(model.store.record(id)?.game.metadataSource == nil)
    }

    @Test func queuedImportsProcessedAfterIndexReady() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, provider, id1) = try await makeEnv(title: "Doom")

        let crate2 = try io.makeCrate(title: "Doom 2", in: model.store.library)
        let game2 = Game(title: "Doom", source: .managed)
        try io.save(game2, extra: [:], to: crate2)
        await model.store.reload()
        let id2 = game2.id

        let (stream, continuation) = AsyncStream<Void>.makeStream()
        provider.ensureReadyGate = {
            for await _ in stream { break }
        }

        model.metadata.importedGame(id1)
        model.metadata.importedGame(id2)
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.store.record(id1)?.game.metadataSource == nil)
        #expect(model.store.record(id2)?.game.metadataSource == nil)

        continuation.yield(())
        continuation.finish()

        await waitUntil {
            model.store.record(id1)?.game.metadataSource != nil
                && model.store.record(id2)?.game.metadataSource != nil
        }
        #expect(model.store.record(id1)?.game.year == 1993)
        #expect(model.store.record(id2)?.game.year == 1993)
    }

    @Test func cancelsFetchOnPlay() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, provider, id) = try await makeEnv(title: "Doom")

        let (enteredStream, enteredCont) = AsyncStream<Void>.makeStream()
        let (releaseStream, releaseCont) = AsyncStream<Void>.makeStream()
        provider.downloadGate = { _ in
            enteredCont.yield(())
            enteredCont.finish()
            for await _ in releaseStream { break }
        }

        model.metadata.importedGame(id)
        for await _ in enteredStream { break }

        await model.play(id)?.value
        releaseCont.yield(())
        releaseCont.finish()
        try await Task.sleep(for: .milliseconds(30))

        #expect(model.store.record(id)?.game.metadataSource == nil)
        #expect(model.store.record(id)?.game.year == nil)
        runner.processes.first?.finish(0)
    }

    @Test func cancelsFetchOnRemove() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, provider, id) = try await makeEnv(title: "Doom")
        let crateURL = try #require(model.store.record(id)?.crateURL)

        let (enteredStream, enteredCont) = AsyncStream<Void>.makeStream()
        let (releaseStream, releaseCont) = AsyncStream<Void>.makeStream()
        provider.downloadGate = { _ in
            enteredCont.yield(())
            enteredCont.finish()
            for await _ in releaseStream { break }
        }

        model.metadata.importedGame(id)
        for await _ in enteredStream { break }

        model.removeGame(id, trashFiles: true)
        releaseCont.yield(())
        releaseCont.finish()
        try await Task.sleep(for: .milliseconds(30))

        #expect(model.store.record(id) == nil)
        #expect(!FileManager.default.fileExists(atPath: crateURL.path))
    }

    @Test func autoFillDoesNotOverwriteEditMadeDuringFetch() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, provider, id) = try await makeEnv(title: "Doom")

        let (enteredStream, enteredCont) = AsyncStream<Void>.makeStream()
        let (releaseStream, releaseCont) = AsyncStream<Void>.makeStream()
        provider.downloadGate = { _ in
            enteredCont.yield(())
            enteredCont.finish()
            for await _ in releaseStream { break }
        }

        model.metadata.importedGame(id)
        for await _ in enteredStream { break }

        // User edits developer while the fetch is downloading art.
        var edited = try #require(model.store.record(id)?.game)
        edited.developer = "User Edited Dev"
        try model.store.save(edited)

        releaseCont.yield(())
        releaseCont.finish()

        await waitUntil { model.store.record(id)?.game.metadataSource != nil }
        let saved = try #require(model.store.record(id)?.game)
        #expect(saved.developer == "User Edited Dev")
        #expect(saved.year == 1993)
        #expect(saved.publisher == "id Software")
    }

    @Test func fieldsSavedWhenArtNotWritable() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, provider, id) = try await makeEnv(title: "Doom")
        provider.artAllFailed = true

        let outcome = await model.metadata.apply(Self.sampleRecords[0], to: id, mode: .replace)
        #expect(outcome == .artNotWritable)
        let saved = try #require(model.store.record(id)?.game)
        #expect(saved.year == 1993)
        #expect(saved.developer == "id Software")
        #expect(saved.metadataSource?.id == 101)
    }

    @Test func statusTextForEachPhase() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _, _) = try await makeEnv(title: "Doom")
        let coord = model.metadata

        coord.phase = .idle
        #expect(coord.statusText == nil)

        coord.phase = .downloading(0.42)
        #expect(coord.statusText == "Downloading LaunchBox data… 42%")

        coord.phase = .building
        #expect(coord.statusText == "Building LaunchBox index…")

        coord.phase = .ready
        #expect(coord.statusText == nil)

        coord.phase = .failed("boom")
        #expect(coord.statusText == "LaunchBox data unavailable")
    }
}

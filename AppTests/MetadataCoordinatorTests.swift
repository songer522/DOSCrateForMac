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

    func download(
        _ art: [ArtKind: URL],
        into crate: URL,
        mode: ApplyMode,
        onWrite: @escaping @Sendable (ArtKind) -> Void
    ) async -> ArtResult {
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
        let sortedKinds = art.keys.sorted { $0.sortRank < $1.sortRank }
        for kind in sortedKinds {
            if Task.isCancelled { break }
            let dest = kind.fileURL(in: crate, io: io)
            if mode == .fillEmpty, FileManager.default.fileExists(atPath: dest.path) {
                continue
            }
            do {
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("png".utf8).write(to: dest)
                written.insert(kind)
                onWrite(kind)
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
        provider.ensureReadyGate = {
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
        provider.ensureReadyGate = {
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
        provider.ensureReadyGate = {
            enteredCont.yield(())
            enteredCont.finish()
            for await _ in releaseStream { break }
        }

        model.metadata.importedGame(id)
        for await _ in enteredStream { break }

        // User edits developer while the fetch is running.
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

        _ = await model.metadata.apply(Self.sampleRecords[0], to: id, mode: .replace)
        let saved = try #require(model.store.record(id)?.game)
        #expect(saved.year == 1993)
        #expect(saved.developer == "id Software")
        #expect(saved.metadataSource?.id == 101)
        await waitUntil { model.metadata.lastOutcome[id] == .artNotWritable }
        #expect(model.metadata.lastOutcome[id] == .artNotWritable)
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

    @Test func unmatchedAddedWhenAutoMatchFails() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, provider, id) = try await makeEnv(title: "Aladin")

        model.metadata.importedGame(id)
        await waitUntil { provider.ensureReadyCalls == 1 && model.metadata.unmatched == [id] }
        #expect(model.metadata.unmatched == [id])

        // Re-importing the same unmatched game does not duplicate its ID
        model.metadata.importedGame(id)
        await waitUntil { provider.ensureReadyCalls == 2 }
        #expect(model.metadata.unmatched == [id])
    }

    @Test func unmatchedClearedWhenMatchApplied() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _, id) = try await makeEnv(title: "Aladin")

        model.metadata.importedGame(id)
        await waitUntil { model.metadata.unmatched == [id] }

        let outcome = await model.metadata.apply(Self.sampleRecords[0], to: id, mode: .replace)
        #expect(outcome == .applied(artFailed: false))
        #expect(model.metadata.unmatched.isEmpty)
    }

    @Test func unmatchedClearedOnRemove() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _, id) = try await makeEnv(title: "Aladin")

        model.metadata.importedGame(id)
        await waitUntil { model.metadata.unmatched == [id] }

        model.removeGame(id, trashFiles: true)
        #expect(model.metadata.unmatched.isEmpty)
    }

    @Test func unmatchedStatusTextSingularPlural() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _, id1) = try await makeEnv(title: "Aladin")

        let lib = root.appending(path: "Library", directoryHint: .isDirectory)
        let crate2 = try io.makeCrate(title: "1000m", in: lib)
        var game2 = Game(title: "1000m", source: .managed)
        game2.launch.executable = "GAME.EXE"
        try io.save(game2, extra: [:], to: crate2)
        await model.store.reload()

        model.metadata.importedGame(id1)
        await waitUntil { model.metadata.unmatched == [id1] }
        #expect(LibraryView.statusBarLeadingText(for: model) == "1 game without a LaunchBox match")
        #expect(RetroStatusBar.leadingText(for: model) == "1 game without a LaunchBox match")
        #expect(LibraryView.showsUnmatchedReview(for: model) == true)

        model.metadata.importedGame(game2.id)
        await waitUntil { model.metadata.unmatched.count == 2 }
        #expect(LibraryView.statusBarLeadingText(for: model) == "2 games without a LaunchBox match")
        #expect(RetroStatusBar.leadingText(for: model) == "2 games without a LaunchBox match")

        // While downloading or building, download/build status takes precedence over unmatched notice
        model.metadata.phase = .downloading(0.5)
        #expect(LibraryView.statusBarLeadingText(for: model) == "Downloading LaunchBox data… 50%")
        #expect(LibraryView.showsUnmatchedReview(for: model) == false)
    }

    @Test func dismissAllClears() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _, id) = try await makeEnv(title: "Aladin")

        model.metadata.importedGame(id)
        await waitUntil { model.metadata.unmatched == [id] }

        model.metadata.dismissUnmatched()
        #expect(model.metadata.unmatched.isEmpty)
        #expect(LibraryView.statusBarLeadingText(for: model) == nil)
        #expect(LibraryView.showsUnmatchedReview(for: model) == false)
    }

    @Test func findMissingTargetsOnlyIncompleteUnmatchedGames() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, provider, incompleteID) = try await makeEnv(title: "Doom")
        let lib = root.appending(path: "Library", directoryHint: .isDirectory)

        // Game 2: already has metadataSource -> should be skipped even with nil year
        let crate2 = try io.makeCrate(title: "DoomWithSource", in: lib)
        var game2 = Game(title: "Doom", source: .managed)
        game2.metadataSource = MetadataSource(provider: "launchbox", id: 101, fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        game2.launch.executable = "GAME.EXE"
        try io.save(game2, extra: [:], to: crate2)

        // Game 3: metadataSource == nil, but all fields + cover.png are present -> should be skipped
        let crate3 = try io.makeCrate(title: "DoomComplete", in: lib)
        var game3 = Game(title: "Doom", source: .managed)
        game3.year = 1993
        game3.developer = "Custom Dev"
        game3.publisher = "Custom Pub"
        game3.genre = "Custom Genre"
        game3.description = "Custom Desc"
        game3.launch.executable = "GAME.EXE"
        try io.save(game3, extra: [:], to: crate3)
        try Data("png".utf8).write(to: io.coverURL(crate3))

        await model.store.reload()

        model.metadata.findMissingMetadata()
        await waitUntil { !model.metadata.isFindingMissing && model.store.record(incompleteID)?.game.metadataSource != nil }

        #expect(provider.downloadCalls == 1)
        #expect(model.store.record(incompleteID)?.game.year == 1993)
        #expect(model.store.record(game2.id)?.game.year == nil)
        #expect(model.store.record(game3.id)?.game.metadataSource == nil)
        #expect(model.store.record(game3.id)?.game.developer == "Custom Dev")
    }

    @Test func findMissingSkipsRunningGames() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, provider, runningID) = try await makeEnv(title: "Doom")
        let lib = root.appending(path: "Library", directoryHint: .isDirectory)

        let crate2 = try io.makeCrate(title: "DoomIdle", in: lib)
        var game2 = Game(title: "Doom", source: .managed)
        game2.launch.executable = "GAME.EXE"
        try io.save(game2, extra: [:], to: crate2)
        await model.store.reload()

        let playTask = model.play(runningID)
        await waitUntil { !runner.processes.isEmpty }

        model.metadata.findMissingMetadata()
        await waitUntil { !model.metadata.isFindingMissing && model.store.record(game2.id)?.game.metadataSource != nil }

        #expect(provider.downloadCalls == 1)
        #expect(model.store.record(runningID)?.game.metadataSource == nil)
        #expect(model.store.record(game2.id)?.game.metadataSource?.id == 101)

        runner.processes[0].finish(0)
        await playTask?.value
    }

    @Test func findMissingProgressText() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, provider, _) = try await makeEnv(title: "Doom")
        let lib = root.appending(path: "Library", directoryHint: .isDirectory)

        let crate2 = try io.makeCrate(title: "Zelda", in: lib)
        var game2 = Game(title: "Zelda", source: .managed)
        game2.launch.executable = "GAME.EXE"
        try io.save(game2, extra: [:], to: crate2)
        await model.store.reload()

        let (entered1Stream, entered1Cont) = AsyncStream<Void>.makeStream()
        let (release1Stream, release1Cont) = AsyncStream<Void>.makeStream()
        provider.downloadGate = { _ in
            entered1Cont.yield(())
            entered1Cont.finish()
            for await _ in release1Stream { break }
        }

        model.metadata.findMissingMetadata()
        for await _ in entered1Stream { break }

        #expect(LibraryView.statusBarLeadingText(for: model) == "Finding metadata… 1 of 2")
        #expect(RetroStatusBar.leadingText(for: model) == "Finding metadata… 1 of 2")
        #expect(LibraryView.showsFindMissingCancel(for: model) == true)

        release1Cont.yield(())
        release1Cont.finish()

        await waitUntil { !model.metadata.isFindingMissing }
        // After finishing, the unmatched notice for "Aladin" takes over
        #expect(model.metadata.unmatched == [game2.id])
        #expect(LibraryView.statusBarLeadingText(for: model) == "1 game without a LaunchBox match")
    }

    @Test func cancelFindMissingStopsAfterCurrent() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, provider, _) = try await makeEnv(title: "Doom")
        let lib = root.appending(path: "Library", directoryHint: .isDirectory)

        let crate2 = try io.makeCrate(title: "Doom 2", in: lib)
        var game2 = Game(title: "Doom", source: .managed)
        game2.launch.executable = "GAME.EXE"
        try io.save(game2, extra: [:], to: crate2)
        await model.store.reload()

        let (enteredStream, enteredCont) = AsyncStream<Void>.makeStream()
        let (releaseStream, releaseCont) = AsyncStream<Void>.makeStream()
        provider.downloadGate = { _ in
            enteredCont.yield(())
            enteredCont.finish()
            for await _ in releaseStream { break }
        }

        model.metadata.findMissingMetadata()
        for await _ in enteredStream { break }

        model.metadata.cancelFindMissing()
        releaseCont.yield(())
        releaseCont.finish()

        await waitUntil { !model.metadata.isFindingMissing }
        #expect(provider.downloadCalls == 1)
        let matchedCount = model.store.records.filter { $0.game.metadataSource != nil }.count
        #expect(matchedCount == 1)
    }

    @Test func findMissingIgnoresImportToggle() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _, id) = try await makeEnv(title: "Doom", fetchOnImport: false)

        model.metadata.findMissingMetadata()
        await waitUntil { model.store.record(id)?.game.metadataSource != nil }

        #expect(model.store.record(id)?.game.year == 1993)
    }

    @Test func applySavesFieldsBeforeArtDownloads() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, provider, id) = try await makeEnv(title: "Doom")

        let (enteredStream, enteredCont) = AsyncStream<Void>.makeStream()
        let (releaseStream, releaseCont) = AsyncStream<Void>.makeStream()
        provider.downloadGate = { _ in
            enteredCont.yield(())
            enteredCont.finish()
            for await _ in releaseStream { break }
        }

        let outcome = await model.metadata.apply(Self.sampleRecords[0], to: id, mode: .replace)
        #expect(outcome == .applied(artFailed: false))

        // Fields are already saved on disk while art download is still blocked in the background
        let saved = try #require(model.store.record(id)?.game)
        #expect(saved.year == 1993)
        #expect(saved.developer == "id Software")
        #expect(saved.metadataSource?.id == 101)
        #expect(!FileManager.default.fileExists(atPath: io.coverURL(model.store.record(id)!.crateURL).path))

        for await _ in enteredStream { break }
        #expect(model.metadata.artLoading.contains(id))

        releaseCont.yield(())
        releaseCont.finish()
        await waitUntil { !model.metadata.artLoading.contains(id) }
        #expect(FileManager.default.fileExists(atPath: io.coverURL(model.store.record(id)!.crateURL).path))
    }

    @Test func artLoadingSetWhileDownloadingAndClearedAfter() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, provider, id) = try await makeEnv(title: "Doom")

        let (enteredStream, enteredCont) = AsyncStream<Void>.makeStream()
        let (releaseStream, releaseCont) = AsyncStream<Void>.makeStream()
        provider.downloadGate = { _ in
            enteredCont.yield(())
            enteredCont.finish()
            for await _ in releaseStream { break }
        }

        _ = await model.metadata.apply(Self.sampleRecords[0], to: id, mode: .replace)
        #expect(model.metadata.artLoading.contains(id))
        for await _ in enteredStream { break }
        #expect(model.metadata.artLoading.contains(id))

        releaseCont.yield(())
        releaseCont.finish()
        await waitUntil { !model.metadata.artLoading.contains(id) }
        #expect(!model.metadata.artLoading.contains(id))
    }

    @Test func playCancelsBackgroundArtAndClearsSpinner() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, provider, id) = try await makeEnv(title: "Doom")

        let (enteredStream, enteredCont) = AsyncStream<Void>.makeStream()
        let (releaseStream, releaseCont) = AsyncStream<Void>.makeStream()
        provider.downloadGate = { _ in
            enteredCont.yield(())
            enteredCont.finish()
            for await _ in releaseStream { break }
        }

        _ = await model.metadata.apply(Self.sampleRecords[0], to: id, mode: .replace)
        for await _ in enteredStream { break }
        #expect(model.metadata.artLoading.contains(id))

        let playTask = model.play(id)
        #expect(!model.metadata.artLoading.contains(id))

        releaseCont.yield(())
        releaseCont.finish()
        await waitUntil { !runner.processes.isEmpty }
        #expect(!FileManager.default.fileExists(atPath: io.coverURL(model.store.record(id)!.crateURL).path))

        runner.processes[0].finish(0)
        await playTask?.value
    }

    @Test func artFailureReportedAfterFieldsSaved() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, provider, id) = try await makeEnv(title: "Doom")
        provider.artAllFailed = true

        _ = await model.metadata.apply(Self.sampleRecords[0], to: id, mode: .replace)
        let saved = try #require(model.store.record(id)?.game)
        #expect(saved.year == 1993)
        #expect(saved.metadataSource?.id == 101)

        await waitUntil { !model.metadata.artLoading.contains(id) && model.metadata.lastOutcome[id] != nil }
        #expect(model.metadata.lastOutcome[id] == .artNotWritable)
        #expect(model.alert?.title == "Couldn't save art")
    }

    @Test func batchImportedGamesAutoFillAfterDeferredReload() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let records = [
            LaunchBoxRecord(id: 101, name: "Doom", releaseYear: 1993, developer: "id Software"),
            LaunchBoxRecord(id: 102, name: "Heretic", releaseYear: 1994, developer: "Raven Software"),
            LaunchBoxRecord(id: 103, name: "Hexen", releaseYear: 1995, developer: "Raven Software"),
        ]
        let (model, _, initialID) = try await makeEnv(title: "Placeholder", records: records)
        try model.store.remove(initialID, trashFiles: true)

        let fm = FileManager.default
        let stagingDir = root.appending(path: "Staging", directoryHint: .isDirectory)
        var entries: [ImportQueue.BatchEntry] = []
        for title in ["Doom", "Heretic", "Hexen"] {
            let folder = stagingDir.appending(path: title, directoryHint: .isDirectory)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appending(path: "GAME.EXE"))
            entries.append(ImportQueue.BatchEntry(url: folder, mode: .reference))
        }

        await model.imports.enqueue(entries, model: model)?.value
        #expect(model.store.records.count == 3)

        await waitUntil {
            model.store.records.count == 3
                && model.store.records.allSatisfy { $0.game.metadataSource != nil }
        }

        let byTitle = Dictionary(uniqueKeysWithValues: model.store.records.map { ($0.game.title, $0.game) })
        #expect(byTitle["Doom"]?.year == 1993)
        #expect(byTitle["Doom"]?.developer == "id Software")
        #expect(byTitle["Heretic"]?.year == 1994)
        #expect(byTitle["Heretic"]?.developer == "Raven Software")
        #expect(byTitle["Hexen"]?.year == 1995)
        #expect(byTitle["Hexen"]?.developer == "Raven Software")
    }

    @Test func replacedArtTaskDoesNotClearNewTaskState() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, provider, id) = try await makeEnv(title: "Doom")

        let gate1Entered = Gate()
        let gate1Release = Gate()
        let gate2Entered = Gate()
        let gate2Release = Gate()
        let callCounter = Counter()

        provider.downloadGate = { _ in
            let n = callCounter.increment()
            if n == 1 {
                gate1Entered.open()
                await gate1Release.wait()
            } else {
                gate2Entered.open()
                await gate2Release.wait()
            }
        }

        _ = await model.metadata.apply(Self.sampleRecords[0], to: id, mode: .replace)
        await gate1Entered.wait()
        #expect(model.metadata.artLoading.contains(id))

        // Replace with a second apply while the first art task is still in flight.
        _ = await model.metadata.apply(Self.sampleRecords[0], to: id, mode: .replace)
        await gate2Entered.wait()

        // Let the cancelled first art task exit its download call.
        gate1Release.open()
        try await Task.sleep(for: .milliseconds(30))

        // The second art task is still running; its spinner and state must remain intact.
        #expect(model.metadata.artLoading.contains(id))
        #expect(model.metadata.lastOutcome[id] == nil)

        gate2Release.open()
        await waitUntil { !model.metadata.artLoading.contains(id) }
        #expect(model.metadata.lastOutcome[id] == .applied(artFailed: false))
    }

    @Test func removeAfterReplacementStillCancelsNewArtTask() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, provider, id) = try await makeEnv(title: "Doom")
        let crateURL = try #require(model.store.record(id)?.crateURL)

        let gate1Entered = Gate()
        let gate1Release = Gate()
        let gate2Entered = Gate()
        let gate2Release = Gate()
        let callCounter = Counter()
        let secondTaskSawCancel = Flag()

        provider.downloadGate = { _ in
            let n = callCounter.increment()
            if n == 1 {
                gate1Entered.open()
                await gate1Release.wait()
            } else {
                gate2Entered.open()
                await gate2Release.wait()
                if Task.isCancelled {
                    secondTaskSawCancel.set()
                }
            }
        }

        _ = await model.metadata.apply(Self.sampleRecords[0], to: id, mode: .replace)
        await gate1Entered.wait()

        _ = await model.metadata.apply(Self.sampleRecords[0], to: id, mode: .replace)
        await gate2Entered.wait()

        // Let the first (cancelled) art task finish while the second is still blocked.
        gate1Release.open()
        try await Task.sleep(for: .milliseconds(30))

        // Removing/cancelling the game now must still cancel the second art task.
        model.metadata.cancel(id)
        #expect(!model.metadata.artLoading.contains(id))

        gate2Release.open()
        await waitUntil { secondTaskSawCancel.value }
        #expect(!FileManager.default.fileExists(atPath: io.coverURL(crateURL).path))
    }

    @Test func retryAfterFailedFindMissingWorksWithImportToggleOff() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, provider, id) = try await makeEnv(title: "Doom", fetchOnImport: false)
        provider.shouldFailEnsureReady = true

        model.metadata.findMissingMetadata()
        await waitUntil {
            if case .failed = model.metadata.phase, !model.metadata.isFindingMissing {
                return true
            }
            return false
        }

        provider.shouldFailEnsureReady = false
        model.metadata.retry()

        await waitUntil { model.store.record(id)?.game.metadataSource != nil }
        let updated = try #require(model.store.record(id)?.game)
        #expect(updated.year == 1993)
        #expect(updated.developer == "id Software")
        #expect(updated.metadataSource?.id == 101)
    }

    @Test func autoApplyFlushesPendingInspectorEditFirst() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _, id) = try await makeEnv(title: "Doom", fetchOnImport: false)

        var draft = try #require(model.store.record(id)?.game)
        draft.notes = "My custom inspector notes"
        draft.developer = "User Edited Dev"
        let saveTask = GameDetailView.scheduleDraftSave(draft: draft, in: model)
        #expect(saveTask != nil)
        #expect(model.store.record(id)?.game.notes == "")

        // Auto-fetch runs while the 500ms inspector debounce is still pending.
        await model.metadata.enqueueAutoFetch(id)?.value

        // Wait past the 500ms debounce window to ensure a stale timer doesn't overwrite metadata.
        try await Task.sleep(for: .milliseconds(550))

        let saved = try #require(model.store.record(id)?.game)
        #expect(saved.notes == "My custom inspector notes")
        #expect(saved.developer == "User Edited Dev")
        #expect(saved.year == 1993)
        #expect(saved.publisher == "id Software")
        #expect(saved.genre == "Shooter")
        #expect(saved.description == "Fight demons on Mars.")
        #expect(saved.metadataSource?.id == 101)
        #expect(GameDetailView.shouldAdopt(stored: saved, over: draft))

        let onDisk = io.loadRecord(at: try #require(model.store.record(id)?.crateURL)).game
        #expect(onDisk.notes == "My custom inspector notes")
        #expect(onDisk.developer == "User Edited Dev")
        #expect(onDisk.year == 1993)
    }

    @Test func manualApplyFlushesPendingInspectorEditFirst() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _, id) = try await makeEnv(title: "Doom", fetchOnImport: false)

        var draft = try #require(model.store.record(id)?.game)
        draft.notes = "Notes before manual replace"
        draft.year = 1990
        let saveTask = GameDetailView.scheduleDraftSave(draft: draft, in: model)
        #expect(saveTask != nil)

        let outcome = await model.metadata.apply(Self.sampleRecords[0], to: id, mode: .replace)
        #expect(outcome == .applied(artFailed: false))

        // Wait past the 500ms debounce window to ensure the flushed draft doesn't fire again.
        try await Task.sleep(for: .milliseconds(550))

        let saved = try #require(model.store.record(id)?.game)
        #expect(saved.notes == "Notes before manual replace")
        #expect(saved.year == 1993)
        #expect(saved.developer == "id Software")
        #expect(saved.publisher == "id Software")
        #expect(saved.genre == "Shooter")
        #expect(saved.description == "Fight demons on Mars.")
        #expect(saved.metadataSource?.id == 101)
        #expect(GameDetailView.shouldAdopt(stored: saved, over: draft))
    }

    @Test func playStillFlushesPendingWrites() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _, id) = try await makeEnv(title: "Doom", fetchOnImport: false)

        var draft = try #require(model.store.record(id)?.game)
        draft.notes = "Flushed on play"
        _ = GameDetailView.scheduleDraftSave(draft: draft, in: model)
        #expect(model.store.record(id)?.game.notes == "")

        let playTask = model.play(id)
        #expect(model.store.record(id)?.game.notes == "Flushed on play")

        await waitUntil { !runner.processes.isEmpty }
        runner.processes[0].finish(0)
        await playTask?.value
    }

    @Test func findMissingSkipsGameMatchedManuallyDuringRun() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let firstRecord = LaunchBoxRecord(
            id: 100,
            name: "Doom",
            releaseYear: 1993,
            developer: "id Software",
            images: [LaunchBoxImage(type: "Box - Front", fileName: "doom.png")]
        )
        let autoQuakeRecord = LaunchBoxRecord(
            id: 101,
            name: "Quake",
            releaseYear: 1996,
            developer: "id Software",
            images: [LaunchBoxImage(type: "Box - Front", fileName: "quake.png")]
        )
        let manualQuakeRecord = LaunchBoxRecord(
            id: 102,
            name: "Quake: Scourge of Armagon",
            releaseYear: 1997,
            developer: "Hipnotic Interactive",
            images: [LaunchBoxImage(type: "Box - Front", fileName: "quake-armagon.png")]
        )

        let (model, provider, firstID) = try await makeEnv(
            title: "Doom",
            records: [firstRecord, autoQuakeRecord, manualQuakeRecord],
            fetchOnImport: false
        )
        let secondCrate = try io.makeCrate(title: "Quake", in: model.store.library)
        var secondGame = Game(title: "Quake", source: .managed)
        secondGame.launch.executable = "GAME.EXE"
        let secondID = secondGame.id
        try io.save(secondGame, extra: [:], to: secondCrate)
        await model.store.reload()

        let firstArtEntered = Gate()
        let firstArtRelease = Gate()
        let manualArtEntered = Gate()
        let manualArtRelease = Gate()
        let firstCratePath = try #require(model.store.record(firstID)?.crateURL.standardizedFileURL.path)
        let secondDownloadCalls = Counter()

        provider.downloadGate = { crate in
            if crate.standardizedFileURL.path == firstCratePath {
                firstArtEntered.open()
                await firstArtRelease.wait()
            } else if secondDownloadCalls.increment() == 1 {
                manualArtEntered.open()
                await manualArtRelease.wait()
            }
        }

        model.metadata.findMissingMetadata()
        await firstArtEntered.wait()

        // While game 1 ("Doom") is being processed by Find Missing, manually match game 2 ("Quake") to 102.
        _ = await model.metadata.apply(manualQuakeRecord, to: secondID, mode: .replace)
        await manualArtEntered.wait()
        #expect(model.store.record(secondID)?.game.metadataSource?.id == 102)
        #expect(model.metadata.artLoading.contains(secondID))

        // Release game 1 so Find Missing advances to game 2 and finishes.
        firstArtRelease.open()
        await waitUntil { !model.metadata.isFindingMissing }

        // Game 2 must NOT have been re-fetched, re-stamped to 101, or had its in-flight manual art task cancelled.
        let game2AfterRun = try #require(model.store.record(secondID)?.game)
        #expect(game2AfterRun.metadataSource?.id == 102)
        #expect(game2AfterRun.year == 1997)
        #expect(game2AfterRun.developer == "Hipnotic Interactive")
        #expect(model.metadata.artLoading.contains(secondID))

        manualArtRelease.open()
        await waitUntil { !model.metadata.artLoading.contains(secondID) }
        #expect(model.metadata.lastOutcome[secondID] == .applied(artFailed: false))
    }

    @Test func autoFetchNeverOverridesExistingMetadataSource() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, provider, id) = try await makeEnv(title: "Doom", fetchOnImport: true)

        // Case 1: metadataSource is already set before enqueueAutoFetch is called.
        let manualStamp = MetadataSource(
            provider: "launchbox",
            id: 999,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        var game = try #require(model.store.record(id)?.game)
        game.metadataSource = manualStamp
        game.year = nil
        try model.store.save(game)

        await model.metadata.enqueueAutoFetch(id)?.value
        let afterDirect = try #require(model.store.record(id)?.game)
        #expect(afterDirect.metadataSource == manualStamp)
        #expect(afterDirect.year == nil)
        #expect(provider.ensureReadyCalls == 0)

        // Case 2: metadataSource is nil when enqueueAutoFetch starts, but gets set while ensureReady is in flight.
        game.metadataSource = nil
        try model.store.save(game)

        let entered = Gate()
        let release = Gate()
        provider.ensureReadyGate = {
            entered.open()
            await release.wait()
        }

        let autoTask = model.metadata.enqueueAutoFetch(id)
        await entered.wait()

        var midFlight = try #require(model.store.record(id)?.game)
        midFlight.metadataSource = manualStamp
        midFlight.developer = "Manual Choice"
        try model.store.save(midFlight)

        release.open()
        await autoTask?.value

        let afterInFlight = try #require(model.store.record(id)?.game)
        #expect(afterInFlight.metadataSource == manualStamp)
        #expect(afterInFlight.developer == "Manual Choice")
        #expect(afterInFlight.year == nil)
    }
}

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func open() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            let copy = continuations
            continuations.removeAll()
            return copy
        }
        for c in pending { c.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                continuations.append(c)
                return false
            }
            if resumeNow { c.resume() }
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool { lock.withLock { storage } }
    func set() { lock.withLock { storage = true } }
}

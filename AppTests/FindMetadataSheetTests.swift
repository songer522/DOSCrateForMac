import AppKit
import Foundation
import ImportKit
import LauncherKit
import LibraryKit
import MetadataKit
import SwiftUI
import Testing
@testable import DOSCrate

@MainActor
@Suite struct FindMetadataSheetTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "findmeta-\(UUID().uuidString)")
    let io = CrateIO()

    static let sampleRecords: [LaunchBoxRecord] = [
        LaunchBoxRecord(
            id: 1,
            name: "Ultima",
            releaseYear: 1981,
            developer: "Origin Systems",
            publisher: "California Pacific",
            genres: ["Role-Playing"],
            overview: "First Ultima.",
            images: [LaunchBoxImage(type: "Box - Front", fileName: "u1.png")]
        ),
        LaunchBoxRecord(
            id: 2,
            name: "Ultima II",
            releaseYear: 1982,
            developer: "Sierra On-Line",
            publisher: "Sierra On-Line",
            genres: ["Role-Playing"],
            overview: "Second Ultima.",
            images: [LaunchBoxImage(type: "Box - Front", fileName: "u2.png")]
        ),
        LaunchBoxRecord(
            id: 3,
            name: "Ultima III: Exodus",
            releaseYear: 1983,
            developer: "Origin Systems",
            publisher: "Origin Systems",
            genres: ["Role-Playing"],
            overview: "Third Ultima.",
            images: [LaunchBoxImage(type: "Box - Front", fileName: "u3.png")]
        ),
        LaunchBoxRecord(
            id: 99,
            name: "Wolfenstein 3D",
            releaseYear: 1992,
            developer: "id Software",
            publisher: "Apogee",
            genres: ["Shooter"],
            overview: "Escape Castle Wolfenstein.",
            images: []
        ),
    ]

    func makeEnv(
        title: String = "Ultima",
        configure: (inout Game) -> Void = { _ in }
    ) async throws -> (AppModel, StubMetadataProvider, UUID) {
        let fm = FileManager.default
        let lib = root.appending(path: "Library", directoryHint: .isDirectory)
        try fm.createDirectory(at: lib, withIntermediateDirectories: true)

        let crate = try io.makeCrate(title: title, in: lib)
        var game = Game(title: title, source: .managed)
        configure(&game)
        try io.save(game, extra: [:], to: crate)

        let prefs = Preferences(defaults: UserDefaults(suiteName: "doscrate-fm-\(UUID().uuidString)")!)
        let store = LibraryStore(library: lib)
        await store.reload()

        let provider = StubMetadataProvider(records: Self.sampleRecords)
        let coordinator = MetadataCoordinator(provider: provider, prefs: prefs)
        let model = AppModel(
            prefs: prefs,
            store: store,
            sessions: SessionManager(runner: FakeRunner()),
            importer: Importer(),
            dosbox: root.appending(path: "dosbox"),
            verifyDosbox: { _ in },
            metadata: coordinator
        )
        return (model, provider, game.id)
    }

    @Test func prefillsQueryWithTitle() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _, id) = try await makeEnv(title: "The Secret of Monkey Island")
        let sheetModel = FindMetadataModel(model: model, gameID: id)
        #expect(sheetModel.query == "The Secret of Monkey Island")
    }

    @Test func currentSourceListedFirst() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _, id) = try await makeEnv(title: "Ultima") { game in
            game.metadataSource = MetadataSource(
                provider: "launchbox",
                id: 3,
                fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }
        let sheetModel = FindMetadataModel(model: model, gameID: id)
        await sheetModel.searchNow()

        #expect(sheetModel.results.first?.record.id == 3)
        #expect(sheetModel.isCurrent(Self.sampleRecords[2]))
        #expect(sheetModel.badgeText(for: Self.sampleRecords[2]) == "Current")
        #expect(sheetModel.badgeText(for: Self.sampleRecords[0]) == nil)
    }

    @Test func emptyResultsShowNoMatches() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _, id) = try await makeEnv(title: "ZzzNonExistentGameTitle")
        let sheetModel = FindMetadataModel(model: model, gameID: id)
        await sheetModel.searchNow()

        #expect(sheetModel.results.isEmpty)
        #expect(!sheetModel.isLoading)
        #expect(sheetModel.emptyStateText == "No matches")
    }

    @Test func confirmationRequiredOnlyWhenSomethingExists() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _, id) = try await makeEnv(title: "Ultima")
        let sheetModel = FindMetadataModel(model: model, gameID: id)

        // Fresh game with no fields or art does not require replace confirmation.
        #expect(!sheetModel.needsReplaceConfirmation(for: Self.sampleRecords[0]))

        // Once a field or art exists, confirmation is required.
        var game = try #require(model.store.record(id)?.game)
        game.developer = "Existing Dev"
        try model.store.save(game)
        #expect(sheetModel.needsReplaceConfirmation(for: Self.sampleRecords[0]))
    }

    @Test func useAppliesReplaceMode() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _, id) = try await makeEnv(title: "Ultima") { game in
            game.year = 1980
            game.developer = "Old Dev"
            game.description = "Old Description"
        }
        let sheetModel = FindMetadataModel(model: model, gameID: id)
        let outcome = await sheetModel.use(Self.sampleRecords[1])

        #expect(outcome == .applied(artFailed: false))
        let updated = try #require(model.store.record(id)?.game)
        #expect(updated.year == 1982)
        #expect(updated.developer == "Sierra On-Line")
        #expect(updated.publisher == "Sierra On-Line")
        #expect(updated.genre == "Role-Playing")
        #expect(updated.description == "Second Ultima.")
        #expect(updated.metadataSource?.id == 2)
    }

    @Test func findMetadataSheetUsesRetroLayoutInDOS() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _, id) = try await makeEnv(title: "Ultima")

        #expect(FindMetadataSheet.layout(for: .dos) == .retro)
        #expect(FindMetadataSheet.layout(for: .standard) == .standard)

        for theme in [AppTheme.dos, AppTheme.standard] {
            model.prefs.appTheme = theme
            let sheet = FindMetadataSheet(model: model, gameID: id)
            let hosting = NSHostingView(rootView: sheet)
            hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
            hosting.layoutSubtreeIfNeeded()
        }
    }

    @Test func unmatchedSheetUsesRetroLayoutInDOS() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _, id) = try await makeEnv(title: "Ultima")

        #expect(UnmatchedMetadataSheet.layout(for: .dos) == .retro)
        #expect(UnmatchedMetadataSheet.layout(for: .standard) == .standard)

        for unmatched in [[id], []] {
            model.metadata.unmatched = unmatched
            for theme in [AppTheme.dos, AppTheme.standard] {
                model.prefs.appTheme = theme
                let sheet = UnmatchedMetadataSheet(model: model)
                let hosting = NSHostingView(rootView: sheet)
                hosting.frame = NSRect(x: 0, y: 0, width: 460, height: 360)
                hosting.layoutSubtreeIfNeeded()
            }
        }
    }

    @Test func replaceConfirmationIsInSheetPanelInDOS() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _, id) = try await makeEnv(title: "Ultima") { game in
            game.developer = "Existing Dev"
        }
        model.prefs.appTheme = .dos

        let sheetModel = FindMetadataModel(model: model, gameID: id)
        await sheetModel.searchNow()

        let canProceedImmediately = sheetModel.requestUse(Self.sampleRecords[1])
        #expect(!canProceedImmediately)
        #expect(sheetModel.confirmingRecord == Self.sampleRecords[1])
        #expect(sheetModel.showsInSheetReplacePanel)
        #expect(!sheetModel.showsNativeConfirmationDialog)

        // Switching to Standard flips confirmation to native dialog instead of in-sheet panel.
        model.prefs.appTheme = .standard
        #expect(!sheetModel.showsInSheetReplacePanel)
        #expect(sheetModel.showsNativeConfirmationDialog)

        // Switch back to DOS, host the sheet with the in-sheet panel, and confirm.
        model.prefs.appTheme = .dos
        let sheet = FindMetadataSheet(model: model, gameID: id)
        let hosting = NSHostingView(rootView: sheet)
        hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        hosting.layoutSubtreeIfNeeded()

        let outcome = await sheetModel.confirmReplace()
        #expect(outcome == .applied(artFailed: false))
        #expect(sheetModel.confirmingRecord == nil)
        #expect(!sheetModel.showsInSheetReplacePanel)
        #expect(model.store.record(id)?.game.developer == "Sierra On-Line")
    }

    @Test func staleSearchResponseIsDiscarded() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, provider, id) = try await makeEnv(title: "Ultima")
        let sheetModel = FindMetadataModel(model: model, gameID: id)

        let firstEntered = SearchGate()
        let firstRelease = SearchGate()
        let counter = SearchCounter()

        provider.ensureReadyGate = {
            if counter.increment() == 1 {
                firstEntered.open()
                await firstRelease.wait()
            }
        }

        let firstSearch = Task { await sheetModel.searchNow() }
        await firstEntered.wait()

        // Newer search for "Wolfenstein 3D" finishes before the stale "Ultima" search resumes.
        sheetModel.query = "Wolfenstein 3D"
        await sheetModel.searchNow()
        #expect(sheetModel.results.first?.record.id == 99)

        // Release the older search; its stale "Ultima" results must be discarded.
        firstRelease.open()
        await firstSearch.value

        #expect(sheetModel.results.first?.record.id == 99)
        #expect(!sheetModel.results.contains { $0.record.id == 1 })
        #expect(!sheetModel.isLoading)
    }

    @Test func clearingQueryWhileIndexLoadsStaysEmpty() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, provider, id) = try await makeEnv(title: "Ultima")
        let sheetModel = FindMetadataModel(model: model, gameID: id)

        let entered = SearchGate()
        let release = SearchGate()
        provider.ensureReadyGate = {
            entered.open()
            await release.wait()
        }

        let inFlight = Task { await sheetModel.searchNow() }
        await entered.wait()
        #expect(sheetModel.isLoading)

        // Clear the search field while the index load is still in flight.
        sheetModel.query = ""
        sheetModel.scheduleSearch()
        #expect(sheetModel.results.isEmpty)
        #expect(!sheetModel.isLoading)

        // When the in-flight load finishes, the cleared field must stay empty with no stale rows.
        release.open()
        await inFlight.value
        #expect(sheetModel.results.isEmpty)
        #expect(!sheetModel.isLoading)
        #expect(sheetModel.errorText == nil)
    }
}

private final class SearchGate: @unchecked Sendable {
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

private final class SearchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

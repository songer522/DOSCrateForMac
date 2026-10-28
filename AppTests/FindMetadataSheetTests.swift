import Foundation
import ImportKit
import LauncherKit
import LibraryKit
import MetadataKit
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
}

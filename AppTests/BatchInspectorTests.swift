import AppKit
import Foundation
import ImportKit
import LauncherKit
import LibraryKit
import SwiftUI
import Testing
@testable import DOSCrate

@MainActor
@Suite struct BatchInspectorTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "batch-inspector-\(UUID().uuidString)")
    let io = CrateIO()

    func makeModel(games: [(title: String, configure: (inout Game) -> Void)]) async throws -> (AppModel, [UUID]) {
        let fm = FileManager.default
        let lib = root.appending(path: "Library")
        try fm.createDirectory(at: lib, withIntermediateDirectories: true)

        var ids: [UUID] = []
        for entry in games {
            let crate = try io.makeCrate(title: entry.title, in: lib)
            var game = Game(title: entry.title, source: .managed)
            entry.configure(&game)
            ids.append(game.id)
            try io.save(game, extra: [:], to: crate)
        }

        let dosbox = root.appending(path: "dosbox")
        try Data("#!/bin/sh\n".utf8).write(to: dosbox)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dosbox.path)

        let defaults = UserDefaults(suiteName: "doscrate-batch-\(UUID().uuidString)")!
        let prefs = Preferences(defaults: defaults)
        let store = LibraryStore(library: lib)
        await store.reload()
        let model = AppModel(
            prefs: prefs,
            store: store,
            sessions: SessionManager(runner: FakeRunner()),
            importer: Importer(),
            dosbox: dosbox,
            verifyDosbox: { _ in }
        )
        await model.startupVerify?.value
        return (model, ids)
    }

    @Test func setAndClearFavoritesAcrossSelectedGames() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, ids) = try await makeModel(games: [
            ("Commander Keen", { $0.isFavorite = false }),
            ("Doom", { $0.isFavorite = true }),
            ("Quake", { $0.isFavorite = false }),
        ])
        let selected: Set<UUID> = [ids[0], ids[1]]

        BatchInspectorView.setFavorite(true, for: selected, in: model)
        #expect(model.store.record(ids[0])?.game.isFavorite == true)
        #expect(model.store.record(ids[1])?.game.isFavorite == true)
        #expect(model.store.record(ids[2])?.game.isFavorite == false)

        BatchInspectorView.setFavorite(false, for: selected, in: model)
        #expect(model.store.record(ids[0])?.game.isFavorite == false)
        #expect(model.store.record(ids[1])?.game.isFavorite == false)
    }

    @Test func addAndRemoveTagsCaseInsensitively() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, ids) = try await makeModel(games: [
            ("Commander Keen", { $0.tags = ["Platformer", "Apogee"] }),
            ("Doom", { $0.tags = ["FPS", "apogee"] }),
        ])
        let selected = Set(ids)

        let initialSummaries = BatchInspectorView.tagSummaries(
            in: BatchInspectorView.selectedRecords(in: model, selectedIDs: selected)
        )
        #expect(initialSummaries == [
            .init(name: "Apogee", count: 2, total: 2),
            .init(name: "FPS", count: 1, total: 2),
            .init(name: "Platformer", count: 1, total: 2),
        ])

        // Adding a tag that one game already has (different case) only appends to the game missing it.
        BatchInspectorView.addTag("  fps  ", for: selected, in: model)
        #expect(model.store.record(ids[0])?.game.tags == ["Platformer", "Apogee", "fps"])
        #expect(model.store.record(ids[1])?.game.tags == ["FPS", "apogee"])

        // Removing a tag case-insensitively removes it from all selected games.
        BatchInspectorView.removeTag("APOGEE", for: selected, in: model)
        #expect(model.store.record(ids[0])?.game.tags == ["Platformer", "fps"])
        #expect(model.store.record(ids[1])?.game.tags == ["FPS"])
    }

    @Test func applySharedMetadataWithoutClobberingUntouchedMixedFields() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, ids) = try await makeModel(games: [
            ("Doom", {
                $0.genre = "Action"
                $0.year = 1993
                $0.developer = "id Software"
                $0.publisher = "id Software"
            }),
            ("Commander Keen", {
                $0.genre = "Platformer"
                $0.year = 1990
                $0.developer = "id Software"
                $0.publisher = "Apogee"
            }),
        ])
        let selected = Set(ids)
        let records = BatchInspectorView.selectedRecords(in: model, selectedIDs: selected)

        var draft = BatchInspectorView.BatchMetadataDraft(records: records)
        #expect(draft.hasMultipleGenres)
        #expect(draft.genre == "")
        #expect(draft.genrePrompt == "Multiple values")
        #expect(draft.hasMultipleYears)
        #expect(draft.yearText == "")
        #expect(draft.yearPrompt == "Multiple values")
        #expect(!draft.hasMultipleDevelopers)
        #expect(draft.developer == "id Software")
        #expect(draft.developerPrompt == nil)
        #expect(draft.hasMultiplePublishers)
        #expect(draft.publisher == "")
        #expect(draft.publisherPrompt == "Multiple values")
        #expect(!draft.hasChanges)

        // Edit only Genre and Year; leave Publisher (mixed) and Developer (shared) untouched.
        draft.genre = "Action / Shooter"
        draft.yearText = "1994"
        #expect(draft.hasChanges)

        BatchInspectorView.applyMetadata(draft, for: selected, in: model)

        let doom = try #require(model.store.record(ids[0])?.game)
        let keen = try #require(model.store.record(ids[1])?.game)
        #expect(doom.genre == "Action / Shooter")
        #expect(keen.genre == "Action / Shooter")
        #expect(doom.year == 1994)
        #expect(keen.year == 1994)
        // Untouched mixed publisher and shared developer remain intact!
        #expect(doom.publisher == "id Software")
        #expect(keen.publisher == "Apogee")
        #expect(doom.developer == "id Software")
        #expect(keen.developer == "id Software")

        // Clearing a shared field sets it to nil on all selected games.
        var secondDraft = BatchInspectorView.BatchMetadataDraft(
            records: BatchInspectorView.selectedRecords(in: model, selectedIDs: selected)
        )
        #expect(!secondDraft.hasMultipleDevelopers)
        secondDraft.developer = ""
        secondDraft.yearText = ""
        BatchInspectorView.applyMetadata(secondDraft, for: selected, in: model)
        #expect(model.store.record(ids[0])?.game.developer == nil)
        #expect(model.store.record(ids[1])?.game.developer == nil)
        #expect(model.store.record(ids[0])?.game.year == nil)
        #expect(model.store.record(ids[1])?.game.year == nil)
    }

    @Test func invalidYearBlocksMetadataApply() {
        let g1 = GameRecord(game: Game(title: "A", source: .managed), crateURL: URL(filePath: "/tmp/A.doscrate"))
        let g2 = GameRecord(game: Game(title: "B", source: .managed), crateURL: URL(filePath: "/tmp/B.doscrate"))
        var draft = BatchInspectorView.BatchMetadataDraft(records: [g1, g2])
        draft.yearText = "not-a-year"
        #expect(!draft.isYearValid)
        #expect(!draft.hasChanges)
    }

    @Test func applyMachinePresetAcrossSelectedGames() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, ids) = try await makeModel(games: [
            ("Doom", { $0.settings.preset = .pc486 }),
            ("Commander Keen", { $0.settings.preset = nil }),
        ])
        let selected = Set(ids)

        #expect(
            BatchInspectorView.presetChoice(
                in: BatchInspectorView.selectedRecords(in: model, selectedIDs: selected)
            ) == .mixed
        )

        BatchInspectorView.applyPreset(.pentium, for: selected, in: model)
        #expect(model.store.record(ids[0])?.game.settings.preset == .pentium)
        #expect(model.store.record(ids[1])?.game.settings.preset == .pentium)
        #expect(
            BatchInspectorView.presetChoice(
                in: BatchInspectorView.selectedRecords(in: model, selectedIDs: selected)
            ) == .preset(.pentium)
        )

        BatchInspectorView.applyPreset(nil, for: selected, in: model)
        #expect(model.store.record(ids[0])?.game.settings.preset == nil)
        #expect(model.store.record(ids[1])?.game.settings.preset == nil)
        #expect(
            BatchInspectorView.presetChoice(
                in: BatchInspectorView.selectedRecords(in: model, selectedIDs: selected)
            ) == .presetDefault
        )
    }

    @Test func batchOperationsSkipReadOnlyGames() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, ids) = try await makeModel(games: [
            ("Writable Game", {
                $0.isFavorite = false
                $0.tags = ["Old"]
                $0.genre = "Action"
                $0.settings.preset = nil
            }),
            ("Read-Only Game", {
                $0.isFavorite = false
                $0.tags = ["Old"]
                $0.genre = "RPG"
                $0.settings.preset = nil
            }),
        ])

        var roRecord = try #require(model.store.record(ids[1]))
        roRecord.status = .readOnly(reason: "Future format")
        model.store.upsert(roRecord)

        let selected = Set(ids)
        #expect(BatchInspectorView.writableRecords(in: model, selectedIDs: selected).map(\.id) == [ids[0]])
        #expect(
            BatchInspectorView.headerSubtitle(selectedCount: 2, writableCount: 1) == "1 editable · 1 read-only"
        )
        #expect(
            BatchInspectorView.headerSubtitle(selectedCount: 2, writableCount: 0) == "All selected games are read-only"
        )
        #expect(BatchInspectorView.headerSubtitle(selectedCount: 2, writableCount: 2) == nil)

        BatchInspectorView.setFavorite(true, for: selected, in: model)
        BatchInspectorView.addTag("DOS", for: selected, in: model)
        BatchInspectorView.removeTag("Old", for: selected, in: model)
        BatchInspectorView.applyPreset(.pc386, for: selected, in: model)

        var draft = BatchInspectorView.BatchMetadataDraft(
            records: BatchInspectorView.selectedRecords(in: model, selectedIDs: selected)
        )
        draft.genre = "Strategy"
        BatchInspectorView.applyMetadata(draft, for: selected, in: model)

        let writable = try #require(model.store.record(ids[0])?.game)
        #expect(writable.isFavorite == true)
        #expect(writable.tags == ["DOS"])
        #expect(writable.genre == "Strategy")
        #expect(writable.settings.preset == .pc386)

        let readOnly = try #require(model.store.record(ids[1])?.game)
        #expect(readOnly.isFavorite == false)
        #expect(readOnly.tags == ["Old"])
        #expect(readOnly.genre == "RPG")
        #expect(readOnly.settings.preset == nil)
        #expect(model.alert == nil)
    }

    @Test func rendersInStandardAndRetroThemes() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, ids) = try await makeModel(games: [
            ("Doom", { $0.tags = ["FPS"]; $0.year = 1993 }),
            ("Quake", { $0.tags = ["FPS", "3D"]; $0.year = 1996 }),
        ])
        let selected = Set(ids)

        let standardHosting = NSHostingView(rootView: BatchInspectorView(model: model, selectedIDs: selected))
        standardHosting.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        standardHosting.layoutSubtreeIfNeeded()

        let retroHosting = NSHostingView(
            rootView: BatchInspectorView(model: model, selectedIDs: selected).retroControls()
        )
        retroHosting.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        retroHosting.layoutSubtreeIfNeeded()
    }
}

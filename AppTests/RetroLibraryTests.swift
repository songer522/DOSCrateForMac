import AppKit
import Foundation
import ImportKit
import LauncherKit
import LibraryKit
import SwiftUI
import Testing
@testable import DOSCrate

@MainActor
struct RetroLibraryTests {
    @Test func badgesForEachStatus() {
        let url = URL(filePath: "/tmp/Game.doscrate")
        let okRecord = GameRecord(game: Game(title: "Keen", source: .managed), crateURL: url, status: .ok)
        #expect(RetroBadge.badges(for: okRecord, running: [], starting: []) == [])
        #expect(RetroBadge.badges(for: okRecord, running: [okRecord.id], starting: []) == [.running])
        #expect(RetroBadge.badges(for: okRecord, running: [okRecord.id], starting: [okRecord.id]) == [.running])

        let missingRecord = GameRecord(game: Game(title: "Keen", source: .managed), crateURL: url, status: .missingSource)
        #expect(RetroBadge.badges(for: missingRecord, running: [], starting: [missingRecord.id]) == [.starting, .missing])

        let repairRecord = GameRecord(game: Game(title: "Keen", source: .managed), crateURL: url, status: .needsRepair(reason: "bad"))
        #expect(RetroBadge.badges(for: repairRecord, running: [], starting: []) == [.needsRepair])

        let readOnlyRecord = GameRecord(game: Game(title: "Keen", source: .managed), crateURL: url, status: .readOnly(reason: "ro"))
        #expect(RetroBadge.badges(for: readOnlyRecord, running: [], starting: []) == [.readOnly])
    }

    @Test func playTargetNeedsExactlyOneIdleGame() {
        let a = UUID()
        let b = UUID()
        #expect(RetroLibraryView.playTarget(selected: [], running: [], starting: [], pendingRemoval: []) == nil)
        #expect(RetroLibraryView.playTarget(selected: [a], running: [], starting: [], pendingRemoval: []) == a)
        #expect(RetroLibraryView.playTarget(selected: [a, b], running: [], starting: [], pendingRemoval: []) == nil)
        #expect(RetroLibraryView.playTarget(selected: [a], running: [a], starting: [], pendingRemoval: []) == nil)
        #expect(RetroLibraryView.playTarget(selected: [a], running: [], starting: [a], pendingRemoval: []) == nil)
        #expect(RetroLibraryView.playTarget(selected: [a], running: [], starting: [], pendingRemoval: [a]) == nil)
    }

    @Test func retroLayoutRendersLargeLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "retrolib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let defaults = UserDefaults(suiteName: "doscrate-retro-\(UUID().uuidString)")!
        let prefs = Preferences(defaults: defaults)
        prefs.appTheme = .dos
        let store = LibraryStore(library: root)
        let model = AppModel(
            prefs: prefs,
            store: store,
            sessions: SessionManager(runner: FakeRunner()),
            importer: Importer(),
            dosbox: root.appending(path: "dosbox"),
            verifyDosbox: { _ in }
        )

        let longTitle = String(repeating: "Commander Keen Episode ", count: 6) // > 120 chars
        let records: [GameRecord] = (0..<300).map { i in
            var game = Game(title: i % 5 == 0 ? "\(longTitle)\(i)" : "Game \(i)", source: .managed)
            game.year = 1990 + (i % 10)
            game.developer = "Developer \(i)"
            return GameRecord(
                game: game,
                crateURL: root.appending(path: "Game-\(i).doscrate"),
                status: i % 17 == 0 ? .missingSource : .ok
            )
        }

        let makeView = { (recs: [GameRecord], grid: Bool) -> RetroLibraryView in
            let commands = LibraryCommands(
                model: model,
                records: recs,
                removing: .constant(nil),
                removingMany: .constant(nil)
            )
            return RetroLibraryView(
                model: model,
                records: recs,
                commands: commands,
                showsGrid: .constant(grid),
                showsInspector: .constant(true),
                choosingImport: .constant(false)
            )
        }

        let hosting = NSHostingView(rootView: makeView(records, true))
        hosting.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        hosting.layoutSubtreeIfNeeded()

        hosting.rootView = makeView(records, false)
        hosting.layoutSubtreeIfNeeded()

        hosting.rootView = makeView([], true)
        hosting.layoutSubtreeIfNeeded()

        hosting.rootView = makeView([], false)
        hosting.layoutSubtreeIfNeeded()
    }
}

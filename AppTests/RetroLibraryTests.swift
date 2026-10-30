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
    @Test func listScrollsSidewaysOnlyWhenNarrowerThanItsColumns() {
        // Title minimum 200 + Year 60 + Developer 160 + Last Played 120 + Play Time 100, 4 gaps of 12, 8 + 8 padding.
        #expect(RetroGameList.minimumContentWidth == 704)
        #expect(RetroGameList.contentWidth(available: 300) == 704)
        #expect(RetroGameList.contentWidth(available: 900) == 900)
    }

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

    @Test func windowChromeTogglesRetroAndStandard() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        RetroWindowChrome.apply(isRetro: true, to: window)
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.standardWindowButton(.closeButton)?.isHidden == true)
        #expect(window.standardWindowButton(.miniaturizeButton)?.isHidden == true)
        #expect(window.standardWindowButton(.zoomButton)?.isHidden == true)
        #expect(window.standardWindowButton(.closeButton)?.superview?.superview?.isHidden == true)

        RetroWindowChrome.apply(isRetro: false, to: window)
        #expect(window.titleVisibility == .visible)
        #expect(!window.titlebarAppearsTransparent)
        #expect(!window.styleMask.contains(.fullSizeContentView))
        #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
        #expect(window.standardWindowButton(.miniaturizeButton)?.isHidden == false)
        #expect(window.standardWindowButton(.zoomButton)?.isHidden == false)
        #expect(window.standardWindowButton(.closeButton)?.superview?.superview?.isHidden == false)
    }

    @Test func closeActionCallbackIsWiredOnRetroLibraryView() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "retrolib-close-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let defaults = UserDefaults(suiteName: "doscrate-retro-close-\(UUID().uuidString)")!
        let prefs = Preferences(defaults: defaults)
        let store = LibraryStore(library: root)
        let model = AppModel(
            prefs: prefs,
            store: store,
            sessions: SessionManager(runner: FakeRunner()),
            importer: Importer(),
            dosbox: root.appending(path: "dosbox"),
            verifyDosbox: { _ in }
        )
        let commands = LibraryCommands(model: model, records: [], removing: .constant(nil), removingMany: .constant(nil))
        var didClose = false
        let view = RetroLibraryView(
            model: model,
            records: [],
            commands: commands,
            showsGrid: .constant(true),
            showsInspector: .constant(true),
            choosingImport: .constant(false),
            onClose: { didClose = true }
        )
        view.onClose()
        #expect(didClose)
    }

    @Test func statusBarShowsMetadataStatusWhenIdleOtherwise() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "retrolib-status-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let defaults = UserDefaults(suiteName: "doscrate-retro-status-\(UUID().uuidString)")!
        let prefs = Preferences(defaults: defaults)
        let store = LibraryStore(library: root)
        let model = AppModel(
            prefs: prefs,
            store: store,
            sessions: SessionManager(runner: FakeRunner()),
            importer: Importer(),
            dosbox: root.appending(path: "dosbox"),
            verifyDosbox: { _ in }
        )

        #expect(LibraryView.statusBarLeadingText(for: model) == nil)
        #expect(RetroStatusBar.leadingText(for: model) == nil)

        model.metadata.phase = .downloading(0.5)
        #expect(LibraryView.statusBarLeadingText(for: model) == "Downloading LaunchBox data… 50%")
        #expect(RetroStatusBar.leadingText(for: model) == "Downloading LaunchBox data… 50%")
        #expect(!LibraryView.showsMetadataRetry(for: model))

        model.metadata.phase = .building
        #expect(LibraryView.statusBarLeadingText(for: model) == "Building LaunchBox index…")
        #expect(RetroStatusBar.leadingText(for: model) == "Building LaunchBox index…")

        model.metadata.phase = .failed("offline")
        #expect(LibraryView.statusBarLeadingText(for: model) == "LaunchBox data unavailable")
        #expect(RetroStatusBar.leadingText(for: model) == "LaunchBox data unavailable")
        #expect(LibraryView.showsMetadataRetry(for: model))
        #expect(RetroStatusBar.showsMetadataRetry(for: model))
        #expect(!LibraryView.showsRemovalCancel(for: model))
        #expect(!RetroStatusBar.showsRemovalCancel(for: model))
    }
}

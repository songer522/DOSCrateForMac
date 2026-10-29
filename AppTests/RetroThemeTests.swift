import AppKit
import ConfigKit
import ImportKit
import LauncherKit
import LibraryKit
import SwiftUI
import Testing
@testable import DOSCrate

@MainActor
struct RetroThemeTests {
    @Test func paletteMatchesSpec() {
        #expect(RetroPalette.hex(RetroPalette.desktop) == "#0000AA")
        #expect(RetroPalette.hex(RetroPalette.panel) == "#C0C0C0")
        #expect(RetroPalette.hex(RetroPalette.bevelDark) == "#808080")
        #expect(RetroPalette.hex(RetroPalette.secondaryText) == "#404040")
        #expect(RetroPalette.hex(RetroPalette.yellow) == "#FFFF55")
        #expect(RetroPalette.hex(RetroPalette.cyan) == "#55FFFF")
    }

    @Test func bevelColorsInvertWhenSunken() {
        #expect(RetroBevelStyle.raised.topLeft == RetroPalette.bevelLight)
        #expect(RetroBevelStyle.raised.bottomRight == RetroPalette.bevelDark)
        #expect(RetroBevelStyle.sunken.topLeft == RetroPalette.bevelDark)
        #expect(RetroBevelStyle.sunken.bottomRight == RetroPalette.bevelLight)
    }

    @Test func pixelSymbolRendersAKnownSymbol() throws {
        let image = try #require(PixelSymbol.render("gamecontroller", color: .black, pointSize: 16))
        #expect(image.size.width >= 8 && image.size.width <= 24)
        #expect(image.size.height >= 8 && image.size.height <= 24)
    }

    @Test func pixelSymbolUnknownNameIsNil() {
        #expect(PixelSymbol.render("no.such.symbol", color: .black, pointSize: 16) == nil)
    }

    @Test func retroThemeEnvironmentDefaultsToFalse() {
        #expect(EnvironmentValues().retroTheme == false)
    }

    @Test func themedPickerLabelAndSelectionMapping() {
        #expect(ThemedPicker<Preset>.currentText(for: nil, label: \.displayName) == "Preset default")
        #expect(ThemedPicker<Preset>.currentText(for: .pc486, label: \.displayName) == Preset.pc486.displayName)
        #expect(ThemedPicker<String>.currentText(for: nil, nilLabel: "None", label: { $0 }) == "None")
        #expect(ThemedPicker<Int>.optionsWithNil([4, 8, 16]) == [nil, 4, 8, 16])
    }

    @Test func themedSegmentedSelectionMapping() {
        #expect(ThemedSegmented<CyclesMode>.isSelected(.auto, selection: .auto))
        #expect(!ThemedSegmented<CyclesMode>.isSelected(.preset, selection: .auto))
    }

    @Test func gameDetailViewRendersAllTabsInStandardAndRetro() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "detail-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let defaults = UserDefaults(suiteName: "doscrate-detail-\(UUID().uuidString)")!
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

        var game = Game(title: "Prince of Persia", source: .managed)
        game.year = 1990
        game.developer = "Broderbund"
        game.settings.cycles = .fixed(3000)
        game.media = [MediaImage(relativePath: "media/disc.iso", kind: .cdrom)]
        let record = GameRecord(game: game, crateURL: root.appending(path: "PoP.doscrate"), status: .ok)

        for retro in [false, true] {
            for tab in GameDetailView.Tab.allCases {
                let view = GameDetailView(model: model, record: record, initialTab: tab)
                    .environment(\.retroTheme, retro)
                let hosting = NSHostingView(rootView: view)
                hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 640)
                hosting.layoutSubtreeIfNeeded()
            }
        }
    }

    @Test func preferencesAndSheetsRenderInStandardAndRetro() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sheets-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let defaults = UserDefaults(suiteName: "doscrate-sheets-\(UUID().uuidString)")!
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

        #expect(ImportSheet.locationLabel(for: .copy) == "Copy into library")
        #expect(ImportSheet.locationLabel(for: .reference) == "Keep in place")
        #expect(ImportSheet.duplicateActionLabel(for: .skip) == "Skip duplicates")
        #expect(ImportSheet.duplicateActionLabel(for: .replace) == "Replace")
        #expect(ImportSheet.duplicateActionLabel(for: .keepBoth) == "Keep Both")

        let game = Game(title: "Doom", source: .managed)
        let record = GameRecord(game: game, crateURL: root.appending(path: "Doom.doscrate"), status: .ok)
        let prompt = ImportQueue.BatchPrompt(
            urls: [root.appending(path: "Doom"), root.appending(path: "Keen")],
            presetMode: nil,
            matches: [root.appending(path: "Doom"): DuplicateMatch(record: record, kind: .sameTitle)]
        )
        let chooseRequest = ChooseProgramRequest(
            gameID: game.id,
            title: "Doom",
            candidates: [ExecutableCandidate(relativePath: "DOOM.EXE", score: 100)]
        )
        let alert = AppAlert(title: "Test Alert", message: "Alert body", fix: .chooseExecutable, gameID: game.id)

        for theme in AppTheme.allCases {
            prefs.appTheme = theme

            for tab in PreferencesView.Tab.allCases {
                let prefsHosting = NSHostingView(rootView: PreferencesView(model: model, updater: nil, initialTab: tab))
                prefsHosting.frame = NSRect(x: 0, y: 0, width: 520, height: 460)
                prefsHosting.layoutSubtreeIfNeeded()
            }

            let importHosting = NSHostingView(rootView: ImportSheet(model: model, url: root) {})
            importHosting.frame = NSRect(x: 0, y: 0, width: 460, height: 360)
            importHosting.layoutSubtreeIfNeeded()

            let batchHosting = NSHostingView(rootView: BatchImportSheet(model: model, prompt: prompt))
            batchHosting.frame = NSRect(x: 0, y: 0, width: 420, height: 360)
            batchHosting.layoutSubtreeIfNeeded()

            let chooseHosting = NSHostingView(rootView: ChooseProgramSheet(model: model, request: chooseRequest))
            chooseHosting.frame = NSRect(x: 0, y: 0, width: 440, height: 320)
            chooseHosting.layoutSubtreeIfNeeded()

            let firstRunHosting = NSHostingView(rootView: FirstRunView(model: model))
            firstRunHosting.frame = NSRect(x: 0, y: 0, width: 480, height: 240)
            firstRunHosting.layoutSubtreeIfNeeded()

            let licensesHosting = NSHostingView(rootView: LicensesView(prefs: prefs))
            licensesHosting.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
            licensesHosting.layoutSubtreeIfNeeded()

            let alertHosting = NSHostingView(rootView: RetroAlertModal(model: model, alert: alert))
            alertHosting.frame = NSRect(x: 0, y: 0, width: 420, height: 200)
            alertHosting.layoutSubtreeIfNeeded()
        }
    }
}

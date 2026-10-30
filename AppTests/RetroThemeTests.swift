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

    @Test func retroCandidateListAndLicensesSteppedSelection() {
        let candidates = [
            ExecutableCandidate(relativePath: "SETUP.EXE", score: 50),
            ExecutableCandidate(relativePath: "DOOM.EXE", score: 100),
            ExecutableCandidate(relativePath: "README.COM", score: 10),
        ]

        #expect(RetroCandidateList.steppedSelection(in: [], current: nil, by: 1) == nil)
        #expect(RetroCandidateList.steppedSelection(in: candidates, current: "DOOM.EXE", by: 0) == nil)
        #expect(RetroCandidateList.steppedSelection(in: candidates, current: nil, by: 1) == "SETUP.EXE")
        #expect(RetroCandidateList.steppedSelection(in: candidates, current: nil, by: -1) == "README.COM")
        #expect(RetroCandidateList.steppedSelection(in: candidates, current: "SETUP.EXE", by: -1) == "SETUP.EXE")
        #expect(RetroCandidateList.steppedSelection(in: candidates, current: "SETUP.EXE", by: 1) == "DOOM.EXE")
        #expect(RetroCandidateList.steppedSelection(in: candidates, current: "DOOM.EXE", by: 1) == "README.COM")
        #expect(RetroCandidateList.steppedSelection(in: candidates, current: "README.COM", by: 1) == "README.COM")
        #expect(RetroCandidateList.steppedSelection(in: candidates, current: "README.COM", by: -1) == "DOOM.EXE")

        let files = [
            LicenseFile(url: URL(fileURLWithPath: "/tmp/a.txt"), name: "a.txt"),
            LicenseFile(url: URL(fileURLWithPath: "/tmp/b.txt"), name: "b.txt"),
        ]
        #expect(LicensesView.steppedSelection(in: [], current: nil, by: 1) == nil)
        #expect(LicensesView.steppedSelection(in: files, current: nil, by: 1) == files[0].id)
        #expect(LicensesView.steppedSelection(in: files, current: files[0].id, by: 1) == files[1].id)
        #expect(LicensesView.steppedSelection(in: files, current: files[1].id, by: 1) == files[1].id)
        #expect(LicensesView.steppedSelection(in: files, current: files[1].id, by: -1) == files[0].id)
    }

    @Test func retroModalIsolationState() {
        let game = Game(title: "Doom", source: .managed)
        let record = GameRecord(game: game, crateURL: URL(fileURLWithPath: "/tmp/Doom.doscrate"), status: .ok)
        let alert = AppAlert(title: "Error", message: "Details")

        #expect(!LibraryActions.isShowingRetroRemoval(isRetro: false, removingRecord: record, removingMany: nil))
        #expect(!LibraryActions.isShowingRetroRemoval(isRetro: true, removingRecord: nil, removingMany: nil))
        #expect(LibraryActions.isShowingRetroRemoval(isRetro: true, removingRecord: record, removingMany: nil))
        #expect(LibraryActions.isShowingRetroRemoval(isRetro: true, removingRecord: nil, removingMany: [game.id]))

        #expect(!DOSCrateApp.isShowingRetroAlert(theme: .standard, alert: alert))
        #expect(!DOSCrateApp.isShowingRetroAlert(theme: .dos, alert: nil))
        #expect(DOSCrateApp.isShowingRetroAlert(theme: .dos, alert: alert))
    }

    @Test func retroAlertContextTracksTopmostSheetAndScrollsLongMessages() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "alert-context-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let defaults = UserDefaults(suiteName: "doscrate-alert-ctx-\(UUID().uuidString)")!
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

        #expect(DOSCrateApp.activeRetroAlertContext(for: model) == nil)
        model.alert = AppAlert(title: "Timed Out", message: "DOSBox did not start.")
        #expect(DOSCrateApp.activeRetroAlertContext(for: model) == .mainWindow)

        let gameID = UUID()
        model.showingUnmatchedMetadata = true
        #expect(DOSCrateApp.activeRetroAlertContext(for: model) == .unmatchedMetadataSheet)

        model.findMetadataFor = gameID
        #expect(DOSCrateApp.activeRetroAlertContext(for: model) == .findMetadataSheet)

        model.showingUnmatchedMetadata = false
        #expect(DOSCrateApp.activeRetroAlertContext(for: model) == .findMetadataSheet)

        model.findMetadataFor = nil
        model.chooseProgram = ChooseProgramRequest(
            gameID: gameID,
            title: "Doom",
            candidates: [ExecutableCandidate(relativePath: "DOOM.EXE", score: 100)]
        )
        #expect(DOSCrateApp.activeRetroAlertContext(for: model) == .chooseProgramSheet)

        model.chooseProgram = nil
        model.imports.add([root.appending(path: "A"), root.appending(path: "B")], model: model)
        #expect(DOSCrateApp.activeRetroAlertContext(for: model) == .batchImportSheet)

        model.imports.cancelBatch()
        model.imports.add([root.appending(path: "A")], model: model)
        #expect(DOSCrateApp.activeRetroAlertContext(for: model) == .importSheet)
        model.imports.finishCurrent()

        prefs.appTheme = .standard
        #expect(DOSCrateApp.activeRetroAlertContext(for: model) == nil)

        prefs.appTheme = .dos
        let longLines = (1...50).map { "Game \($0): Archive could not be extracted." }.joined(separator: "\n")
        let longAlert = AppAlert(title: "Couldn't import 50 of 50 items", message: longLines)
        let longHosting = NSHostingView(rootView: RetroAlertModal(model: model, alert: longAlert))
        longHosting.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        longHosting.layoutSubtreeIfNeeded()
        #expect(containsScrollView(in: longHosting))
    }

    private func containsScrollView(in view: NSView) -> Bool {
        if view is NSScrollView {
            return true
        }
        return view.subviews.contains(where: containsScrollView)
    }
}

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
}

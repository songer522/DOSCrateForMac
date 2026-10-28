import AppKit
import SwiftUI
import Testing
@testable import DOSCrate

@MainActor
struct RetroThemeTests {
    @Test func paletteMatchesSpec() {
        #expect(RetroPalette.hex(RetroPalette.desktop) == "#0000AA")
        #expect(RetroPalette.hex(RetroPalette.panel) == "#C0C0C0")
        #expect(RetroPalette.hex(RetroPalette.bevelDark) == "#808080")
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
}

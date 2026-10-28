import AppKit
import Foundation
import Testing
@testable import DOSCrate

@MainActor
struct RetroFontTests {
    @Test func bundledFontIsInTheApp() {
        #expect(Bundle.main.url(forResource: "PxPlus_IBM_VGA_8x16", withExtension: "ttf") != nil)
    }

    @Test func registersAndResolves() {
        #expect(RetroFont.register())
        #expect(NSFont(name: RetroFont.postScriptName, size: 16) != nil)
        #expect(RetroFont.register())
        #expect(NSFont(name: RetroFont.postScriptName, size: 16) != nil)
    }

    @Test func badURLFailsWithoutCrashing() {
        #expect(RetroFont.register(url: URL(filePath: "/nonexistent.ttf")) == false)
    }
}

import Foundation
import Testing
import LibraryKit
@testable import ConfigKit

private func build(preset: Preset?, memoryMB: Int?, defaultPreset: Preset) throws -> ConfigDocument {
    var game = Game(title: "T", source: .managed)
    game.launch = LaunchSpec(executable: "A.EXE")
    game.settings = GameSettings(preset: preset, memoryMB: memoryMB)
    let g = GlobalConfig(defaultPreset: defaultPreset, overrides: GameSettings(memoryMB: 8),
                         rawOverrides: "[dosbox]\nmemsize = 12\n",
                         env: ConfigEnvironment(soundfontPath: nil, mt32RomDir: nil))
    return try LaunchConfigBuilder.build(game: game, cDrive: URL(fileURLWithPath: "/tmp/g"), media: [], global: g)
}

@Test func layerPrecedence() throws {
    #expect(try build(preset: .pc486, memoryMB: 64, defaultPreset: .pc386).value("dosbox", "memsize") == "64")
    #expect(try build(preset: .pc486, memoryMB: nil, defaultPreset: .pc386).value("dosbox", "memsize") == "16")
    #expect(try build(preset: .auto, memoryMB: nil, defaultPreset: .pc386).value("dosbox", "memsize") == "12")
}

@Test func defaultPresetUsedWhenGameInherits() throws {
    let d = try build(preset: nil, memoryMB: nil, defaultPreset: .pc386)
    #expect(d.value("dosbox", "memsize") == "4")
    #expect(d.value("dosbox", "machine") == "svga_et4000")
}

@Test func autoexecIncluded() throws {
    let d = try build(preset: nil, memoryMB: nil, defaultPreset: .auto)
    #expect(d.autoexec == ["mount c \"/tmp/g\"", "c:", "A.EXE"])
}

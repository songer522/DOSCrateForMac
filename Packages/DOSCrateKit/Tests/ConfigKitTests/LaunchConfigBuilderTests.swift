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

@Test func isoAndFloppyMediaInAutoexec() throws {
    var game = Game(title: "T", source: .managed)
    game.launch = LaunchSpec(executable: "A.EXE")
    let media: [(URL, MediaKind)] = [
        (URL(fileURLWithPath: "/c/media/disc.iso"), .cdrom), (URL(fileURLWithPath: "/c/media/boot.img"), .floppy),
    ]
    let d = try LaunchConfigBuilder.build(game: game, cDrive: URL(fileURLWithPath: "/tmp/g"), media: media, global: GlobalConfig())
    #expect(d.autoexec == [
        "mount c \"/tmp/g\"", "imgmount d \"/c/media/disc.iso\" -t iso",
        "imgmount a \"/c/media/boot.img\" -t floppy", "c:", "A.EXE",
    ])
}

@Test func captureDirSetAndOverridableByRawOverrides() throws {
    var game = Game(title: "T", source: .managed)
    game.launch = LaunchSpec(executable: "A.EXE")
    let captureURL = URL(fileURLWithPath: "/tmp/Doom.doscrate/art/screenshots")
    let baseDoc = try LaunchConfigBuilder.build(
        game: game,
        cDrive: URL(fileURLWithPath: "/tmp/g"),
        media: [],
        global: GlobalConfig(),
        captureDir: captureURL
    )
    #expect(baseDoc.value("capture", "capture_dir") == captureURL.path)

    let overridden = try LaunchConfigBuilder.build(
        game: game,
        cDrive: URL(fileURLWithPath: "/tmp/g"),
        media: [],
        global: GlobalConfig(rawOverrides: "[capture]\ncapture_dir = /custom/captures\n"),
        captureDir: captureURL
    )
    #expect(overridden.value("capture", "capture_dir") == "/custom/captures")
}

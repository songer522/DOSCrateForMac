import Foundation
import Testing
import LibraryKit
@testable import ConfigKit

@Suite struct LaunchConfigBuilderControllerTests {
    private let game: Game = {
        var g = Game(title: "T", source: .managed)
        g.launch = LaunchSpec(executable: "A.EXE")
        return g
    }()
    private let cDrive = URL(fileURLWithPath: "/tmp/g")

    @Test func controllerLinesAdded() throws {
        let map = URL(filePath: "/Volumes/MicroSD 1TB/dos/Doom.doscrate/.cache/controller.map")
        let doc = try LaunchConfigBuilder.build(game: game, cDrive: cDrive, media: [], global: GlobalConfig(), controllerMap: map)
        #expect(doc.value("sdl", "mapperfile") == "/Volumes/MicroSD 1TB/dos/Doom.doscrate/.cache/controller.map")
        #expect(doc.value("joystick", "joysticktype") == "hidden")
        #expect(doc.render().contains("mapperfile = /Volumes/MicroSD 1TB/dos/Doom.doscrate/.cache/controller.map\n"))
    }
    @Test func rawOverridesWin() throws {
        let g = GlobalConfig(rawOverrides: "[joystick]\njoysticktype = auto\n[sdl]\nmapperfile = mine.map\n")
        let doc = try LaunchConfigBuilder.build(game: game, cDrive: cDrive, media: [], global: g, controllerMap: URL(filePath: "/x/controller.map"))
        #expect(doc.value("joystick", "joysticktype") == "auto"); #expect(doc.value("sdl", "mapperfile") == "mine.map")
    }
    @Test func noControllerMapUnchanged() throws {
        let a = try LaunchConfigBuilder.build(game: game, cDrive: cDrive, media: [], global: GlobalConfig())
        #expect(!a.render().contains("mapperfile")); #expect(!a.render().contains("joysticktype"))
    }
}

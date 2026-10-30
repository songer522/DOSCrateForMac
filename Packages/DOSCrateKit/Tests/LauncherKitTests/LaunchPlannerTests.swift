import Foundation
import Testing
import ConfigKit
import LibraryKit
@testable import LauncherKit

@Suite struct LaunchPlannerTests {
    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
    func planArgumentsExact(withOverride: Bool, exitWhenDone: Bool) throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.touch("GAME.EXE")
        let r = f.record(executable: "GAME.EXE", exitWhenDone: exitWhenDone)
        if withOverride { try Data("[cpu]\ncycles = max\n".utf8).write(to: f.io.overrideURL(f.crate)) }
        let c = try Preflight.check(r, io: f.io, dosbox: f.dosbox)
        let plan = try LaunchPlanner.plan(r, cDrive: c, global: GlobalConfig(), dosbox: f.dosbox, io: f.io)
        var expected = ["--noprimaryconf", "--nolocalconf", "--working-dir", f.crate.path,
                        "--conf", f.crate.path + "/.cache/launch.conf"]
        if withOverride { expected += ["--conf", f.crate.path + "/override.conf"] }
        if exitWhenDone { expected.append("--exit") }
        #expect(plan.arguments == expected)
        #expect(plan.executable == f.dosbox)
        #expect(plan.workingDirectory == f.crate)
        #expect(plan.environment.isEmpty)
        #expect(plan.configURL.path == f.crate.path + "/.cache/launch.conf")
        #expect(plan.logsDirectory.path == f.crate.path + "/.cache/logs")
    }

    @Test func noExecutableNeverPassesExit() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.crate.appendingPathComponent("media"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: f.crate.appendingPathComponent("media/d.iso"))
        var r = f.record(executable: nil, exitWhenDone: true)
        r.game.media = [MediaImage(relativePath: "media/d.iso", kind: .cdrom)]
        let plan = try LaunchPlanner.plan(r, cDrive: Preflight.check(r, io: f.io, dosbox: f.dosbox),
                                          global: GlobalConfig(), dosbox: f.dosbox, io: f.io)
        #expect(!plan.arguments.contains("--exit"))
        r.game.launch.executable = ""
        let empty = try LaunchPlanner.plan(r, cDrive: Preflight.check(r, io: f.io, dosbox: f.dosbox),
                                           global: GlobalConfig(), dosbox: f.dosbox, io: f.io)
        #expect(!empty.arguments.contains("--exit"))
    }

    @Test func emptyOverrideIsIgnored() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.touch("GAME.EXE")
        try Data().write(to: f.io.overrideURL(f.crate))
        let r = f.record(executable: "GAME.EXE")
        let plan = try LaunchPlanner.plan(r, cDrive: Preflight.check(r, io: f.io, dosbox: f.dosbox),
                                          global: GlobalConfig(), dosbox: f.dosbox, io: f.io)
        #expect(plan.arguments.filter { $0 == "--conf" }.count == 1)
    }

    @Test func planWritesLaunchConf() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.touch("GAME.EXE")
        let r = f.record(executable: "GAME.EXE")
        let c = try Preflight.check(r, io: f.io, dosbox: f.dosbox)
        let plan = try LaunchPlanner.plan(r, cDrive: c, global: GlobalConfig(), dosbox: f.dosbox, io: f.io)
        let text = try String(contentsOf: plan.configURL, encoding: .utf8)
        #expect(text.contains("[autoexec]"))
        #expect(text.contains("mount c \"\(c.path)\""))
        #expect(text.contains("GAME.EXE"))
        #expect(text == LaunchPlanner.generatedConfigPreview(r, global: GlobalConfig(), io: f.io))
        #expect(FileManager.default.fileExists(atPath: plan.logsDirectory.path))
    }

    @Test func planMapsUnquotablePath() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let r = f.record(executable: "GAME.EXE")
        #expect(throws: LaunchError.unsupportedPath("/a\"b")) {
            try LaunchPlanner.plan(r, cDrive: URL(fileURLWithPath: "/a\"b"), global: GlobalConfig(), dosbox: f.dosbox, io: f.io)
        }
    }

    @Test func previewReportsErrorLine() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let r = f.record(executable: "Long Name/x.exe")
        #expect(LaunchPlanner.generatedConfigPreview(r, global: GlobalConfig(), io: f.io).hasPrefix("# error:"))
    }

    @Test func writesControllerMap() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.touch("GAME.EXE"); let r = f.record(executable: "GAME.EXE", exitWhenDone: false)
        let c = try Preflight.check(r, io: f.io, dosbox: f.dosbox)
        _ = try LaunchPlanner.plan(r, cDrive: c, global: GlobalConfig(controllerLayout: .steam), dosbox: f.dosbox, io: f.io)
        let map = f.crate.appending(path: ".cache/controller.map")
        #expect(try String(contentsOf: map, encoding: .utf8) == ControllerMap.render(.steam))
        let conf = try String(contentsOf: f.crate.appending(path: ".cache/launch.conf"), encoding: .utf8)
        #expect(conf.contains("mapperfile = \(map.path)\n")); #expect(conf.contains("joysticktype = hidden\n"))
    }

    @Test func noLayoutNoMap() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.touch("GAME.EXE"); let r = f.record(executable: "GAME.EXE", exitWhenDone: false)
        let c = try Preflight.check(r, io: f.io, dosbox: f.dosbox)
        _ = try LaunchPlanner.plan(r, cDrive: c, global: GlobalConfig(), dosbox: f.dosbox, io: f.io)
        let map = f.crate.appending(path: ".cache/controller.map")
        #expect(!FileManager.default.fileExists(atPath: map.path))
        let conf = try String(contentsOf: f.crate.appending(path: ".cache/launch.conf"), encoding: .utf8)
        #expect(!conf.contains("mapperfile")); #expect(!conf.contains("joysticktype"))
    }

    @Test func unwritableMapStillLaunches() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.touch("GAME.EXE"); let r = f.record(executable: "GAME.EXE", exitWhenDone: false)
        let map = f.crate.appending(path: ".cache/controller.map")
        try FileManager.default.createDirectory(at: map, withIntermediateDirectories: true)
        let c = try Preflight.check(r, io: f.io, dosbox: f.dosbox)
        _ = try LaunchPlanner.plan(r, cDrive: c, global: GlobalConfig(controllerLayout: .steam), dosbox: f.dosbox, io: f.io)
        let conf = try String(contentsOf: f.crate.appending(path: ".cache/launch.conf"), encoding: .utf8)
        #expect(!conf.contains("mapperfile")); #expect(!conf.contains("joysticktype"))
    }

    @Test func previewShowsControllerLines() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.touch("GAME.EXE"); let r = f.record(executable: "GAME.EXE", exitWhenDone: false)
        let map = f.crate.appending(path: ".cache/controller.map")
        let preview = LaunchPlanner.generatedConfigPreview(r, global: GlobalConfig(controllerLayout: .standard), io: f.io)
        #expect(preview.contains("mapperfile = \(map.path)\n"))
        #expect(preview.contains("joysticktype = hidden\n"))
        #expect(!FileManager.default.fileExists(atPath: map.path))
    }

    @Test func perGameJoystickModeWritesJoystickMapAndType() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.touch("GAME.EXE")
        var r = f.record(executable: "GAME.EXE", exitWhenDone: false)
        r.game.settings.controllerMode = .twoAxis
        r.game.settings.controllerBindings = ControllerBindings(leftTrigger: .space)
        let c = try Preflight.check(r, io: f.io, dosbox: f.dosbox)
        // Even if global controllerLayout is nil (global toggle off), detectedControllerLayout enables explicit per-game mode
        let global = GlobalConfig(controllerLayout: nil, detectedControllerLayout: .xboxUSB)
        _ = try LaunchPlanner.plan(r, cDrive: c, global: global, dosbox: f.dosbox, io: f.io)
        let map = f.crate.appending(path: ".cache/controller.map")
        #expect(try String(contentsOf: map, encoding: .utf8) == ControllerMap.render(
            .xboxUSB,
            mode: .twoAxis,
            bindings: ControllerBindings(leftTrigger: .space)
        ))
        let conf = try String(contentsOf: f.crate.appending(path: ".cache/launch.conf"), encoding: .utf8)
        #expect(conf.contains("mapperfile = \(map.path)\n"))
        #expect(conf.contains("joysticktype = 2axis\n"))
    }

    @Test func perGameDisabledControllerModeSkipsMapAndSetsDisabled() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.touch("GAME.EXE")
        var r = f.record(executable: "GAME.EXE", exitWhenDone: false)
        r.game.settings.controllerMode = .disabled
        let c = try Preflight.check(r, io: f.io, dosbox: f.dosbox)
        _ = try LaunchPlanner.plan(r, cDrive: c, global: GlobalConfig(controllerLayout: .standard), dosbox: f.dosbox, io: f.io)
        let map = f.crate.appending(path: ".cache/controller.map")
        #expect(!FileManager.default.fileExists(atPath: map.path))
        let conf = try String(contentsOf: f.crate.appending(path: ".cache/launch.conf"), encoding: .utf8)
        #expect(!conf.contains("mapperfile"))
        #expect(conf.contains("joysticktype = disabled\n"))
    }
}

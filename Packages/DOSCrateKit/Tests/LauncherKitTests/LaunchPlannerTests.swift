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
}

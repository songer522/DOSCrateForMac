import Foundation
import Testing
import ConfigKit
import LibraryKit
@testable import LauncherKit

@Test(.enabled(if: TestStaging.dosboxURL != nil))
func overrideConfWinsOverGeneratedAndAutoexecRuns() throws {
    let dosbox = try #require(TestStaging.dosboxURL)
    let f = try Fixture(); defer { f.cleanup() }
    var r = f.record(executable: nil, exitWhenDone: true)
    r.game.settings.memoryMB = 16
    try Data("[dosbox]\nmemsize = 32\n[autoexec]\nconfig -get memsize > MEM.TXT\n".utf8)
        .write(to: f.io.overrideURL(f.crate))
    let cDrive = try f.io.cDriveURL(for: r)
    var plan = try LaunchPlanner.plan(r, cDrive: cDrive, global: GlobalConfig(), dosbox: dosbox, io: f.io)
    plan.environment = ["SDL_VIDEODRIVER": "dummy", "SDL_AUDIODRIVER": "dummy"]

    let code = try TestStaging.run(plan.executable, arguments: plan.arguments, environment: plan.environment, timeout: 30)
    #expect(code == 0)
    let mem = try String(contentsOf: cDrive.appendingPathComponent("MEM.TXT"), encoding: .utf8)
    #expect(mem.trimmingCharacters(in: .whitespacesAndNewlines) == "32")
}

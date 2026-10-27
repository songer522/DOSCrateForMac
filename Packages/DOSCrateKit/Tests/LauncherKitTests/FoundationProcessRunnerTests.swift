import Foundation
import Testing
@testable import LauncherKit

@Suite struct FoundationProcessRunnerTests {
    private func plan(_ args: [String], in dir: URL) -> LaunchPlan {
        LaunchPlan(executable: URL(filePath: "/bin/sh"), arguments: args, workingDirectory: dir,
                   environment: ["DC_TEST": "hello"], configURL: dir.appending(path: "x.conf"), logsDirectory: dir)
    }

    @Test func capturesStdoutStderrAndExitCode() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "fpr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appending(path: "a.log")
        let p = try FoundationProcessRunner().start(plan(["-c", "echo out $DC_TEST; echo err >&2; exit 3"], in: dir), logURL: log)
        #expect(await p.waitForExit() == 3)
        #expect(await p.waitForExit() == 3)
        let text = try String(contentsOf: log, encoding: .utf8)
        #expect(text.contains("out hello") && text.contains("err"))
    }

    @Test func killStopsAProcessThatIgnoresTerminate() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "fpr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = try FoundationProcessRunner().start(plan(["-c", "trap '' TERM; echo ready; while true; do sleep 1; done"], in: dir),
                                                    logURL: dir.appending(path: "b.log"))
        try await Task.sleep(for: .milliseconds(300))
        p.terminate()
        p.kill()
        #expect(await p.waitForExit() == 9)
    }
}

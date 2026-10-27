import Foundation
import Testing
@testable import LauncherKit

final class FakeProcess: RunningProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int32, Never>?
    private var exitCode: Int32?
    private var _terminateCalled = false
    private var _killCalled = false
    private let exitOnTerminate: Int32?

    init(exitOnTerminate: Int32? = nil) { self.exitOnTerminate = exitOnTerminate }

    var terminateCalled: Bool { lock.withLock { _terminateCalled } }
    var killCalled: Bool { lock.withLock { _killCalled } }

    func terminate() {
        lock.withLock { _terminateCalled = true }
        if let c = exitOnTerminate { finish(c) }
    }
    func kill() {
        lock.withLock { _killCalled = true }
        finish(137)
    }
    func finish(_ code: Int32) {
        let c: CheckedContinuation<Int32, Never>? = lock.withLock {
            guard exitCode == nil else { return nil }
            exitCode = code
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: code)
    }
    func waitForExit() async -> Int32 {
        await withCheckedContinuation { (c: CheckedContinuation<Int32, Never>) in
            let done: Int32? = lock.withLock {
                if let e = exitCode { return e }
                continuation = c
                return nil
            }
            if let done { c.resume(returning: done) }
        }
    }
}

final class FakeRunner: ProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _started: [(plan: LaunchPlan, logURL: URL, process: FakeProcess)] = []
    let exitOnTerminate: Int32?
    init(exitOnTerminate: Int32? = nil) { self.exitOnTerminate = exitOnTerminate }
    var started: [(plan: LaunchPlan, logURL: URL, process: FakeProcess)] { lock.withLock { _started } }
    func start(_ plan: LaunchPlan, logURL: URL) throws -> any RunningProcess {
        let p = FakeProcess(exitOnTerminate: exitOnTerminate)
        lock.withLock { _started.append((plan, logURL, p)) }
        return p
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    init(_ t: Date) { self.t = t }
    var now: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
}

@MainActor
private func waitUntil(_ cond: @MainActor () -> Bool) async {
    for _ in 0..<500 where !cond() { try? await Task.sleep(for: .milliseconds(10)) }
}

@MainActor
@Suite struct SessionManagerTests {
    let logs = FileManager.default.temporaryDirectory.appending(path: "sess-\(UUID().uuidString)/logs")

    func plan() -> LaunchPlan {
        LaunchPlan(executable: URL(filePath: "/bin/true"), arguments: [], workingDirectory: logs,
                   environment: [:], configURL: logs.appending(path: "x.conf"), logsDirectory: logs)
    }

    @Test func startMarksRunningAndEndClears() async throws {
        let runner = FakeRunner()
        let m = SessionManager(runner: runner)
        let id = UUID()
        var results: [SessionResult] = []
        m.onEnded = { results.append($0) }
        try m.start(gameID: id, plan: plan())
        #expect(m.running == [id])
        runner.started[0].process.finish(0)
        await waitUntil { m.running.isEmpty }
        #expect(m.running.isEmpty)
        #expect(results.count == 1)
        #expect(results[0].gameID == id && results[0].exitCode == 0 && !results[0].unexpected)
    }

    @Test func secondStartThrowsAlreadyRunning() throws {
        let m = SessionManager(runner: FakeRunner())
        let id = UUID()
        try m.start(gameID: id, plan: plan())
        #expect(throws: LaunchError.alreadyRunning) { try m.start(gameID: id, plan: plan()) }
    }

    @Test func twoGamesRunConcurrently() throws {
        let runner = FakeRunner()
        let m = SessionManager(runner: runner)
        let a = UUID(), b = UUID()
        try m.start(gameID: a, plan: plan())
        try m.start(gameID: b, plan: plan())
        #expect(m.running == [a, b])
        #expect(runner.started.count == 2)
    }

    @Test func durationFromInjectedClock() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let runner = FakeRunner()
        let m = SessionManager(runner: runner, now: { clock.now })
        var results: [SessionResult] = []
        m.onEnded = { results.append($0) }
        try m.start(gameID: UUID(), plan: plan())
        clock.advance(42)
        runner.started[0].process.finish(0)
        await waitUntil { !results.isEmpty }
        #expect(results.first?.duration == 42)
    }

    @Test func unexpectedExitIsReportedWithLog() async throws {
        let runner = FakeRunner()
        let m = SessionManager(runner: runner)
        var results: [SessionResult] = []
        m.onEnded = { results.append($0) }
        try m.start(gameID: UUID(), plan: plan())
        runner.started[0].process.finish(1)
        await waitUntil { !results.isEmpty }
        let r = try #require(results.first)
        #expect(r.unexpected && r.exitCode == 1)
        #expect(r.logURL.deletingLastPathComponent().standardizedFileURL == logs.standardizedFileURL)
        #expect(r.logURL.pathExtension == "log")
        #expect(r.logURL == runner.started[0].logURL)
    }

    @Test func userStopIsNotUnexpected() async throws {
        let runner = FakeRunner(exitOnTerminate: 143)
        let m = SessionManager(runner: runner)
        let id = UUID()
        var results: [SessionResult] = []
        m.onEnded = { results.append($0) }
        try m.start(gameID: id, plan: plan())
        m.stop(gameID: id)
        await waitUntil { !results.isEmpty }
        #expect(runner.started[0].process.terminateCalled)
        #expect(results.first?.exitCode == 143)
        #expect(results.first?.unexpected == false)
    }

    @Test func stopEscalatesToKillAfterGrace() async throws {
        let runner = FakeRunner()
        let m = SessionManager(runner: runner, killGrace: .milliseconds(50))
        let id = UUID()
        try m.start(gameID: id, plan: plan())
        m.stop(gameID: id)
        let p = runner.started[0].process
        await waitUntil { p.killCalled }
        #expect(p.terminateCalled && p.killCalled)
        await waitUntil { m.running.isEmpty }
        #expect(m.running.isEmpty)
    }

    @Test func stopDoesNotKillIfProcessExitsWithinGrace() async throws {
        let runner = FakeRunner(exitOnTerminate: 0)
        let m = SessionManager(runner: runner, killGrace: .milliseconds(50))
        let id = UUID()
        try m.start(gameID: id, plan: plan())
        m.stop(gameID: id)
        await waitUntil { m.running.isEmpty }
        try await Task.sleep(for: .milliseconds(120))
        #expect(!runner.started[0].process.killCalled)
    }

    @Test func startPrunesOldLogsAndCreatesDirectory() throws {
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: logs.deletingLastPathComponent()) }
        for i in 1...8 { try Data().write(to: logs.appending(path: "2020010\(i)-000000.log")) }
        let m = SessionManager(runner: FakeRunner())
        try m.start(gameID: UUID(), plan: plan())
        #expect(try FileManager.default.contentsOfDirectory(atPath: logs.path).count == 5)
    }
}

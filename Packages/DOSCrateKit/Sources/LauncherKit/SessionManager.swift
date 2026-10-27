import Foundation
import Observation

public struct SessionResult: Sendable, Equatable {
    public var gameID: UUID
    public var exitCode: Int32
    public var duration: TimeInterval
    public var logURL: URL
    /// True when the exit code is non-zero and the user did not stop the session.
    public var unexpected: Bool
}

@MainActor @Observable
public final class SessionManager {
    public private(set) var running: Set<UUID> = []
    public var onEnded: (@MainActor (SessionResult) -> Void)?

    @ObservationIgnored private let runner: any ProcessRunner
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let killGrace: Duration
    @ObservationIgnored private var processes: [UUID: any RunningProcess] = [:]
    @ObservationIgnored private var stopped: Set<UUID> = []

    public init(runner: any ProcessRunner = FoundationProcessRunner(),
                now: @escaping @Sendable () -> Date = Date.init,
                killGrace: Duration = .seconds(5)) {
        self.runner = runner
        self.now = now
        self.killGrace = killGrace
    }

    public func start(gameID: UUID, plan: LaunchPlan) throws(LaunchError) {
        guard !running.contains(gameID) else { throw .alreadyRunning }
        let started = now()
        let logURL = plan.logsDirectory.appending(path: Self.logName(started), directoryHint: .notDirectory)
        let process: any RunningProcess
        do {
            try FileManager.default.createDirectory(at: plan.logsDirectory, withIntermediateDirectories: true)
            try LogRotation.prune(plan.logsDirectory, keep: 5)
            process = try runner.start(plan, logURL: logURL)
        } catch let e as LaunchError {
            throw e
        } catch {
            throw .sourceUnreachable(path: plan.logsDirectory.path)
        }
        running.insert(gameID)
        processes[gameID] = process
        stopped.remove(gameID)
        Task { @MainActor [weak self] in
            let code = await process.waitForExit()
            self?.ended(gameID: gameID, code: code, started: started, logURL: logURL)
        }
    }

    public func stop(gameID: UUID) {
        guard let process = processes[gameID] else { return }
        stopped.insert(gameID)
        process.terminate()
        let grace = killGrace
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: grace)
            // Only escalate if this same process is still the running session.
            if let self, let current = self.processes[gameID], self.isSame(current, process) {
                process.kill()
            }
        }
    }

    private func isSame(_ a: any RunningProcess, _ b: any RunningProcess) -> Bool {
        (a as AnyObject) === (b as AnyObject)
    }

    private func ended(gameID: UUID, code: Int32, started: Date, logURL: URL) {
        let wasStopped = stopped.contains(gameID)
        processes[gameID] = nil
        stopped.remove(gameID)
        running.remove(gameID)
        onEnded?(SessionResult(gameID: gameID, exitCode: code, duration: now().timeIntervalSince(started),
                               logURL: logURL, unexpected: code != 0 && !wasStopped))
    }

    private static func logName(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date) + ".log"
    }
}

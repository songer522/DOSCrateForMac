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

    /// Session logs kept per game, including the current one.
    nonisolated public static let keptLogs = 5

    public struct PreparedSession: Sendable {
        public let plan: LaunchPlan
        public let started: Date
        public let logURL: URL
        public let log: FileHandle?

        public func discard() {
            try? log?.close()
        }
    }

    nonisolated public func prepare(_ plan: LaunchPlan) throws(LaunchError) -> PreparedSession {
        let started = now()
        let logURL = plan.logsDirectory.appending(path: Self.logName(started), directoryHint: .notDirectory)
        // Log housekeeping must never stop a launch: keep 4 old logs so the new one makes 5.
        try? FileManager.default.createDirectory(at: plan.logsDirectory, withIntermediateDirectories: true)
        try? LogRotation.prune(plan.logsDirectory, keep: Self.keptLogs - 1)
        do {
            let log = try (runner as? FoundationProcessRunner)?.openLog(at: logURL)
            return PreparedSession(plan: plan, started: started, logURL: logURL, log: log)
        } catch let e as LaunchError {
            throw e
        } catch {
            throw .launchFailed(error.localizedDescription)
        }
    }

    public func start(gameID: UUID, prepared: PreparedSession) throws(LaunchError) {
        guard !running.contains(gameID) else {
            prepared.discard()
            throw .alreadyRunning
        }
        let process: any RunningProcess
        do {
            if let log = prepared.log, let foundation = runner as? FoundationProcessRunner {
                process = try foundation.start(prepared.plan, log: log)
            } else {
                process = try runner.start(prepared.plan, logURL: prepared.logURL)
            }
        } catch let e as LaunchError {
            throw e
        } catch {
            throw .launchFailed(error.localizedDescription)
        }
        running.insert(gameID)
        processes[gameID] = process
        stopped.remove(gameID)
        let started = prepared.started
        let logURL = prepared.logURL
        Task { @MainActor [weak self] in
            let code = await process.waitForExit()
            self?.ended(gameID: gameID, code: code, started: started, logURL: logURL)
        }
    }

    public func start(gameID: UUID, plan: LaunchPlan) throws(LaunchError) {
        guard !running.contains(gameID) else { throw .alreadyRunning }
        let prepared = try prepare(plan)
        try start(gameID: gameID, prepared: prepared)
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

    nonisolated private static func logName(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date) + ".log"
    }
}

extension FoundationProcessRunner {
    func openLog(at logURL: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: logURL.path])
        }
        return try FileHandle(forWritingTo: logURL)
    }

    func start(_ plan: LaunchPlan, log: FileHandle) throws -> any RunningProcess {
        let process = Process()
        process.executableURL = plan.executable
        process.arguments = plan.arguments
        process.currentDirectoryURL = plan.workingDirectory
        process.environment = ProcessInfo.processInfo.environment.merging(plan.environment) { _, new in new }
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        let running = FoundationRunningProcess(process)
        process.terminationHandler = { p in
            try? log.close()
            running.finished(p.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            try? log.close()
            throw error
        }
        return running
    }
}

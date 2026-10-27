import Foundation

public protocol RunningProcess: Sendable {
    func terminate()
    func kill()
    func waitForExit() async -> Int32
}

public protocol ProcessRunner: Sendable {
    func start(_ plan: LaunchPlan, logURL: URL) throws -> any RunningProcess
}

public struct FoundationProcessRunner: ProcessRunner {
    public init() {}

    public func start(_ plan: LaunchPlan, logURL: URL) throws -> any RunningProcess {
        let fm = FileManager.default
        guard fm.createFile(atPath: logURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: logURL.path])
        }
        let log = try FileHandle(forWritingTo: logURL)
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

final class FoundationRunningProcess: RunningProcess, @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var exitCode: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    init(_ process: Process) { self.process = process }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    func kill() {
        let pid = process.processIdentifier
        if process.isRunning, pid > 0 { _ = Darwin.kill(pid, SIGKILL) }
    }

    func finished(_ code: Int32) {
        let toResume: [CheckedContinuation<Int32, Never>] = lock.withLock {
            exitCode = code
            defer { waiters = [] }
            return waiters
        }
        for w in toResume { w.resume(returning: code) }
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { (c: CheckedContinuation<Int32, Never>) in
            let done: Int32? = lock.withLock {
                if let e = exitCode { return e }
                waiters.append(c)
                return nil
            }
            if let done { c.resume(returning: done) }
        }
    }
}

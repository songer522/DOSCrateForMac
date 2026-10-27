import Foundation
import Testing

enum TestStaging {
    /// `<repo>/Vendor/DOSBox Staging.app/Contents/MacOS/dosbox`, or nil if missing.
    static let dosboxURL: URL? = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        url = url.appendingPathComponent("Vendor/DOSBox Staging.app/Contents/MacOS/dosbox")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }()

    /// Runs `executable`, terminating it after `timeout` seconds. Returns the exit code, or nil on timeout.
    static func run(
        _ executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval
    ) throws -> Int32? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 5)
            return nil
        }
        return process.terminationStatus
    }
}

@Test(.enabled(if: TestStaging.dosboxURL != nil))
func headlessRunWritesFile() throws {
    let dosbox = try #require(TestStaging.dosboxURL)
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("doscrate-\(UUID().uuidString)")
    let cDir = tmp.appendingPathComponent("c dir")
    try FileManager.default.createDirectory(at: cDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let exitCode = try TestStaging.run(
        dosbox,
        arguments: [
            "--noprimaryconf", "--nolocalconf",
            "-c", "mount c \"\(cDir.path)\"",
            "-c", "c:",
            "-c", "echo ok > OK.TXT",
            "--exit",
        ],
        environment: ["SDL_VIDEODRIVER": "dummy", "SDL_AUDIODRIVER": "dummy"],
        timeout: 30)

    #expect(exitCode == 0)
    let contents = try String(contentsOf: cDir.appendingPathComponent("OK.TXT"), encoding: .utf8)
    #expect(contents.trimmingCharacters(in: .whitespacesAndNewlines) == "ok")
}

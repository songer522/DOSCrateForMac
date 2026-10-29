import Foundation

public enum DittoError: Error, Equatable, Sendable {
    case failed(String)
}

public enum Ditto {
    public static func unzip(_ zip: URL, into dir: URL) async throws {
        let stderr: (status: Int32, text: String) = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(filePath: "/usr/bin/ditto")
                process.arguments = ["-x", "-k", zip.path, dir.path]
                let pipe = Pipe()
                process.standardError = pipe
                process.standardOutput = FileHandle.nullDevice
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        guard stderr.status == 0 else {
            throw DittoError.failed(stderr.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

import Foundation

public enum LogRotation {
    /// Keeps the newest `keep` `.log` files in `dir` (ordered by name, which is a timestamp) and deletes the rest.
    /// A missing directory is not an error; files that are not `.log` files are never touched.
    public static func prune(_ dir: URL, keep: Int) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return }
        let logs = try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".log") }.sorted()
        for name in logs.dropLast(max(keep, 0)) {
            try fm.removeItem(at: dir.appending(path: name, directoryHint: .notDirectory))
        }
    }
}

import Foundation
import Testing
@testable import LauncherKit

@Suite struct LogRotationTests {
    @Test func pruneKeepsNewestFive() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "logrot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = (1...8).map { "20260101-00000\($0).log" }
        for n in names.reversed() { try Data("x".utf8).write(to: dir.appending(path: n)) }
        try LogRotation.prune(dir, keep: 5)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(left == Array(names.suffix(5)))
    }

    @Test func pruneToleratesMissingDirectoryAndLeavesNonLogFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "logrot-\(UUID().uuidString)")
        try LogRotation.prune(dir, keep: 5)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appending(path: "notes.txt"))
        try Data().write(to: dir.appending(path: "20260101-000001.log"))
        try Data().write(to: dir.appending(path: "20260101-000002.log"))
        try LogRotation.prune(dir, keep: 1)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(left == ["20260101-000002.log", "notes.txt"])
    }
}

import Foundation
import Testing
@testable import ImportKit

func makeImportTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "doscrate-import-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
func touch(_ root: URL, _ path: String, bytes: Int = 4) throws -> URL {
    let url = root.appending(path: path, directoryHint: .notDirectory)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: bytes).write(to: url)
    return url
}

struct ExecutableRankerTests {
    @Test func unreadableEntryDoesNotFailRanking() throws {
        let root = try makeImportTempDir()
        let locked = root.appending(path: "LOCKED", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }
        try touch(root, "GAME.EXE")
        try touch(root, "LOCKED/OTHER.EXE")
        // Readable but not searchable: the walk can list OTHER.EXE but can't read its attributes.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
        let ranked = try ExecutableRanker.rank(root: root, title: "Game")
        #expect(ranked.map(\.relativePath) == ["GAME.EXE"])
    }

    @Test func prefersTitleMatchOverSetup() throws {
        let root = try makeImportTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch(root, "KEEN1.EXE")
        try touch(root, "SETUP.EXE")
        let ranked = try ExecutableRanker.rank(root: root, title: "Commander Keen 1")
        #expect(ranked.map(\.relativePath) == ["KEEN1.EXE", "SETUP.EXE"])
        #expect(ranked[0].score == 100 + 50 + 20)
        #expect(ranked[1].score == 100 + 20 - 80)
    }

    @Test func rootBeatsSubdir() throws {
        let root = try makeImportTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch(root, "sub/GAME.EXE", bytes: 100)
        try touch(root, "RUN.BAT")
        let ranked = try ExecutableRanker.rank(root: root, title: "Zork")
        #expect(ranked.map(\.relativePath) == ["RUN.BAT", "sub/GAME.EXE"])
        #expect(ranked[1].score == 90)
    }

    @Test func utilitiesRankedLast() throws {
        let root = try makeImportTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch(root, "DOS4GW.EXE", bytes: 500)
        try touch(root, "GAME.EXE")
        let ranked = try ExecutableRanker.rank(root: root, title: "Something")
        #expect(ranked.map(\.relativePath) == ["GAME.EXE", "DOS4GW.EXE"])
    }

    @Test func emptyFolderGivesEmptyList() throws {
        let root = try makeImportTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch(root, "README.TXT")
        #expect(try ExecutableRanker.rank(root: root, title: "X").isEmpty)
    }

    @Test func ignoresDepthBeyond4() throws {
        let root = try makeImportTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch(root, "a/b/c/d/FOUR.EXE")
        try touch(root, "a/b/c/d/e/FIVE.EXE")
        let ranked = try ExecutableRanker.rank(root: root, title: "X")
        #expect(ranked.map(\.relativePath) == ["a/b/c/d/FOUR.EXE"])
    }

    @Test func tiesPreferLargerThenName() throws {
        let root = try makeImportTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch(root, "B.EXE", bytes: 10)
        try touch(root, "A.EXE", bytes: 10)
        try touch(root, "C.exe", bytes: 99)
        try touch(root, ".hidden.exe")
        #expect(try ExecutableRanker.rank(root: root, title: "Q").map(\.relativePath) == ["C.exe", "A.EXE", "B.EXE"])
    }
}

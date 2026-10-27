import Foundation
import Testing
@testable import LibraryKit

func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "doscrate-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct CrateIOTests {
    let io = CrateIO()

    @Test func crateNameSanitizing() {
        #expect(CrateIO.crateName(for: "Doom: Episode 1/2") == "Doom- Episode 1-2.doscrate")
        #expect(CrateIO.crateName(for: "..hidden") == "hidden.doscrate")
        #expect(CrateIO.crateName(for: "") == "Untitled.doscrate")
        #expect(CrateIO.crateName(for: " . ") == "Untitled.doscrate")
    }

    @Test func makeCrateUniquifies() throws {
        let lib = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: lib) }
        #expect(try io.makeCrate(title: "Keen", in: lib).lastPathComponent == "Keen.doscrate")
        #expect(try io.makeCrate(title: "Keen", in: lib).lastPathComponent == "Keen 2.doscrate")
    }

    @Test func brokenJSONIsRenamedAndFlagged() throws {
        let lib = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: lib) }
        let crate = try io.makeCrate(title: "Bad", in: lib)
        try Data("{".utf8).write(to: crate.appending(path: "game.json"))
        let record = io.loadRecord(at: crate)
        guard case .needsRepair = record.status else { Issue.record("expected needsRepair, got \(record.status)"); return }
        #expect(FileManager.default.fileExists(atPath: crate.appending(path: "game.json.broken").path))
        #expect(!FileManager.default.fileExists(atPath: crate.appending(path: "game.json").path))
        #expect(record.game.title == "Bad")
        #expect(io.loadRecord(at: crate).id == record.id)
    }

    @Test func scanFindsOnlyCrates() async throws {
        let lib = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: lib) }
        for title in ["Zork", "Alley"] {
            let crate = try io.makeCrate(title: title, in: lib)
            try io.save(Game(title: title, source: .managed), extra: [:], to: crate)
        }
        try FileManager.default.createDirectory(at: lib.appending(path: "plain"), withIntermediateDirectories: true)
        try Data().write(to: lib.appending(path: "file.doscrate.txt"))
        let records = await io.scan(library: lib)
        #expect(records.map(\.game.title) == ["Alley", "Zork"])
    }

    @Test func managedCDriveIsFilesPlusRoot() throws {
        var game = Game(title: "G", source: .managed)
        game.launch.driveCRoot = "GAME"
        let crate = URL(filePath: "/tmp/G.doscrate", directoryHint: .isDirectory)
        let url = try io.cDriveURL(for: GameRecord(game: game, crateURL: crate))
        #expect(url.path == "/tmp/G.doscrate/files/GAME")
    }

    @Test func referencedCDriveResolvesBookmark() throws {
        let lib = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: lib) }
        let source = lib.appending(path: "src", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let bookmark = try CrateIO.makeBookmark(for: source)
        let crate = try io.makeCrate(title: "Ref", in: lib)
        let game = Game(title: "Ref", source: .referenced(path: source.path, bookmark: bookmark))
        try io.save(game, extra: [:], to: crate)

        let record = io.loadRecord(at: crate)
        #expect(record.status == .ok)
        let resolved = try io.cDriveURL(for: record)
        #expect(resolved.resolvingSymlinksInPath().path == source.resolvingSymlinksInPath().path)

        try FileManager.default.removeItem(at: source)
        #expect(throws: LibraryError.sourceUnreachable(path: source.path)) { try io.cDriveURL(for: record) }
        #expect(io.loadRecord(at: crate).status == .missingSource)
    }
}

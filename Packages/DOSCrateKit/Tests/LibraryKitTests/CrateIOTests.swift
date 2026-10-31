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

    func brokenFiles(in crate: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: crate.path)
            .filter { $0.hasPrefix("game.json.") && $0.hasSuffix(".broken") }.sorted()
    }

    func writeJSON(_ object: [String: Any], to crate: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: crate.appending(path: "game.json"))
    }

    @Test func brokenJSONIsRenamedAndFlagged() throws {
        let lib = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: lib) }
        let crate = try io.makeCrate(title: "Bad", in: lib)
        try Data("{".utf8).write(to: crate.appending(path: "game.json"))
        let record = io.loadRecord(at: crate)
        guard case .needsRepair = record.status else { Issue.record("expected needsRepair, got \(record.status)"); return }
        #expect(try brokenFiles(in: crate).count == 1)
        #expect(!FileManager.default.fileExists(atPath: crate.appending(path: "game.json").path))
        #expect(record.game.title == "Bad")
        #expect(io.loadRecord(at: crate).id == record.id)
    }

    @Test func secondBreakageNeverOverwritesTheFirstBrokenFile() throws {
        let lib = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: lib) }
        let crate = try io.makeCrate(title: "Bad", in: lib)
        try Data("{ first".utf8).write(to: crate.appending(path: "game.json"))
        _ = io.loadRecord(at: crate)
        try Data("{ second".utf8).write(to: crate.appending(path: "game.json"))
        _ = io.loadRecord(at: crate)
        let names = try brokenFiles(in: crate)
        #expect(names.count == 2)
        let contents = try Set(names.map { try String(contentsOf: crate.appending(path: $0), encoding: .utf8) })
        #expect(contents == ["{ first", "{ second"])
    }

    @Test func newerSchemaIsReadOnlyAndLeftAlone() throws {
        let lib = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: lib) }
        let crate = try io.makeCrate(title: "Future", in: lib)
        let id = UUID()
        try writeJSON(["schemaVersion": 2, "id": id.uuidString, "title": "From The Future",
                       "source": ["type": "cloud"], "hologram": true], to: crate)
        let before = try Data(contentsOf: crate.appending(path: "game.json"))
        let record = io.loadRecord(at: crate)
        guard case .readOnly = record.status else { Issue.record("expected readOnly, got \(record.status)"); return }
        #expect(record.game.title == "From The Future")
        #expect(record.id == id)
        #expect(try Data(contentsOf: crate.appending(path: "game.json")) == before)
        #expect(try brokenFiles(in: crate).isEmpty)
    }

    @Test func unknownEnumValueIsReadOnlyNotBroken() throws {
        let lib = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: lib) }
        let crate = try io.makeCrate(title: "Odd", in: lib)
        try writeJSON(["schemaVersion": 1, "id": UUID().uuidString, "title": "Odd",
                       "source": ["type": "managed"],
                       "media": [["relativePath": "media/x.tap", "kind": "tape"]],
                       "settings": ["preset": "pentium4", "memoryMB": 16, "cycles": "turbo"]], to: crate)
        let before = try Data(contentsOf: crate.appending(path: "game.json"))
        let record = io.loadRecord(at: crate)
        guard case .readOnly = record.status else { Issue.record("expected readOnly, got \(record.status)"); return }
        #expect(record.game.settings.preset == nil)
        #expect(record.game.settings.cycles == nil)
        #expect(record.game.settings.memoryMB == 16)
        #expect(try Data(contentsOf: crate.appending(path: "game.json")) == before)
        #expect(try brokenFiles(in: crate).isEmpty)
    }

    @Test func duplicateIDsAcrossCratesAreSplit() async throws {
        let lib = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: lib) }
        let game = Game(title: "Keen", source: .managed)
        let first = try io.makeCrate(title: "Keen", in: lib)
        let second = try io.makeCrate(title: "Keen", in: lib)
        try io.save(game, extra: ["futureField": .string("kept")], to: first)
        try io.save(game, extra: ["futureField": .string("kept")], to: second)
        let records = await io.scan(library: lib)
        #expect(Set(records.map(\.id)).count == 2)
        #expect(records.first { $0.crateURL.lastPathComponent == first.lastPathComponent }?.id == game.id)
        let onDisk = try GameFileCodec.decode(Data(contentsOf: second.appending(path: "game.json")))
        #expect(onDisk.game.id != game.id)
        #expect(onDisk.extra["futureField"] == .string("kept"))
        #expect(records.first { $0.crateURL.lastPathComponent == second.lastPathComponent }?.id == onDisk.game.id)
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

    @Test func cDriveURLRejectsParentTraversalAndAbsolutePaths() {
        let crate = URL(filePath: "/tmp/G.doscrate", directoryHint: .isDirectory)
        for bad in ["..", "../outside", "SUB/../..", "SUB\\..", "/etc", "\\WINDOWS", "."] {
            var game = Game(title: "G", source: .managed)
            game.launch.driveCRoot = bad
            #expect(throws: LibraryError.invalidDriveCRoot(path: bad)) {
                _ = try io.cDriveURL(for: GameRecord(game: game, crateURL: crate))
            }
        }
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

    @Test func artPathsLiveUnderArtFolder() throws {
        let lib = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: lib) }
        let crate = try io.makeCrate(title: "Doom", in: lib)
        #expect(io.artURL(crate).path.hasSuffix("/art"))
        #expect(io.backURL(crate).path.hasSuffix("/art/back.png"))
        #expect(io.discURL(crate).path.hasSuffix("/art/disc.png"))
        #expect(io.logoURL(crate).path.hasSuffix("/art/logo.png"))
        #expect(io.screenshotURL(crate, index: 3).path.hasSuffix("/art/screenshots/03.png"))
        #expect(io.screenshotURLs(crate).isEmpty)

        let s2 = io.screenshotURL(crate, index: 2)
        let s1 = io.screenshotURL(crate, index: 1)
        try FileManager.default.createDirectory(at: s1.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: s2)
        try Data([1]).write(to: s1)
        #expect(io.screenshotURLs(crate).map(\.lastPathComponent) == ["01.png", "02.png"])
    }

    @Test func addScreenshotCreatesUniqueFilesAndNeverOverwrites() throws {
        let lib = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: lib) }
        let crate = try io.makeCrate(title: "Doom", in: lib)
        #expect(io.screenshotsURL(crate).path.hasSuffix("/art/screenshots"))

        let first = try io.addScreenshot(pngData: Data([1, 2, 3]), in: crate)
        let second = try io.addScreenshot(pngData: Data([4, 5, 6]), in: crate)
        #expect(first.lastPathComponent == "screenshot-01.png")
        #expect(second.lastPathComponent == "screenshot-02.png")
        #expect(try Data(contentsOf: first) == Data([1, 2, 3]))
        #expect(try Data(contentsOf: second) == Data([4, 5, 6]))
        #expect(io.screenshotURLs(crate).map(\.lastPathComponent) == ["screenshot-01.png", "screenshot-02.png"])
    }
}

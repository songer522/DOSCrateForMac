import Foundation
import Testing
@testable import LibraryKit

struct LibraryQueryTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func record(_ title: String, year: Int? = nil, developer: String? = nil, publisher: String? = nil,
                genre: String? = nil, tags: [String] = [],
                favorite: Bool = false, lastPlayed: Date? = nil, seconds: Double = 0,
                status: RecordStatus = .ok) -> GameRecord {
        var g = Game(title: title, source: .managed)
        g.year = year; g.developer = developer; g.publisher = publisher; g.genre = genre
        g.tags = tags; g.isFavorite = favorite
        g.stats = PlayStats(totalPlaySeconds: seconds, lastPlayed: lastPlayed, launchCount: 0)
        return GameRecord(game: g, crateURL: URL(filePath: "/tmp/\(title).doscrate"), status: status)
    }

    func titles(_ q: LibraryQuery, _ rs: [GameRecord]) -> [String] {
        q.apply(to: rs, now: now).map(\.game.title)
    }

    @Test func searchMatchesTitleDeveloperPublisherGenreYearTag() {
        let rs = [
            record("DOOM", year: 1993, developer: "id Software", publisher: "id Software", genre: "Shooter", tags: ["fps"]),
            record("Keen", year: 1990, developer: "id Software", publisher: "Apogee", genre: "Platform", tags: ["platformer"]),
            record("Nobunaga", year: 1990, developer: "Koei", publisher: "Koei Co., Ltd.", genre: "Strategy"),
        ]
        #expect(titles(LibraryQuery(search: "dôom"), rs) == ["DOOM"])
        #expect(titles(LibraryQuery(search: "APOGEE"), rs) == ["Keen"])
        #expect(titles(LibraryQuery(search: "koei"), rs) == ["Nobunaga"])
        #expect(titles(LibraryQuery(search: "strategy"), rs) == ["Nobunaga"])
        #expect(titles(LibraryQuery(search: "1993"), rs) == ["DOOM"])
        #expect(titles(LibraryQuery(search: "platform"), rs) == ["Keen"])
        #expect(titles(LibraryQuery(search: "  "), rs).count == 3)
    }

    @Test func recentIs30Days() {
        let day: TimeInterval = 86_400
        let rs = [
            record("In", lastPlayed: now.addingTimeInterval(-29 * day)),
            record("Out", lastPlayed: now.addingTimeInterval(-31 * day)),
            record("Never"),
        ]
        #expect(titles(LibraryQuery(filter: .recent), rs) == ["In"])
    }

    @Test func favoritesFilter() {
        let rs = [record("A", favorite: true), record("B")]
        #expect(titles(LibraryQuery(filter: .favorites), rs) == ["A"])
    }

    @Test func tagFilter() {
        let rs = [record("A", tags: ["rpg"]), record("B", tags: ["fps"]), record("C", tags: [" RPG "])]
        #expect(titles(LibraryQuery(filter: .tag("rpg")), rs) == ["A", "C"])
        #expect(titles(LibraryQuery(filter: .tag("RPG")), rs) == ["A", "C"])
        #expect(titles(LibraryQuery(filter: .tag(" rpg ")), rs) == ["A", "C"])
    }

    @Test func sortByLastPlayedNilsLast() {
        let rs = [
            record("Never"),
            record("Old", lastPlayed: now.addingTimeInterval(-1000)),
            record("New", lastPlayed: now.addingTimeInterval(-10)),
        ]
        #expect(titles(LibraryQuery(sort: .lastPlayed), rs) == ["New", "Old", "Never"])
    }

    @Test func titleSortIgnoresLeadingThe() {
        let rs = [record("Zork"), record("The Secret of Monkey Island"), record("Alone in the Dark")]
        #expect(titles(LibraryQuery(sort: .title), rs) == ["Alone in the Dark", "The Secret of Monkey Island", "Zork"])
    }

    @Test func yearAndPlayTimeSorts() {
        let rs = [record("B", year: 1995, seconds: 5), record("A", year: nil, seconds: 50), record("C", year: 1990, seconds: 10)]
        #expect(titles(LibraryQuery(sort: .year), rs) == ["C", "B", "A"])
        #expect(titles(LibraryQuery(sort: .playTime), rs) == ["A", "C", "B"])
    }

    @Test func needsRepairBypassesFilterButNotSearch() {
        let rs = [record("Broken", status: .needsRepair(reason: "x")), record("Fine")]
        #expect(titles(LibraryQuery(filter: .favorites), rs) == ["Broken"])
        #expect(titles(LibraryQuery(filter: .favorites, search: "brok"), rs) == ["Broken"])
        #expect(titles(LibraryQuery(search: "zzz"), rs).isEmpty)
    }

    @Test func allTagsSortedUnique() {
        let rs = [record("A", tags: ["rpg", "fps"]), record("B", tags: ["fps", "Adventure", "RPG"])]
        #expect(allTags(in: rs) == ["Adventure", "fps", "rpg"])
    }

    @Test func filterByGenreYearPublisherDeveloper() {
        let rs = [
            record("Shannara", year: 1995, developer: "Legend Entertainment", publisher: "Legend Entertainment", genre: "Adventure"),
            record("Romance of the Three Kingdoms", year: 1988, developer: "Koei", publisher: "Koei Co., Ltd.", genre: "Strategy, Role-Playing"),
            record("Uncharted Waters", year: 1991, developer: "Koei", publisher: "Koei Co., Ltd.", genre: "Role-Playing; Simulation"),
            record("DOOM", year: 1993, developer: "id Software", publisher: "id Software", genre: "Shooter"),
        ]

        #expect(titles(LibraryQuery(genre: "Adventure"), rs) == ["Shannara"])
        #expect(titles(LibraryQuery(genre: "role-playing"), rs) == ["Romance of the Three Kingdoms", "Uncharted Waters"])
        #expect(titles(LibraryQuery(year: 1993), rs) == ["DOOM"])
        #expect(titles(LibraryQuery(publisher: "Koei Co., Ltd."), rs) == ["Romance of the Three Kingdoms", "Uncharted Waters"])
        #expect(titles(LibraryQuery(developer: "Legend Entertainment"), rs) == ["Shannara"])

        // Combined filters
        var combined = LibraryQuery(genre: "Role-Playing", year: 1991, publisher: "Koei Co., Ltd.", developer: "Koei")
        #expect(combined.hasActiveMetadataFilter)
        #expect(titles(combined, rs) == ["Uncharted Waters"])

        combined.clearMetadataFilters()
        #expect(!combined.hasActiveMetadataFilter)
        #expect(titles(combined, rs).count == 4)
    }

    @Test func allMetadataOptionsExtractedSortedUnique() {
        let rs = [
            record("A", year: 1995, developer: "Legend Entertainment", publisher: "Sierra", genre: "Adventure, Puzzle"),
            record("B", year: 1990, developer: "Koei", publisher: "Koei Co., Ltd.", genre: "Strategy; adventure"),
            record("C", year: 1995, developer: "koei", publisher: "   ", genre: ""),
        ]
        #expect(allGenres(in: rs) == ["Adventure", "Puzzle", "Strategy"])
        #expect(allYears(in: rs) == [1990, 1995])
        #expect(allPublishers(in: rs) == ["Koei Co., Ltd.", "Sierra"])
        #expect(allDevelopers(in: rs) == ["Koei", "Legend Entertainment"])
    }

    @Test func needsAttentionChecksStatusCDriveAndExecutable() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "query-attention-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        func makeManagedCrate(_ name: String, createFiles: Bool = true, executable: String? = nil, driveCRoot: String = "", status: RecordStatus = .ok) throws -> GameRecord {
            let crate = root.appending(path: "\(name).doscrate", directoryHint: .isDirectory)
            let files = crate.appending(path: "files", directoryHint: .isDirectory)
            if createFiles {
                try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: crate, withIntermediateDirectories: true)
            }
            var g = Game(title: name, source: .managed)
            g.launch.executable = executable
            g.launch.driveCRoot = driveCRoot
            return GameRecord(game: g, crateURL: crate, status: status)
        }

        // Healthy record with existing executable
        let healthy = try makeManagedCrate("Healthy", executable: "DOOM.EXE")
        try Data("exe".utf8).write(to: healthy.crateURL.appending(path: "files/DOOM.EXE"))
        #expect(!LibraryQuery.needsAttention(healthy))
        #expect(!healthy.needsAttention)

        // Healthy record with no executable configured
        let noExe = try makeManagedCrate("NoExe", executable: nil)
        #expect(!LibraryQuery.needsAttention(noExe))

        // Non-ok statuses need attention even when files exist
        let repair = try makeManagedCrate("Repair", status: .needsRepair(reason: "broken"))
        let missingSource = try makeManagedCrate("MissingSource", status: .missingSource)
        let readOnly = try makeManagedCrate("ReadOnly", status: .readOnly(reason: "newer"))
        #expect(LibraryQuery.needsAttention(repair))
        #expect(LibraryQuery.needsAttention(missingSource))
        #expect(LibraryQuery.needsAttention(readOnly))

        // Missing C: folder (`files/` deleted or missing `driveCRoot` subfolder)
        let noFiles = try makeManagedCrate("NoFiles", createFiles: false)
        let missingSubfolder = try makeManagedCrate("MissingSub", driveCRoot: "SUBDIR")
        #expect(LibraryQuery.needsAttention(noFiles))
        #expect(LibraryQuery.needsAttention(missingSubfolder))

        // Referenced game whose external folder was removed after bookmark creation
        let extFolder = root.appending(path: "ExternalGame", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: extFolder, withIntermediateDirectories: true)
        let bookmark = try CrateIO.makeBookmark(for: extFolder)
        var refGame = Game(title: "Referenced", source: .referenced(path: extFolder.path, bookmark: bookmark))
        refGame.launch.executable = nil
        let refCrate = root.appending(path: "Referenced.doscrate", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: refCrate, withIntermediateDirectories: true)
        let refRecord = GameRecord(game: refGame, crateURL: refCrate, status: .ok)
        #expect(!LibraryQuery.needsAttention(refRecord))
        try FileManager.default.removeItem(at: extFolder)
        #expect(LibraryQuery.needsAttention(refRecord))

        // Missing executable file, directory as executable, or escaping symlink
        let missingExe = try makeManagedCrate("MissingExe", executable: "GONE.EXE")
        #expect(LibraryQuery.needsAttention(missingExe))

        let dirExe = try makeManagedCrate("DirExe", executable: "SUBDIR")
        try FileManager.default.createDirectory(at: dirExe.crateURL.appending(path: "files/SUBDIR"), withIntermediateDirectories: true)
        #expect(LibraryQuery.needsAttention(dirExe))

        let escapeExe = try makeManagedCrate("EscapeExe", executable: "OUT.EXE")
        let outside = root.appending(path: "OUT.EXE")
        try Data("exe".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: escapeExe.crateURL.appending(path: "files/OUT.EXE"),
            withDestinationURL: outside
        )
        #expect(LibraryQuery.needsAttention(escapeExe))
    }

    @Test func filterAndCountIncludeNeedsAttentionAndCollections() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "query-counts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        func makeHealthy(_ title: String, favorite: Bool = false, lastPlayed: Date? = nil, tags: [String] = [], genre: String? = nil) throws -> GameRecord {
            let crate = root.appending(path: "\(title).doscrate", directoryHint: .isDirectory)
            let files = crate.appending(path: "files", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            try Data("exe".utf8).write(to: files.appending(path: "GAME.EXE"))
            var g = Game(title: title, source: .managed)
            g.isFavorite = favorite
            g.stats.lastPlayed = lastPlayed
            g.tags = tags
            g.genre = genre
            g.launch.executable = "GAME.EXE"
            return GameRecord(game: g, crateURL: crate, status: .ok)
        }

        let doom = try makeHealthy("DOOM", favorite: true, lastPlayed: now.addingTimeInterval(-3600), tags: ["FPS"], genre: "Shooter")
        let keen = try makeHealthy("Keen", favorite: false, lastPlayed: nil, tags: ["Platformer"], genre: "Platform")
        var brokenExe = try makeHealthy("BrokenExe", favorite: false, lastPlayed: nil, tags: ["FPS"], genre: "Shooter")
        brokenExe.game.launch.executable = "MISSING.EXE"
        let repair = record("NeedsRepair", genre: "Adventure", status: .needsRepair(reason: "corrupt"))

        let records = [doom, keen, brokenExe, repair]

        #expect(titles(LibraryQuery(filter: .needsAttention), records) == ["BrokenExe", "NeedsRepair"])
        #expect(titles(LibraryQuery(filter: .needsAttention, genre: "Shooter"), records) == ["BrokenExe"])
        #expect(titles(LibraryQuery(filter: .needsAttention, search: "repair"), records) == ["NeedsRepair"])

        #expect(LibraryQuery.count(for: .all, in: records, now: now) == 4)
        #expect(LibraryQuery.count(for: .recent, in: records, now: now) == 2) // doom + repair
        #expect(LibraryQuery.count(for: .favorites, in: records, now: now) == 2) // doom + repair
        #expect(LibraryQuery.count(for: .needsAttention, in: records, now: now) == 2) // brokenExe + repair
        #expect(LibraryQuery.count(for: .tag("fps"), in: records, now: now) == 3) // doom + brokenExe + repair
        #expect(LibraryQuery.count(for: .tag("Platformer"), in: records, now: now) == 2) // keen + repair
    }
}

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
        let rs = [record("A", tags: ["rpg"]), record("B", tags: ["fps"])]
        #expect(titles(LibraryQuery(filter: .tag("rpg")), rs) == ["A"])
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
        let rs = [record("A", tags: ["rpg", "fps"]), record("B", tags: ["fps", "Adventure"])]
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
}

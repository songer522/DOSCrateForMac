import Foundation

public enum SidebarFilter: Hashable, Sendable {
    case all
    case recent
    case favorites
    case tag(String)
}

public enum SortKey: Sendable, Equatable {
    /// A to Z, ignoring a leading "The ".
    case title
    /// Oldest first; unknown years last.
    case year
    /// Most recent first; never-played last.
    case lastPlayed
    /// Longest first.
    case playTime
}

public struct LibraryQuery: Sendable, Equatable {
    public static let recentWindow: TimeInterval = 30 * 24 * 60 * 60

    public var filter: SidebarFilter
    public var search: String
    public var sort: SortKey
    public var genre: String?
    public var year: Int?
    public var publisher: String?
    public var developer: String?

    public init(
        filter: SidebarFilter = .all,
        search: String = "",
        sort: SortKey = .title,
        genre: String? = nil,
        year: Int? = nil,
        publisher: String? = nil,
        developer: String? = nil
    ) {
        self.filter = filter
        self.search = search
        self.sort = sort
        self.genre = genre
        self.year = year
        self.publisher = publisher
        self.developer = developer
    }

    public var hasActiveMetadataFilter: Bool {
        genre != nil || year != nil || publisher != nil || developer != nil
    }

    public mutating func clearMetadataFilters() {
        genre = nil
        year = nil
        publisher = nil
        developer = nil
    }

    /// Filters, searches and sorts. Records that need repair always pass the sidebar filter, but still honour metadata filters and search.
    public func apply(to records: [GameRecord], now: Date) -> [GameRecord] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = records.filter { record in
            if case .needsRepair = record.status {
                return matchesMetadataFilters(record) && matchesSearch(record, needle: needle)
            }
            return matchesFilter(record, now: now)
                && matchesMetadataFilters(record)
                && matchesSearch(record, needle: needle)
        }
        return visible.sorted { precedes($0, $1) }
    }

    private func matchesFilter(_ record: GameRecord, now: Date) -> Bool {
        let game = record.game
        switch filter {
        case .all: return true
        case .recent:
            guard let played = game.stats.lastPlayed else { return false }
            return now.timeIntervalSince(played) <= Self.recentWindow
        case .favorites: return game.isFavorite
        case .tag(let tag):
            guard let targetTag = trimmedNonEmpty(tag) else { return false }
            return game.tags.contains { raw in
                guard let trimmed = trimmedNonEmpty(raw) else { return false }
                return trimmed.localizedCaseInsensitiveCompare(targetTag) == .orderedSame
            }
        }
    }

    private func matchesMetadataFilters(_ record: GameRecord) -> Bool {
        let game = record.game
        if let targetGenre = genre {
            let matchesGenre = splitGenres(in: game.genre).contains {
                $0.localizedCaseInsensitiveCompare(targetGenre) == .orderedSame
            }
            if !matchesGenre { return false }
        }
        if let targetYear = year, game.year != targetYear {
            return false
        }
        if let targetPublisher = publisher {
            guard let gamePublisher = trimmedNonEmpty(game.publisher),
                  gamePublisher.localizedCaseInsensitiveCompare(targetPublisher) == .orderedSame
            else { return false }
        }
        if let targetDeveloper = developer {
            guard let gameDeveloper = trimmedNonEmpty(game.developer),
                  gameDeveloper.localizedCaseInsensitiveCompare(targetDeveloper) == .orderedSame
            else { return false }
        }
        return true
    }

    private func matchesSearch(_ record: GameRecord, needle: String) -> Bool {
        if needle.isEmpty { return true }
        let game = record.game
        var fields = [game.title] + game.tags
        if let developer = game.developer { fields.append(developer) }
        if let publisher = game.publisher { fields.append(publisher) }
        if let genre = game.genre { fields.append(genre) }
        if let year = game.year { fields.append(String(year)) }
        return fields.contains { $0.localizedStandardContains(needle) }
    }

    private func precedes(_ a: GameRecord, _ b: GameRecord) -> Bool {
        let byTitle = Self.titleKey(a.game.title).localizedStandardCompare(Self.titleKey(b.game.title))
        switch sort {
        case .title:
            return byTitle == .orderedAscending
        case .year:
            if a.game.year != b.game.year {
                guard let x = a.game.year else { return false }
                guard let y = b.game.year else { return true }
                return x < y
            }
        case .lastPlayed:
            if a.game.stats.lastPlayed != b.game.stats.lastPlayed {
                guard let x = a.game.stats.lastPlayed else { return false }
                guard let y = b.game.stats.lastPlayed else { return true }
                return x > y
            }
        case .playTime:
            if a.game.stats.totalPlaySeconds != b.game.stats.totalPlaySeconds {
                return a.game.stats.totalPlaySeconds > b.game.stats.totalPlaySeconds
            }
        }
        return byTitle == .orderedAscending
    }

    static func titleKey(_ title: String) -> String {
        if title.range(of: "the ", options: [.anchored, .caseInsensitive]) != nil, title.count > 4 {
            return String(title.dropFirst(4))
        }
        return title
    }
}

/// Every tag used by any record, unique and sorted.
public func allTags(in records: [GameRecord]) -> [String] {
    uniqueSortedStrings(records.flatMap(\.game.tags).compactMap(trimmedNonEmpty))
}

/// Every genre used by any record (splitting comma- or semicolon-separated genre strings), unique and sorted.
public func allGenres(in records: [GameRecord]) -> [String] {
    uniqueSortedStrings(records.flatMap { splitGenres(in: $0.game.genre) })
}

/// Every release year used by any record, unique and sorted ascending.
public func allYears(in records: [GameRecord]) -> [Int] {
    Set(records.compactMap(\.game.year)).sorted()
}

/// Every publisher used by any record, unique and sorted.
public func allPublishers(in records: [GameRecord]) -> [String] {
    uniqueSortedStrings(records.compactMap { trimmedNonEmpty($0.game.publisher) })
}

/// Every developer used by any record, unique and sorted.
public func allDevelopers(in records: [GameRecord]) -> [String] {
    uniqueSortedStrings(records.compactMap { trimmedNonEmpty($0.game.developer) })
}

private func splitGenres(in raw: String?) -> [String] {
    guard let raw else { return [] }
    return raw
        .components(separatedBy: CharacterSet(charactersIn: ",;"))
        .compactMap(trimmedNonEmpty)
}

private func trimmedNonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func uniqueSortedStrings(_ values: [String]) -> [String] {
    var seen: [String: String] = [:]
    for item in values {
        let key = item.lowercased()
        if seen[key] == nil {
            seen[key] = item
        }
    }
    return seen.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
}

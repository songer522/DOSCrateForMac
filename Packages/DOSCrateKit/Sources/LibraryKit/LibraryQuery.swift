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

    public init(filter: SidebarFilter = .all, search: String = "", sort: SortKey = .title) {
        self.filter = filter
        self.search = search
        self.sort = sort
    }

    /// Filters, searches and sorts. Records that need repair always pass the sidebar filter, but still honour search.
    public func apply(to records: [GameRecord], now: Date) -> [GameRecord] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = records.filter { record in
            if case .needsRepair = record.status { return matchesSearch(record, needle: needle) }
            return matchesFilter(record, now: now) && matchesSearch(record, needle: needle)
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
        case .tag(let tag): return game.tags.contains(tag)
        }
    }

    private func matchesSearch(_ record: GameRecord, needle: String) -> Bool {
        if needle.isEmpty { return true }
        let game = record.game
        var fields = [game.title] + game.tags
        if let developer = game.developer { fields.append(developer) }
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
    Set(records.flatMap(\.game.tags)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
}

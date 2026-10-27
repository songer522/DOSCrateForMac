import CryptoKit
import Foundation

public enum RecordStatus: Sendable, Equatable {
    case ok
    case needsRepair(reason: String)
    case missingSource
}

public enum LibraryError: Error, Equatable {
    case sourceUnreachable(path: String)
    case crateExists
}

public struct GameRecord: Sendable, Equatable, Identifiable {
    public var game: Game
    public var crateURL: URL
    public var extra: [String: JSONValue]
    public var status: RecordStatus

    /// The game's id; for records that need repair this is a UUID derived from the crate path.
    public var id: UUID { game.id }

    public init(game: Game, crateURL: URL, extra: [String: JSONValue] = [:], status: RecordStatus = .ok) {
        self.game = game
        self.crateURL = crateURL
        self.extra = extra
        self.status = status
    }
}

/// File-system operations on `.doscrate` folders.
public struct CrateIO: Sendable {
    public init() {}

    public static let crateExtension = "doscrate"
    static let gameFileName = "game.json"

    // MARK: Paths

    public func cacheURL(_ crate: URL) -> URL { crate.appending(path: ".cache", directoryHint: .isDirectory) }
    public func logsURL(_ crate: URL) -> URL { cacheURL(crate).appending(path: "logs", directoryHint: .isDirectory) }
    public func overrideURL(_ crate: URL) -> URL { crate.appending(path: "override.conf", directoryHint: .notDirectory) }
    public func coverURL(_ crate: URL) -> URL { crate.appending(path: "cover.png", directoryHint: .notDirectory) }
    func gameFileURL(_ crate: URL) -> URL { crate.appending(path: Self.gameFileName, directoryHint: .notDirectory) }

    // MARK: Names

    public static func crateName(for title: String) -> String {
        let illegal: Set<Character> = ["/", ":", "\\", "?", "*", "\"", "<", ">", "|"]
        let replaced = String(title.map { illegal.contains($0) ? "-" : $0 })
        let trimmed = replaced.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return (trimmed.isEmpty ? "Untitled" : trimmed) + "." + crateExtension
    }

    // MARK: Loading and saving

    public func loadRecord(at crateURL: URL) -> GameRecord {
        let fm = FileManager.default
        let file = gameFileURL(crateURL)
        func repair(_ reason: String) -> GameRecord {
            let name = crateURL.deletingPathExtension().lastPathComponent
            var placeholder = Game(title: name, source: .managed)
            placeholder.id = Self.derivedID(for: crateURL)
            return GameRecord(game: placeholder, crateURL: crateURL, extra: [:], status: .needsRepair(reason: reason))
        }

        guard let data = try? Data(contentsOf: file) else { return repair("game.json is missing or unreadable") }
        let decoded: (game: Game, extra: [String: JSONValue])
        do {
            decoded = try GameFileCodec.decode(data)
        } catch {
            let broken = crateURL.appending(path: Self.gameFileName + ".broken", directoryHint: .notDirectory)
            try? fm.removeItem(at: broken)
            try? fm.moveItem(at: file, to: broken)
            return repair("game.json could not be read and was renamed to game.json.broken")
        }

        var record = GameRecord(game: decoded.game, crateURL: crateURL, extra: decoded.extra, status: .ok)
        if case .referenced(let path, let bookmark) = decoded.game.source {
            do {
                let resolved = try Self.resolve(path: path, bookmark: bookmark)
                if resolved.stale {
                    record.game.source = .referenced(path: resolved.url.path, bookmark: resolved.bookmark)
                    try? save(record.game, extra: record.extra, to: crateURL)
                }
            } catch {
                record.status = .missingSource
            }
        }
        return record
    }

    public func save(_ game: Game, extra: [String: JSONValue], to crateURL: URL) throws {
        let data = try GameFileCodec.encode(game, extra: extra)
        try data.write(to: gameFileURL(crateURL), options: .atomic)
    }

    /// Extra keys currently on disk, for callers whose in-memory copy may be stale.
    func extraOnDisk(at crateURL: URL) -> [String: JSONValue]? {
        guard let data = try? Data(contentsOf: gameFileURL(crateURL)) else { return nil }
        return try? GameFileCodec.decode(data).extra
    }

    public func scan(library: URL) async -> [GameRecord] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: library, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let crates = entries.filter {
            $0.pathExtension == Self.crateExtension
                && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        let records = await withTaskGroup(of: GameRecord.self) { group in
            for crate in crates { group.addTask { loadRecord(at: crate) } }
            var out: [GameRecord] = []
            for await record in group { out.append(record) }
            return out
        }
        return records.sorted {
            let order = $0.game.title.localizedStandardCompare($1.game.title)
            return order == .orderedSame ? $0.crateURL.path < $1.crateURL.path : order == .orderedAscending
        }
    }

    public func makeCrate(title: String, in library: URL) throws -> URL {
        let fm = FileManager.default
        let base = String(Self.crateName(for: title).dropLast(Self.crateExtension.count + 1))
        var candidate = library.appending(path: base + "." + Self.crateExtension, directoryHint: .isDirectory)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = library.appending(path: "\(base) \(n).\(Self.crateExtension)", directoryHint: .isDirectory)
            n += 1
        }
        try fm.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }

    // MARK: Drive C:

    public func cDriveURL(for record: GameRecord) throws -> URL {
        let root: URL
        switch record.game.source {
        case .managed:
            root = record.crateURL.appending(path: "files", directoryHint: .isDirectory)
        case .referenced(let path, let bookmark):
            do {
                root = try Self.resolve(path: path, bookmark: bookmark).url
            } catch {
                throw LibraryError.sourceUnreachable(path: path)
            }
        }
        let sub = record.game.launch.driveCRoot
        return sub.isEmpty ? root : root.appending(path: sub, directoryHint: .isDirectory)
    }

    // MARK: Helpers

    /// Creates a non-security-scoped bookmark (the app is not sandboxed).
    public static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func resolve(path: String, bookmark: Data) throws -> (url: URL, stale: Bool, bookmark: Data) {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LibraryError.sourceUnreachable(path: path)
        }
        return (url, stale, stale ? try makeBookmark(for: url) : bookmark)
    }

    private static func derivedID(for crateURL: URL) -> UUID {
        let digest = Array(SHA256.hash(data: Data(crateURL.standardizedFileURL.path.utf8)).prefix(16))
        var bytes = digest
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

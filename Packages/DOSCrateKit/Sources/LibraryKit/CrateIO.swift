import CryptoKit
import Foundation

public enum RecordStatus: Sendable, Equatable {
    case ok
    case needsRepair(reason: String)
    case missingSource
    /// `game.json` is from a newer DOSCrate or holds values this version doesn't know. It is shown but never rewritten.
    case readOnly(reason: String)
}

public enum LibraryError: Error, Equatable {
    case sourceUnreachable(path: String)
    case invalidDriveCRoot(path: String)
    case crateExists
    /// The record is read-only; saving it would lose data written by a newer DOSCrate.
    case readOnly
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
    public static let importingMarkerFileName = ".doscrate-importing"
    public static let processSessionID = UUID().uuidString
    static let gameFileName = "game.json"

    // MARK: Paths

    public func isIncompleteImport(_ crate: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: crate.appending(path: Self.importingMarkerFileName, directoryHint: .notDirectory).path
        )
    }

    /// True when `crate` has an `.doscrate-importing` marker written by a previous process (or without this process's session ID).
    public func isAbandonedImport(_ crate: URL) -> Bool {
        let marker = crate.appending(path: Self.importingMarkerFileName, directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: marker) else { return false }
        let owner = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return owner != Self.processSessionID
    }

    public func cacheURL(_ crate: URL) -> URL { crate.appending(path: ".cache", directoryHint: .isDirectory) }
    public func logsURL(_ crate: URL) -> URL { cacheURL(crate).appending(path: "logs", directoryHint: .isDirectory) }
    public func overrideURL(_ crate: URL) -> URL { crate.appending(path: "override.conf", directoryHint: .notDirectory) }
    public func coverURL(_ crate: URL) -> URL { crate.appending(path: "cover.png", directoryHint: .notDirectory) }
    public func artURL(_ crate: URL) -> URL { crate.appending(path: "art", directoryHint: .isDirectory) }
    public func backURL(_ crate: URL) -> URL { artURL(crate).appending(path: "back.png", directoryHint: .notDirectory) }
    public func discURL(_ crate: URL) -> URL { artURL(crate).appending(path: "disc.png", directoryHint: .notDirectory) }
    public func logoURL(_ crate: URL) -> URL { artURL(crate).appending(path: "logo.png", directoryHint: .notDirectory) }
    public func screenshotURL(_ crate: URL, index: Int) -> URL {
        artURL(crate).appending(path: String(format: "screenshots/%02d.png", index), directoryHint: .notDirectory)
    }
    public func screenshotURLs(_ crate: URL) -> [URL] {
        let dir = artURL(crate).appending(path: "screenshots", directoryHint: .isDirectory)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
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
        let file = gameFileURL(crateURL)
        func repair(_ reason: String) -> GameRecord {
            GameRecord(game: placeholder(for: crateURL, raw: [:]), crateURL: crateURL, extra: [:],
                       status: .needsRepair(reason: reason))
        }
        func broken() -> GameRecord {
            let target = brokenFileURL(in: crateURL)
            guard (try? FileManager.default.moveItem(at: file, to: target)) != nil else {
                return repair("game.json could not be read")
            }
            return repair("game.json could not be read and was renamed to \(target.lastPathComponent)")
        }
        func readOnly(_ data: Data, raw: [String: JSONValue], reason: String) -> GameRecord {
            if let lenient = try? GameFileCodec.decodeLenient(data) {
                return GameRecord(game: lenient.game, crateURL: crateURL, extra: lenient.extra, status: .readOnly(reason: reason))
            }
            return GameRecord(game: placeholder(for: crateURL, raw: raw), crateURL: crateURL, extra: [:],
                              status: .readOnly(reason: reason))
        }

        guard let data = try? Data(contentsOf: file) else { return repair("game.json is missing or unreadable") }
        guard let raw = try? GameFileCodec.rawObject(data) else { return broken() }
        let version = GameFileCodec.schemaVersion(of: raw)
        if version > GameFileCodec.schemaVersion {
            return readOnly(data, raw: raw, reason: "This game was saved by a newer version of DOSCrate "
                            + "(game.json schema \(version)), so it can't be changed or played here.")
        }
        let decoded: (game: Game, extra: [String: JSONValue])
        do {
            decoded = try GameFileCodec.decode(data)
        } catch {
            // Valid JSON that only fails on values a newer DOSCrate may have written is kept as it is.
            if (try? GameFileCodec.decodeLenient(data)) != nil {
                return readOnly(data, raw: raw, reason: "This game has settings this version of DOSCrate doesn't "
                                + "recognize, so it can't be changed or played here.")
            }
            return broken()
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
    public func extraOnDisk(at crateURL: URL) -> [String: JSONValue]? {
        guard let data = try? Data(contentsOf: gameFileURL(crateURL)) else { return nil }
        return try? GameFileCodec.decode(data).extra
    }

    /// Loads every crate. A crate whose game id is already taken by an earlier crate (in name order, so
    /// "Keen" before "Keen 2" or "Keen copy"), as happens when a crate is duplicated in Finder, gets a fresh id
    /// written back to its `game.json`.
    public func scan(library: URL) async -> [GameRecord] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: library, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var crates: [URL] = []
        for entry in entries where entry.pathExtension == Self.crateExtension
            && (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if isAbandonedImport(entry) {
                try? fm.removeItem(at: entry)
                continue
            }
            crates.append(entry)
        }
        let records = await withTaskGroup(of: GameRecord.self) { group in
            for crate in crates { group.addTask { loadRecord(at: crate) } }
            var out: [GameRecord] = []
            for await record in group { out.append(record) }
            return out
        }
        var seen = Set<UUID>()
        var unique: [GameRecord] = []
        let byName = records.sorted {
            let order = $0.crateURL.deletingPathExtension().lastPathComponent
                .localizedStandardCompare($1.crateURL.deletingPathExtension().lastPathComponent)
            return order == .orderedSame ? $0.crateURL.path < $1.crateURL.path : order == .orderedAscending
        }
        for var record in byName {
            if seen.contains(record.id) { record = withFreshID(record) }
            seen.insert(record.id)
            unique.append(record)
        }
        return unique.sorted {
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

    /// The folder a referenced game points at, resolved from its bookmark; nil for a managed game.
    public func referencedFolderURL(for record: GameRecord) throws -> URL? {
        guard case .referenced(let path, let bookmark) = record.game.source else { return nil }
        do {
            return try Self.resolve(path: path, bookmark: bookmark).url
        } catch {
            throw LibraryError.sourceUnreachable(path: path)
        }
    }

    public func cDriveURL(for record: GameRecord) throws -> URL {
        let root = try referencedFolderURL(for: record)
            ?? record.crateURL.appending(path: "files", directoryHint: .isDirectory)
        let sub = record.game.launch.driveCRoot
        guard !sub.isEmpty else { return root }
        let normalized = sub.replacingOccurrences(of: "\\", with: "/")
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: true)
        guard !normalized.hasPrefix("/"),
              !parts.isEmpty,
              !parts.contains(".."),
              !parts.contains(".")
        else {
            throw LibraryError.invalidDriveCRoot(path: sub)
        }
        return parts.reduce(root) { $0.appending(path: String($1), directoryHint: .isDirectory) }
    }

    // MARK: Helpers

    /// Gives a duplicate a new id: written to disk when the record is writable, derived from its path otherwise.
    private func withFreshID(_ record: GameRecord) -> GameRecord {
        var record = record
        switch record.status {
        case .ok, .missingSource:
            record.game.id = UUID()
            do {
                try save(record.game, extra: record.extra, to: record.crateURL)
            } catch {
                record.game.id = Self.derivedID(for: record.crateURL)
            }
        case .needsRepair, .readOnly:
            record.game.id = Self.derivedID(for: record.crateURL)
        }
        return record
    }

    /// Stand-in for a record that can't be decoded: title and id from the raw JSON when present, else from the path.
    private func placeholder(for crateURL: URL, raw: [String: JSONValue]) -> Game {
        var title = crateURL.deletingPathExtension().lastPathComponent
        if case .string(let t)? = raw["title"], !t.isEmpty { title = t }
        var game = Game(title: title, source: .managed)
        if case .string(let s)? = raw["id"], let id = UUID(uuidString: s) {
            game.id = id
        } else {
            game.id = Self.derivedID(for: crateURL)
        }
        return game
    }

    /// `game.json.<timestamp>.broken`, numbered so an earlier broken file is never overwritten.
    private func brokenFileURL(in crate: URL) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: Date())
        var candidate = crate.appending(path: "\(Self.gameFileName).\(stamp).broken", directoryHint: .notDirectory)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = crate.appending(path: "\(Self.gameFileName).\(stamp)-\(n).broken", directoryHint: .notDirectory)
            n += 1
        }
        return candidate
    }

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

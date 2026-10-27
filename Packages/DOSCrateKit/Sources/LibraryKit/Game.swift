import Foundation

public enum GameSource: Sendable, Equatable, Codable {
    case managed
    case referenced(path: String, bookmark: Data)

    private enum CodingKeys: String, CodingKey { case type, path, bookmark }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "managed":
            self = .managed
        case "referenced":
            self = .referenced(path: try c.decode(String.self, forKey: .path),
                               bookmark: try c.decode(Data.self, forKey: .bookmark))
        case let other:
            // Shown read-only, so the stand-in is never written back.
            if decoder.decodesEnumsLeniently { self = .managed; return }
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown source type \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .managed:
            try c.encode("managed", forKey: .type)
        case .referenced(let path, let bookmark):
            try c.encode("referenced", forKey: .type)
            try c.encode(path, forKey: .path)
            try c.encode(bookmark, forKey: .bookmark)
        }
    }
}

public enum MediaKind: String, Sendable, Equatable, Codable {
    case cdrom, floppy
}

public struct MediaImage: Sendable, Equatable, Codable {
    /// Relative to the crate, under `media/`.
    public var relativePath: String
    public var kind: MediaKind
    public init(relativePath: String, kind: MediaKind) {
        self.relativePath = relativePath
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey { case relativePath, kind }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        relativePath = try c.decode(String.self, forKey: .relativePath)
        if decoder.decodesEnumsLeniently {
            kind = try c.decodeEnumIfPresent(MediaKind.self, forKey: .kind, lenient: true) ?? .cdrom
        } else {
            kind = try c.decode(MediaKind.self, forKey: .kind)
        }
    }
}

public struct LaunchSpec: Sendable, Equatable, Codable {
    /// '/'-separated path relative to the C: root.
    public var executable: String?
    public var arguments: String
    public var preCommands: [String]
    public var postCommands: [String]
    public var exitWhenDone: Bool
    /// Subpath of the game folder mounted as C:.
    public var driveCRoot: String

    public init(
        executable: String? = nil, arguments: String = "", preCommands: [String] = [],
        postCommands: [String] = [], exitWhenDone: Bool = true, driveCRoot: String = ""
    ) {
        self.executable = executable; self.arguments = arguments
        self.preCommands = preCommands; self.postCommands = postCommands
        self.exitWhenDone = exitWhenDone; self.driveCRoot = driveCRoot
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case executable, arguments, preCommands, postCommands, exitWhenDone, driveCRoot
    }

    static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        executable = try c.decodeIfPresent(String.self, forKey: .executable)
        arguments = try c.decodeIfPresent(String.self, forKey: .arguments) ?? ""
        preCommands = try c.decodeIfPresent([String].self, forKey: .preCommands) ?? []
        postCommands = try c.decodeIfPresent([String].self, forKey: .postCommands) ?? []
        exitWhenDone = try c.decodeIfPresent(Bool.self, forKey: .exitWhenDone) ?? true
        driveCRoot = try c.decodeIfPresent(String.self, forKey: .driveCRoot) ?? ""
    }
}

public struct PlayStats: Sendable, Equatable, Codable {
    public var totalPlaySeconds: Double
    public var lastPlayed: Date?
    public var launchCount: Int

    public init(totalPlaySeconds: Double = 0, lastPlayed: Date? = nil, launchCount: Int = 0) {
        self.totalPlaySeconds = totalPlaySeconds
        self.lastPlayed = lastPlayed
        self.launchCount = launchCount
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case totalPlaySeconds, lastPlayed, launchCount }

    static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalPlaySeconds = try c.decodeIfPresent(Double.self, forKey: .totalPlaySeconds) ?? 0
        lastPlayed = try c.decodeIfPresent(Date.self, forKey: .lastPlayed)
        launchCount = try c.decodeIfPresent(Int.self, forKey: .launchCount) ?? 0
    }
}

public struct ImportOrigin: Sendable, Equatable, Codable {
    public var path: String
    public var fileSize: Int64?
    public var modifiedAt: Date?

    public init(path: String, fileSize: Int64? = nil, modifiedAt: Date? = nil) {
        self.path = path
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case path, fileSize, modifiedAt }

    static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public static func canonicalPath(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    public static func from(_ url: URL) -> ImportOrigin {
        let path = canonicalPath(for: url)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return ImportOrigin(path: path)
        }
        if attrs[.type] as? FileAttributeType == .typeDirectory {
            return ImportOrigin(path: path)
        }
        let size = (attrs[.size] as? NSNumber)?.int64Value
        let mtime = (attrs[.modificationDate] as? Date).map {
            Date(timeIntervalSince1970: floor($0.timeIntervalSince1970))
        }
        return ImportOrigin(path: path, fileSize: size, modifiedAt: mtime)
    }
}

public struct Game: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var title: String
    public var year: Int?
    public var developer: String?
    public var publisher: String?
    public var genre: String?
    public var notes: String
    public var tags: [String]
    public var isFavorite: Bool
    public var source: GameSource
    public var origin: ImportOrigin?
    public var media: [MediaImage]
    public var launch: LaunchSpec
    public var settings: GameSettings
    public var stats: PlayStats

    public init(title: String, source: GameSource, origin: ImportOrigin? = nil) {
        self.id = UUID()
        self.title = title
        self.year = nil
        self.developer = nil
        self.publisher = nil
        self.genre = nil
        self.notes = ""
        self.tags = []
        self.isFavorite = false
        self.source = source
        self.origin = origin
        self.media = []
        self.launch = LaunchSpec()
        self.settings = GameSettings()
        self.stats = PlayStats()
    }

    /// Top-level `game.json` keys this type owns; everything else is carried as `extra`.
    static let knownKeys: Set<String> = [
        "id", "title", "year", "developer", "publisher", "genre", "notes", "tags",
        "isFavorite", "source", "origin", "media", "launch", "settings", "stats",
    ]

    private enum CodingKeys: String, CodingKey {
        case id, title, year, developer, publisher, genre, notes, tags
        case isFavorite, source, origin, media, launch, settings, stats
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        developer = try c.decodeIfPresent(String.self, forKey: .developer)
        publisher = try c.decodeIfPresent(String.self, forKey: .publisher)
        genre = try c.decodeIfPresent(String.self, forKey: .genre)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        source = try c.decode(GameSource.self, forKey: .source)
        origin = try c.decodeIfPresent(ImportOrigin.self, forKey: .origin)
        media = try c.decodeIfPresent([MediaImage].self, forKey: .media) ?? []
        launch = try c.decodeIfPresent(LaunchSpec.self, forKey: .launch) ?? LaunchSpec()
        settings = try c.decodeIfPresent(GameSettings.self, forKey: .settings) ?? GameSettings()
        stats = try c.decodeIfPresent(PlayStats.self, forKey: .stats) ?? PlayStats()
    }
}

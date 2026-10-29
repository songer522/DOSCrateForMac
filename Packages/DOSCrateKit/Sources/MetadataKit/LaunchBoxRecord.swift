import Foundation

public enum LaunchBoxError: Error, Equatable, Sendable {
    case download(String)
    case unzip(String)
    case parse(String)
}

public struct LaunchBoxImage: Sendable, Codable, Equatable {
    public var type: String
    public var fileName: String
    public var region: String?

    public init(type: String, fileName: String, region: String? = nil) {
        self.type = type
        self.fileName = fileName
        self.region = region
    }
}

public struct LaunchBoxRecord: Sendable, Codable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    public var alternateNames: [String]
    public var releaseYear: Int?
    public var developer: String?
    public var publisher: String?
    public var genres: [String]
    public var overview: String?
    public var images: [LaunchBoxImage]

    public init(
        id: Int,
        name: String,
        alternateNames: [String] = [],
        releaseYear: Int? = nil,
        developer: String? = nil,
        publisher: String? = nil,
        genres: [String] = [],
        overview: String? = nil,
        images: [LaunchBoxImage] = []
    ) {
        self.id = id
        self.name = name
        self.alternateNames = alternateNames
        self.releaseYear = releaseYear
        self.developer = developer
        self.publisher = publisher
        self.genres = genres
        self.overview = overview
        self.images = images
    }
}

public struct LaunchBoxIndex: Sendable, Codable, Equatable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var downloadedAt: Date
    public var games: [LaunchBoxRecord]

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        downloadedAt: Date,
        games: [LaunchBoxRecord]
    ) {
        self.formatVersion = formatVersion
        self.downloadedAt = downloadedAt
        self.games = games
    }
}

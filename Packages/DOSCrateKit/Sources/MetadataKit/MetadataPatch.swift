import Foundation
import LibraryKit

public enum ArtKind: Sendable, Hashable {
    case front
    case back
    case disc
    case logo
    case screenshot(Int)

    public func fileURL(in crate: URL, io: CrateIO = CrateIO()) -> URL {
        switch self {
        case .front:
            io.coverURL(crate)
        case .back:
            io.backURL(crate)
        case .disc:
            io.discURL(crate)
        case .logo:
            io.logoURL(crate)
        case .screenshot(let index):
            io.screenshotURL(crate, index: index)
        }
    }

    public var sortRank: Int {
        switch self {
        case .front: 0
        case .back: 1
        case .disc: 2
        case .logo: 3
        case .screenshot(let index): 10 + index
        }
    }
}

public struct MetadataPatch: Sendable, Equatable {
    public var sourceID: Int
    public var year: Int?
    public var developer: String?
    public var publisher: String?
    public var genre: String?
    public var description: String?
    public var art: [ArtKind: URL]

    public init(
        sourceID: Int,
        year: Int? = nil,
        developer: String? = nil,
        publisher: String? = nil,
        genre: String? = nil,
        description: String? = nil,
        art: [ArtKind: URL] = [:]
    ) {
        self.sourceID = sourceID
        self.year = year
        self.developer = developer
        self.publisher = publisher
        self.genre = genre
        self.description = description
        self.art = art
    }
}

public enum ApplyMode: Sendable, Equatable {
    case fillEmpty
    case replace
}

public enum MetadataApplier {
    public static func patch(from record: LaunchBoxRecord) -> MetadataPatch {
        var art: [ArtKind: URL] = [:]

        if let front = pickBestImage(type: "Box - Front", from: record.images) {
            art[.front] = LaunchBoxEndpoints.imageURL(for: front.fileName)
        }
        if let back = pickBestImage(type: "Box - Back", from: record.images) {
            art[.back] = LaunchBoxEndpoints.imageURL(for: back.fileName)
        }
        if let disc = pickBestImage(type: "Disc", from: record.images) {
            art[.disc] = LaunchBoxEndpoints.imageURL(for: disc.fileName)
        }
        if let logo = pickBestImage(type: "Clear Logo", from: record.images) {
            art[.logo] = LaunchBoxEndpoints.imageURL(for: logo.fileName)
        }

        let gameplayShots = record.images.filter { $0.type == "Screenshot - Gameplay" }
        let titleShots = record.images.filter { $0.type == "Screenshot - Game Title" }
        let allScreenshots = Array((gameplayShots + titleShots).prefix(6))
        for (idx, shot) in allScreenshots.enumerated() {
            art[.screenshot(idx + 1)] = LaunchBoxEndpoints.imageURL(for: shot.fileName)
        }

        return MetadataPatch(
            sourceID: record.id,
            year: record.releaseYear,
            developer: nonEmpty(record.developer),
            publisher: nonEmpty(record.publisher),
            genre: nonEmpty(record.genres.first),
            description: nonEmpty(record.overview),
            art: art
        )
    }

    public static func apply(
        _ patch: MetadataPatch,
        to game: Game,
        mode: ApplyMode,
        now: Date
    ) -> Game {
        var updated = game
        switch mode {
        case .fillEmpty:
            if updated.year == nil, let year = patch.year {
                updated.year = year
            }
            if isBlank(updated.developer), let developer = nonEmpty(patch.developer) {
                updated.developer = developer
            }
            if isBlank(updated.publisher), let publisher = nonEmpty(patch.publisher) {
                updated.publisher = publisher
            }
            if isBlank(updated.genre), let genre = nonEmpty(patch.genre) {
                updated.genre = genre
            }
            if isBlank(updated.description), let description = nonEmpty(patch.description) {
                updated.description = description
            }
        case .replace:
            if let year = patch.year {
                updated.year = year
            }
            if let developer = nonEmpty(patch.developer) {
                updated.developer = developer
            }
            if let publisher = nonEmpty(patch.publisher) {
                updated.publisher = publisher
            }
            if let genre = nonEmpty(patch.genre) {
                updated.genre = genre
            }
            if let description = nonEmpty(patch.description) {
                updated.description = description
            }
        }
        updated.metadataSource = MetadataSource(
            provider: "launchbox",
            id: patch.sourceID,
            fetchedAt: now
        )
        return updated
    }

    public static func wouldReplace(
        _ patch: MetadataPatch,
        game: Game,
        existingArt: Set<ArtKind>
    ) -> Bool {
        if patch.year != nil, game.year != nil { return true }
        if nonEmpty(patch.developer) != nil, !isBlank(game.developer) { return true }
        if nonEmpty(patch.publisher) != nil, !isBlank(game.publisher) { return true }
        if nonEmpty(patch.genre) != nil, !isBlank(game.genre) { return true }
        if nonEmpty(patch.description) != nil, !isBlank(game.description) { return true }
        if !existingArt.intersection(patch.art.keys).isEmpty { return true }
        return false
    }

    public static func existingArtKinds(in crate: URL, io: CrateIO = CrateIO()) -> Set<ArtKind> {
        let fm = FileManager.default
        var result: Set<ArtKind> = []
        let candidates: [ArtKind] = [.front, .back, .disc, .logo] + (1...6).map { .screenshot($0) }
        for kind in candidates where fm.fileExists(atPath: kind.fileURL(in: crate, io: io).path) {
            result.insert(kind)
        }
        return result
    }

    private static func pickBestImage(type: String, from images: [LaunchBoxImage]) -> LaunchBoxImage? {
        let matching = images.filter { $0.type == type }
        guard !matching.isEmpty else { return nil }
        if let nilRegion = matching.first(where: { $0.region == nil || $0.region?.isEmpty == true }) {
            return nilRegion
        }
        if let na = matching.first(where: { $0.region == "North America" }) {
            return na
        }
        if let us = matching.first(where: { $0.region == "United States" }) {
            return us
        }
        return matching.first
    }

    private static func isBlank(_ s: String?) -> Bool {
        guard let s else { return true }
        return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

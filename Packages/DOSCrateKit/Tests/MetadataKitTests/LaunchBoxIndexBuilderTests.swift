import Foundation
import Testing
@testable import MetadataKit

struct LaunchBoxIndexBuilderTests {
    private var fixtureURL: URL {
        Bundle.module.url(forResource: "Metadata", withExtension: "xml", subdirectory: "Fixtures")!
    }

    @Test func keepsOnlyMSDOS() throws {
        let records = try LaunchBoxIndexBuilder.build(xml: fixtureURL)
        #expect(records.count == 3)
        #expect(records.map(\.id) == [101, 102, 103])
    }

    @Test func attachesAlternateNamesRegardlessOfOrder() throws {
        let records = try LaunchBoxIndexBuilder.build(xml: fixtureURL)
        let keen = try #require(records.first { $0.id == 101 })
        #expect(keen.alternateNames == ["Commander Keen 4", "Keen 4: Secret of the Oracle"])
    }

    @Test func parsesGenresSplitOnSemicolon() throws {
        let records = try LaunchBoxIndexBuilder.build(xml: fixtureURL)
        let keen = try #require(records.first { $0.id == 101 })
        #expect(keen.genres == ["Action", "Platform"])
    }

    @Test func fallsBackToReleaseDateYear() throws {
        let records = try LaunchBoxIndexBuilder.build(xml: fixtureURL)
        let doom2 = try #require(records.first { $0.id == 102 })
        #expect(doom2.releaseYear == 1994)
    }

    @Test func imagesAttachedWithTypeAndRegion() throws {
        let records = try LaunchBoxIndexBuilder.build(xml: fixtureURL)
        let keen = try #require(records.first { $0.id == 101 })
        #expect(keen.images.count == 12)
        #expect(keen.images.first == LaunchBoxImage(
            type: "Box - Front",
            fileName: "keen4-front.png",
            region: "North America"
        ))
        #expect(keen.images.last == LaunchBoxImage(
            type: "Screenshot - Game Title",
            fileName: "keen4-title.png",
            region: "United States"
        ))
    }

    @Test func malformedXMLThrows() throws {
        let badURL = FileManager.default.temporaryDirectory
            .appending(path: "bad-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: badURL) }
        try Data("<LaunchBox><Game><Name>Unclosed".utf8).write(to: badURL)
        #expect(throws: (any Error).self) {
            _ = try LaunchBoxIndexBuilder.build(xml: badURL)
        }
    }
}

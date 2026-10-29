import Foundation
import LibraryKit
import Testing
@testable import MetadataKit

struct MetadataApplierTests {
    @Test func patchPicksArtByRegionPreference() {
        let record = LaunchBoxRecord(
            id: 10,
            name: "Keen",
            images: [
                LaunchBoxImage(type: "Box - Front", fileName: "eu.png", region: "Europe"),
                LaunchBoxImage(type: "Box - Front", fileName: "us.png", region: "United States"),
                LaunchBoxImage(type: "Box - Front", fileName: "na.png", region: "North America"),
                LaunchBoxImage(type: "Box - Back", fileName: "back-eu.png", region: "Europe"),
                LaunchBoxImage(type: "Box - Back", fileName: "back-nil.png", region: nil),
                LaunchBoxImage(type: "Disc", fileName: "disc-eu.png", region: "Europe"),
                LaunchBoxImage(type: "Clear Logo", fileName: "logo-us.png", region: "United States"),
            ]
        )
        let patch = MetadataApplier.patch(from: record)
        #expect(patch.art[.front] == LaunchBoxEndpoints.imageURL(for: "na.png"))
        #expect(patch.art[.back] == LaunchBoxEndpoints.imageURL(for: "back-nil.png"))
        #expect(patch.art[.disc] == LaunchBoxEndpoints.imageURL(for: "disc-eu.png"))
        #expect(patch.art[.logo] == LaunchBoxEndpoints.imageURL(for: "logo-us.png"))
    }

    @Test func patchCapsScreenshotsAtSix() {
        var images = (1...5).map { i in
            LaunchBoxImage(type: "Screenshot - Gameplay", fileName: "gp\(i).png")
        }
        images.append(LaunchBoxImage(type: "Screenshot - Game Title", fileName: "title1.png"))
        images.append(LaunchBoxImage(type: "Screenshot - Game Title", fileName: "title2.png"))
        let record = LaunchBoxRecord(id: 11, name: "Doom", images: images)
        let patch = MetadataApplier.patch(from: record)

        #expect(patch.art[.screenshot(1)] == LaunchBoxEndpoints.imageURL(for: "gp1.png"))
        #expect(patch.art[.screenshot(5)] == LaunchBoxEndpoints.imageURL(for: "gp5.png"))
        #expect(patch.art[.screenshot(6)] == LaunchBoxEndpoints.imageURL(for: "title1.png"))
        #expect(patch.art[.screenshot(7)] == nil)
    }

    @Test func fillEmptyKeepsExistingValues() {
        var game = Game(title: "Doom", source: .managed)
        game.year = 1993
        game.developer = "id Software"
        game.description = "Existing description"

        let patch = MetadataPatch(
            sourceID: 99,
            year: 1994,
            developer: "Other Dev",
            publisher: "GT Interactive",
            genre: "Shooter",
            description: "New description"
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let updated = MetadataApplier.apply(patch, to: game, mode: .fillEmpty, now: now)

        #expect(updated.year == 1993)
        #expect(updated.developer == "id Software")
        #expect(updated.publisher == "GT Interactive")
        #expect(updated.genre == "Shooter")
        #expect(updated.description == "Existing description")
    }

    @Test func fillEmptyTreatsEmptyStringAsEmpty() {
        var game = Game(title: "Doom", source: .managed)
        game.developer = ""
        game.publisher = "   "
        game.genre = ""
        game.description = ""

        let patch = MetadataPatch(
            sourceID: 99,
            year: 1993,
            developer: "id Software",
            publisher: "id Software",
            genre: "Action",
            description: "Demons on Phobos."
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let updated = MetadataApplier.apply(patch, to: game, mode: .fillEmpty, now: now)

        #expect(updated.developer == "id Software")
        #expect(updated.publisher == "id Software")
        #expect(updated.genre == "Action")
        #expect(updated.description == "Demons on Phobos.")
    }

    @Test func replaceOverwritesProvidedFieldsOnly() {
        var game = Game(title: "Doom", source: .managed)
        game.year = 1993
        game.developer = "id Software"
        game.publisher = "id Software"
        game.genre = "Shooter"
        game.description = "Old description"

        let patch = MetadataPatch(
            sourceID: 100,
            year: 1994,
            developer: nil,
            publisher: "GT Interactive",
            genre: nil,
            description: "New description"
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let updated = MetadataApplier.apply(patch, to: game, mode: .replace, now: now)

        #expect(updated.year == 1994)
        #expect(updated.developer == "id Software")
        #expect(updated.publisher == "GT Interactive")
        #expect(updated.genre == "Shooter")
        #expect(updated.description == "New description")
    }

    @Test func applySetsMetadataSource() {
        let game = Game(title: "Doom", source: .managed)
        let patch = MetadataPatch(sourceID: 42, year: 1993)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let filled = MetadataApplier.apply(patch, to: game, mode: .fillEmpty, now: now)
        #expect(filled.metadataSource == MetadataSource(provider: "launchbox", id: 42, fetchedAt: now))

        let replaced = MetadataApplier.apply(patch, to: game, mode: .replace, now: now)
        #expect(replaced.metadataSource == MetadataSource(provider: "launchbox", id: 42, fetchedAt: now))
    }

    @Test func wouldReplaceTrueWhenAnyFieldOrArtExists() {
        let patch = MetadataPatch(
            sourceID: 42,
            year: 1993,
            developer: "id Software",
            art: [.front: LaunchBoxEndpoints.imageURL(for: "front.png")]
        )
        let emptyGame = Game(title: "Doom", source: .managed)
        #expect(!MetadataApplier.wouldReplace(patch, game: emptyGame, existingArt: []))
        #expect(!MetadataApplier.wouldReplace(patch, game: emptyGame, existingArt: [.back]))
        #expect(MetadataApplier.wouldReplace(patch, game: emptyGame, existingArt: [.front]))

        var gameWithYear = emptyGame
        gameWithYear.year = 1990
        #expect(MetadataApplier.wouldReplace(patch, game: gameWithYear, existingArt: []))
    }
}

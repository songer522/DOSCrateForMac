import Foundation
import Testing
@testable import MetadataKit

struct TitleMatcherTests {
    @Test func normalizeHandlesTagsRomanNumeralsAndDiacritics() {
        #expect(TitleMatcher.normalize("The Secret of Monkey Island v1.1") == "secret of monkey island")
        #expect(TitleMatcher.normalize("DOOM2") == "doom 2")
        #expect(TitleMatcher.normalize("Ultima VII (Disk 1)") == "ultima 7")
        #expect(TitleMatcher.normalize("Lemmings [CD] (1991)") == "lemmings")
        #expect(TitleMatcher.normalize("Ça & Là") == "ca and la")
    }

    @Test func parseYearExtractsParenthesizedYear() {
        #expect(TitleMatcher.parseYear("Lemmings [CD] (1991)") == 1991)
        #expect(TitleMatcher.parseYear("Some DOS Remake (2004)") == 2004)
        #expect(TitleMatcher.parseYear("Doom II") == nil)
    }

    @Test func commanderKeen4MatchesViaAlternateName() {
        let records = [
            LaunchBoxRecord(
                id: 1,
                name: "Commander Keen in Goodbye, Galaxy!",
                alternateNames: ["Commander Keen 4", "Keen 4"]
            ),
            LaunchBoxRecord(
                id: 2,
                name: "Commander Keen in Invasion of the Vorticons",
                alternateNames: ["Commander Keen 1"]
            ),
        ]
        let matched = TitleMatcher.autoMatch(for: "Commander Keen 4", in: records)
        #expect(matched?.id == 1)
    }

    @Test func doom2MatchesDoomII() {
        let records = [
            LaunchBoxRecord(id: 1, name: "Doom"),
            LaunchBoxRecord(id: 2, name: "Doom II"),
        ]
        let matched = TitleMatcher.autoMatch(for: "DOOM2", in: records)
        #expect(matched?.id == 2)
    }

    @Test func monkeyIslandWithVersionMatches() {
        let records = [
            LaunchBoxRecord(id: 1, name: "The Secret of Monkey Island"),
            LaunchBoxRecord(id: 2, name: "Monkey Island 2: LeChuck's Revenge"),
        ]
        let matched = TitleMatcher.autoMatch(for: "The Secret of Monkey Island v1.1", in: records)
        #expect(matched?.id == 1)
    }

    @Test func exactMatchBeatsSequelsAboveMargin() {
        let records = [
            LaunchBoxRecord(id: 1, name: "Ultima"),
            LaunchBoxRecord(id: 2, name: "Ultima II"),
            LaunchBoxRecord(id: 3, name: "Ultima III"),
        ]
        let matched = TitleMatcher.autoMatch(for: "Ultima", in: records)
        #expect(matched?.id == 1)
    }

    @Test func ambiguousMatchReturnsNilWhenMarginTooSmall() {
        let records = [
            LaunchBoxRecord(id: 1, name: "Gold Box Companion"),
            LaunchBoxRecord(id: 2, name: "Gold Box Collection"),
        ]
        #expect(TitleMatcher.autoMatch(for: "Gold Box", in: records) == nil)
    }

    @Test func yearBonusBreaksTieBetweenEqualNames() {
        let records = [
            LaunchBoxRecord(id: 1, name: "Prince of Persia", releaseYear: 1990),
            LaunchBoxRecord(id: 2, name: "Prince of Persia", releaseYear: 1993),
        ]
        let candidates = TitleMatcher.matches(for: "Prince of Persia (1993)", in: records, limit: 5)
        #expect(candidates.first?.record.id == 2)
    }

    @Test func limitIsRespected() {
        let records = (1...10).map { i in
            LaunchBoxRecord(id: i, name: "King's Quest \(i)")
        }
        let candidates = TitleMatcher.matches(for: "King's Quest", in: records, limit: 3)
        #expect(candidates.count == 3)
    }

    @Test func searchFindsTypo() {
        let records = [
            LaunchBoxRecord(id: 1, name: "Doom"),
            LaunchBoxRecord(id: 2, name: "Disney's Aladdin"),
            LaunchBoxRecord(id: 3, name: "Disney Aladdin"),
            LaunchBoxRecord(id: 4, name: "Prince of Persia"),
            LaunchBoxRecord(id: 5, name: "Wolfenstein 3D"),
        ]
        let top3 = TitleMatcher.search(for: "Aladin", in: records, limit: 8).prefix(3).map(\.record.name)
        #expect(top3.contains("Disney's Aladdin"))
        #expect(top3.contains("Disney Aladdin"))
    }

    @Test func searchFindsJoinedDigits() {
        let records = [
            LaunchBoxRecord(id: 1, name: "Alien"),
            LaunchBoxRecord(id: 2, name: "Aliens"),
            LaunchBoxRecord(id: 3, name: "SimCity 2000"),
            LaunchBoxRecord(id: 4, name: "Master of Orion"),
            LaunchBoxRecord(id: 5, name: "Dune II"),
        ]
        let top8 = TitleMatcher.search(for: "Alien2", in: records, limit: 8).map(\.record.name)
        #expect(top8.contains("Aliens") || top8.contains("Alien"))
    }

    @Test func autoMatchUnchangedForTypo() {
        let records = [
            LaunchBoxRecord(id: 1, name: "Disney's Aladdin"),
            LaunchBoxRecord(id: 2, name: "Disney Aladdin"),
        ]
        #expect(TitleMatcher.autoMatch(for: "Aladin", in: records) == nil)
    }

    @Test func searchDropsBelowFloor() {
        let records = [
            LaunchBoxRecord(id: 1, name: "Prince of Persia"),
            LaunchBoxRecord(id: 2, name: "Wolfenstein 3D"),
            LaunchBoxRecord(id: 3, name: "SimCity 2000"),
        ]
        let results = TitleMatcher.search(for: "Aladin", in: records, limit: 8)
        #expect(results.isEmpty)
    }

    @Test func searchFindsByPublisherDeveloperYearAndCombinations() {
        let records = [
            LaunchBoxRecord(
                id: 1,
                name: "Nobunaga's Ambition",
                releaseYear: 1988,
                developer: "Koei Co., Ltd.",
                publisher: "Koei"
            ),
            LaunchBoxRecord(
                id: 2,
                name: "Romance of the Three Kingdoms",
                releaseYear: 1989,
                developer: "Koei Co., Ltd.",
                publisher: "Koei"
            ),
            LaunchBoxRecord(
                id: 3,
                name: "Bandit Kings of Ancient China",
                releaseYear: 1989,
                developer: "Koei Co., Ltd.",
                publisher: "Koei"
            ),
            LaunchBoxRecord(
                id: 4,
                name: "Prince of Persia",
                releaseYear: 1989,
                developer: "Brøderbund",
                publisher: "Brøderbund"
            ),
            LaunchBoxRecord(
                id: 5,
                name: "Doom",
                releaseYear: 1993,
                developer: "id Software",
                publisher: "id Software"
            ),
        ]

        // 1. Search by publisher ("Koei") finds all 3 Koei games and excludes non-Koei games.
        let koeiResults = TitleMatcher.search(for: "Koei", in: records, limit: 10)
        #expect(Set(koeiResults.map(\.record.id)) == [1, 2, 3])

        // 2. Search by year ("1989") finds all 1989 games and excludes 1988/1993 games.
        let yearResults = TitleMatcher.search(for: "1989", in: records, limit: 10)
        #expect(Set(yearResults.map(\.record.id)) == [2, 3, 4])

        // 3. Search by publisher + year ("Koei 1989") finds only Koei games from 1989.
        let koei1989 = TitleMatcher.search(for: "Koei 1989", in: records, limit: 10)
        #expect(Set(koei1989.map(\.record.id)) == [2, 3])

        // 4. Search by title word + publisher ("Nobunaga Koei") finds only Nobunaga's Ambition.
        let nobunagaKoei = TitleMatcher.search(for: "Nobunaga Koei", in: records, limit: 10)
        #expect(nobunagaKoei.map(\.record.id) == [1])

        // 5. autoMatch remains strict on title and does NOT auto-match on publisher or year alone.
        #expect(TitleMatcher.autoMatch(for: "Koei", in: [records[0]]) == nil)
        #expect(TitleMatcher.autoMatch(for: "1988", in: [records[0]]) == nil)
    }
}

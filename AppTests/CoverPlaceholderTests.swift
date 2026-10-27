import SwiftUI
import Testing
@testable import DOSCrate

@Suite struct CoverPlaceholderTests {
    @Test func placeholderColorDeterministic() {
        #expect(PlaceholderCover.color(for: "Doom") == PlaceholderCover.color(for: "Doom"))
        #expect(PlaceholderCover.hue(for: "Doom") != PlaceholderCover.hue(for: "Commander Keen"))
        let hue = PlaceholderCover.hue(for: "Doom")
        #expect(hue >= 0 && hue < 1)
    }

    @Test func renamingATagMergesWithAnExistingOne() {
        #expect(CollectionTags.renamed(["RPG", "Fav"], from: "RPG", to: "Fav") == ["Fav"])
        #expect(CollectionTags.renamed(["RPG", "Fav"], from: "RPG", to: "Quest") == ["Quest", "Fav"])
        #expect(CollectionTags.removed(["RPG", "Fav"], tag: "RPG") == ["Fav"])
    }
}

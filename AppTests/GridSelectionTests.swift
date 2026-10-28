import Foundation
import Testing
@testable import DOSCrate

struct GridSelectionTests {
    @Test func toggleAddsAndRemoves() {
        let a = UUID()
        let b = UUID()
        let added = GridSelection.toggle(b, in: [a])
        #expect(added == [a, b])
        let removed = GridSelection.toggle(a, in: added)
        #expect(removed == [b])
    }

    @Test func extendSelectsInclusiveRangeEitherDirection() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let order = [a, b, c, d]
        #expect(GridSelection.extend(from: b, to: d, in: order) == [b, c, d])
        #expect(GridSelection.extend(from: d, to: b, in: order) == [b, c, d])
    }

    @Test func extendWithoutAnchorOrUnknownIdReturnsNil() {
        let a = UUID(), b = UUID(), unknown = UUID()
        let order = [a, b]
        #expect(GridSelection.extend(from: nil, to: b, in: order) == nil)
        #expect(GridSelection.extend(from: unknown, to: b, in: order) == nil)
        #expect(GridSelection.extend(from: a, to: unknown, in: order) == nil)
    }
}

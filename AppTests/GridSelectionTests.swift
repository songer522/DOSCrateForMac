import Foundation
import Testing
@testable import DOSCrate

struct GridSelectionTests {
    @Test func returnActivatesOnlyASingleSelection() {
        let a = UUID()
        let b = UUID()
        #expect(GridSelection.activationTarget([]) == nil)
        #expect(GridSelection.activationTarget([a]) == a)
        #expect(GridSelection.activationTarget([a, b]) == nil)
    }

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

    @Test func stepMovesAndClampsSingleSelection() {
        let a = UUID(), b = UUID(), c = UUID()
        let order = [a, b, c]

        let first = GridSelection.step(selected: [], anchor: nil, cursor: nil, by: 1, extend: false, in: order)
        #expect(first == SelectionStep(selected: [a], anchor: a, cursor: a))

        let down = GridSelection.step(selected: [a], anchor: a, cursor: a, by: 1, extend: false, in: order)
        #expect(down == SelectionStep(selected: [b], anchor: b, cursor: b))

        let clampedTop = GridSelection.step(selected: [a], anchor: a, cursor: a, by: -1, extend: false, in: order)
        #expect(clampedTop == SelectionStep(selected: [a], anchor: a, cursor: a))

        let clampedBottom = GridSelection.step(selected: [c], anchor: c, cursor: c, by: 1, extend: false, in: order)
        #expect(clampedBottom == SelectionStep(selected: [c], anchor: c, cursor: c))
    }

    @Test func stepShiftExtendsAndContractsFromAnchor() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let order = [a, b, c, d]

        let step1 = GridSelection.step(selected: [b], anchor: nil, cursor: nil, by: 1, extend: true, in: order)!
        #expect(step1 == SelectionStep(selected: [b, c], anchor: b, cursor: c))

        let step2 = GridSelection.step(
            selected: step1.selected, anchor: step1.anchor, cursor: step1.cursor, by: 1, extend: true, in: order
        )!
        #expect(step2 == SelectionStep(selected: [b, c, d], anchor: b, cursor: d))

        let step3 = GridSelection.step(
            selected: step2.selected, anchor: step2.anchor, cursor: step2.cursor, by: -1, extend: true, in: order
        )!
        #expect(step3 == SelectionStep(selected: [b, c], anchor: b, cursor: c))

        let collapse = GridSelection.step(
            selected: step3.selected, anchor: step3.anchor, cursor: step3.cursor, by: 1, extend: false, in: order
        )!
        #expect(collapse == SelectionStep(selected: [d], anchor: d, cursor: d))
    }
}

import Foundation
import LibraryKit
import SwiftUI
import Testing
@testable import DOSCrate

@MainActor
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

@MainActor
struct SettingsBindingTests {
    @Test func optionalPickerNilMeansInherit() throws {
        let box = Box(GameSettings(preset: .pc486, memoryMB: 16))
        let preset = Binding<Preset?>(get: { box.value.preset }, set: { box.value.preset = $0 })
        #expect(preset.wrappedValue == .pc486)

        preset.wrappedValue = nil

        #expect(box.value.preset == nil)
        let json = try String(decoding: JSONEncoder().encode(box.value), as: UTF8.self)
        #expect(!json.contains("preset"))
        #expect(json.contains("memoryMB"))
    }

    @Test func fixedCyclesClampsTo100To500000() {
        #expect(Cycles.clampedFixed(5) == .fixed(100))
        #expect(Cycles.clampedFixed(-3) == .fixed(100))
        #expect(Cycles.clampedFixed(12_000) == .fixed(12_000))
        #expect(Cycles.clampedFixed(9_999_999) == .fixed(500_000))
    }

    @Test func cyclesModeRoundTrips() {
        #expect(CyclesMode(nil) == .preset)
        #expect(CyclesMode(.auto) == .auto)
        #expect(CyclesMode(.max) == .max)
        #expect(CyclesMode(.fixed(2000)) == .fixed)
        #expect(CyclesMode.preset.cycles(fixed: 2000) == nil)
        #expect(CyclesMode.max.cycles(fixed: 2000) == .max)
        #expect(CyclesMode.fixed.cycles(fixed: 50) == .fixed(100))
    }
}

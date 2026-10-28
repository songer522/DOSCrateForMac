import ConfigKit
import Foundation
import LauncherKit
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

    @Test func useControllersDefaultsOnAndPersists() {
        let d = UserDefaults(suiteName: #function)!; d.removePersistentDomain(forName: #function)
        let p = Preferences(defaults: d); #expect(p.useControllers)
        p.useControllers = false; #expect(!Preferences(defaults: d).useControllers)
    }

    @Test func launchConfigRespectsSwitch() {
        let d = UserDefaults(suiteName: #function)!; d.removePersistentDomain(forName: #function)
        let p = Preferences(defaults: d)
        let pad = GamepadInfo(vendorID: 0x054c, productID: 0x0ce6, transport: "USB", product: "DualSense Wireless Controller", usagePage: 1, usage: 5)
        #expect(p.launchConfig(gamepads: [pad]).controllerLayout == .standard)
        p.useControllers = false; #expect(p.launchConfig(gamepads: [pad]).controllerLayout == nil)
    }
}

@MainActor
struct DetailDraftTests {
    @Test func trimmedStoredTitleDoesNotOverwriteTypingDraft() {
        let stored = Game(title: "Lost", source: .managed)
        var draft = stored
        draft.title = "Lost "
        #expect(GameDetailView.merged(draft, into: stored) == stored)
        #expect(!GameDetailView.shouldAdopt(stored: stored, over: draft))
    }

    @Test func externalChangeIsAdopted() {
        let draft = Game(title: "Lost", source: .managed)
        var stored = draft
        stored.launch.executable = "LOST.EXE"
        #expect(GameDetailView.shouldAdopt(stored: stored, over: draft))
    }
}

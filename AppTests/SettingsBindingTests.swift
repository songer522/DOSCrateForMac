import ConfigKit
import Foundation
import ImportKit
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
        #expect(p.launchConfig(gamepads: [pad]).detectedControllerLayout == .standard)
        p.globalOverrides.controllerMode = .twoAxis
        #expect(p.launchConfig(gamepads: [pad]).overrides.controllerMode == .twoAxis)
        p.useControllers = false
        #expect(p.launchConfig(gamepads: [pad]).controllerLayout == nil)
        #expect(p.launchConfig(gamepads: [pad]).detectedControllerLayout == .standard)
        #expect(p.launchConfig(gamepads: [pad]).overrides.controllerMode == nil)
    }

    @Test func controllerSectionBindingSetsAndNormalizesEmptyBindings() {
        let box = Box(GameSettings())
        let settingsBinding = Binding<GameSettings>(get: { box.value }, set: { box.value = $0 })
        let aBinding = ControllerSection.binding(for: .a, in: settingsBinding)
        let ltBinding = ControllerSection.binding(for: .leftTrigger, in: settingsBinding)

        #expect(aBinding.wrappedValue == nil)
        aBinding.wrappedValue = .space
        ltBinding.wrappedValue = .z
        #expect(box.value.controllerBindings == ControllerBindings(a: .space, leftTrigger: .z))

        aBinding.wrappedValue = nil
        #expect(box.value.controllerBindings == ControllerBindings(leftTrigger: .z))

        ltBinding.wrappedValue = nil
        #expect(box.value.controllerBindings == nil)
    }

    @Test func fetchMetadataOnImportDefaultsTrue() {
        let d = UserDefaults(suiteName: #function)!; d.removePersistentDomain(forName: #function)
        let p = Preferences(defaults: d)
        #expect(p.fetchMetadataOnImport == true)
        p.fetchMetadataOnImport = false
        #expect(Preferences(defaults: d).fetchMetadataOnImport == false)
    }

    @Test func refreshButtonCallsCoordinator() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "settings-refresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let d = UserDefaults(suiteName: #function)!; d.removePersistentDomain(forName: #function)
        let prefs = Preferences(defaults: d)
        let store = LibraryStore(library: root)
        let provider = StubMetadataProvider(records: [], downloadedAt: nil)
        let coordinator = MetadataCoordinator(provider: provider, prefs: prefs)
        let model = AppModel(
            prefs: prefs,
            store: store,
            sessions: SessionManager(runner: FakeRunner()),
            importer: Importer(),
            dosbox: root.appending(path: "dosbox"),
            verifyDosbox: { _ in },
            metadata: coordinator
        )

        #expect(GeneralPreferences.lastUpdatedText(nil) == "Never")
        let sampleDate = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(GeneralPreferences.lastUpdatedText(sampleDate).hasPrefix("Last updated "))

        GeneralPreferences.refreshLaunchBox(model: model)
        await waitUntil { provider.refreshCalls == 1 }
        #expect(provider.refreshCalls == 1)
    }

    @Test func drivesSectionAssignsAvailableDriveLettersAndRespectsCDROMOnD() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "folder-mounts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir1 = root.appending(path: "Saves")
        let dir2 = root.appending(path: "Mods")
        try FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)

        var game = Game(title: "Keen", source: .managed)
        #expect(DrivesSection.canAddFolderMount(to: game))

        // Without CD-ROM media, first folder mount defaults to D:, second to E:.
        let first = try #require(DrivesSection.appendFolderMount(url: dir1, to: &game))
        #expect(first.driveLetter == "D")
        let second = try #require(DrivesSection.appendFolderMount(url: dir2, to: &game))
        #expect(second.driveLetter == "E")
        #expect(DrivesSection.availableDriveLetters(for: 0, in: game).contains("D"))
        #expect(!DrivesSection.availableDriveLetters(for: 0, in: game).contains("E"))

        // With CD-ROM media present, D: is reserved for CD-ROM imgmount.
        var cdGame = Game(title: "Wing Commander", source: .managed)
        cdGame.media = [MediaImage(relativePath: "media/disc1.iso", kind: .cdrom)]
        let cdMount = try #require(DrivesSection.appendFolderMount(url: dir1, to: &cdGame))
        #expect(cdMount.driveLetter == "E")
        #expect(!DrivesSection.availableDriveLetters(for: 0, in: cdGame).contains("D"))

        // Adding a CD-ROM after a D: folder mount was already configured shifts D: to the next free letter
        // and never leaves D: selectable while CD-ROM media is present.
        game.media = [MediaImage(relativePath: "media/disc1.iso", kind: .cdrom)]
        #expect(!DrivesSection.availableDriveLetters(for: 0, in: game).contains("D"))
        #expect(FolderMount.reassignConflictsWithCDROM(&game.launch.folderMounts, hasCDROM: true))
        #expect(game.launch.folderMounts.map(\.driveLetter) == ["F", "E"])

        // When all D:–Y: letters are already occupied by folder mounts, reassignConflictsWithCDROM reports failure.
        var fullMounts = FolderMount.availableDriveLetters.map {
            FolderMount(driveLetter: $0, path: dir1.path, bookmark: Data())
        }
        #expect(!FolderMount.reassignConflictsWithCDROM(&fullMounts, hasCDROM: true))

        // Missing extra folder mount reports a dedicated alert without offering .resetCRoot even when driveCRoot is set.
        game.launch.driveCRoot = "SUB"
        let alert = AppModel.alert(
            for: .folderMountMissing(driveLetter: "F", path: "/missing/Saves"),
            gameID: game.id,
            game: game
        )
        #expect(alert.title == "Mounted folder not found")
        #expect(alert.fix == nil)
    }

    @Test func startupSectionAndSetupActionsConfigureAndShowSetupControls() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "setup-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var game = Game(title: "Doom", source: .managed)
        game.launch.executable = "DOOM.EXE"
        var record = GameRecord(game: game, crateURL: root.appending(path: "Doom.doscrate"))

        #expect(!GameHeader.showsSetupButton(for: record))
        #expect(!GameContextMenu.showsRunSetup(for: record, running: []))

        let box = Box(game)
        let gameBinding = Binding<Game>(get: { box.value }, set: { box.value = $0 })
        let mainPicker = ExecutablePicker(record: record, game: box.value, executable: gameBinding.launch.executable)
        let setupPicker = ExecutablePicker(
            title: "Setup program",
            record: record,
            game: box.value,
            executable: gameBinding.launch.setupExecutable
        )
        #expect(mainPicker.title == "Program")
        #expect(setupPicker.title == "Setup program")

        gameBinding.launch.setupExecutable.wrappedValue = "SETUP.EXE"
        #expect(box.value.launch.setupExecutable == "SETUP.EXE")
        record.game = box.value

        #expect(GameHeader.showsSetupButton(for: record))
        #expect(!GameHeader.showsSetupButton(for: record, running: true))
        #expect(!GameHeader.showsSetupButton(for: record, starting: true))
        #expect(!GameHeader.showsSetupButton(for: record, importing: true))
        #expect(GameContextMenu.showsRunSetup(for: record, running: []))
        #expect(!GameContextMenu.showsRunSetup(for: record, running: [record.id]))

        let startupHosting = NSHostingView(rootView: StartupSection(record: record, game: gameBinding))
        startupHosting.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        startupHosting.layoutSubtreeIfNeeded()
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

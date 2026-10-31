import AppKit
import ConfigKit
import Foundation
import ImportKit
import LauncherKit
import LibraryKit
import SwiftUI
import Testing
@testable import DOSCrate

@MainActor
struct ArtStripTests {
    @Test func artItemsOrderBackDiscLogoThenScreenshots() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "art-strip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let crate = root.appending(path: "Doom.doscrate")
        let io = CrateIO()
        let s2 = io.screenshotURL(crate, index: 2)
        let s1 = io.screenshotURL(crate, index: 1)
        let logo = io.logoURL(crate)
        let disc = io.discURL(crate)
        let back = io.backURL(crate)
        let cover = io.coverURL(crate)

        try FileManager.default.createDirectory(at: s1.deletingLastPathComponent(), withIntermediateDirectories: true)

        let png = Data([0x89, 0x50, 0x4E, 0x47])
        for url in [s2, s1, logo, disc, back, cover] {
            try png.write(to: url)
        }

        let items = ArtStripView.items(in: crate)
        #expect(items.map(\.lastPathComponent) == ["back.png", "disc.png", "logo.png", "01.png", "02.png"])
        #expect(items.map(\.standardizedFileURL) == [back, disc, logo, s1, s2].map(\.standardizedFileURL))
        #expect(!ArtStripView.isHidden(in: crate))
        #expect(GameDetailView.headerCoverWidth == 140)
        #expect(ArtStripView.thumbnailSize == CGSize(width: 112, height: 84))
    }

    @Test func noArtMeansHidden() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "art-strip-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let crate = root.appending(path: "Empty.doscrate")
        try FileManager.default.createDirectory(at: crate, withIntermediateDirectories: true)

        // Even with a front cover, extra art strip is empty/hidden
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: CrateIO().coverURL(crate))

        #expect(ArtStripView.items(in: crate).isEmpty)
        #expect(ArtStripView.isHidden(in: crate))
    }

    @Test func descriptionEditSavesThroughPendingWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "desc-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let lib = root.appending(path: "Library", directoryHint: .isDirectory)
        try fm.createDirectory(at: lib, withIntermediateDirectories: true)

        let io = CrateIO()
        let crate = try io.makeCrate(title: "Doom", in: lib)
        var game = Game(title: "Doom", source: .managed)
        game.launch.executable = "DOOM.EXE"
        try io.save(game, extra: [:], to: crate)
        let exeURL = crate.appending(path: "files/DOOM.EXE")
        try fm.createDirectory(at: exeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: exeURL)

        let dosbox = root.appending(path: "dosbox")
        try Data("#!/bin/sh\n".utf8).write(to: dosbox)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dosbox.path)

        let defaults = UserDefaults(suiteName: "doscrate-desc-\(UUID().uuidString)")!
        let prefs = Preferences(defaults: defaults)
        let store = LibraryStore(library: lib)
        await store.reload()

        let runner = FakeRunner()
        let model = AppModel(
            prefs: prefs,
            store: store,
            sessions: SessionManager(runner: runner),
            importer: Importer(),
            dosbox: dosbox,
            verifyDosbox: { _ in }
        )

        let id = game.id
        var draft = try #require(store.record(id)?.game)
        draft.description = "A marine fights demons on Phobos."

        let saveTask = GameDetailView.scheduleDraftSave(draft: draft, in: model)
        #expect(saveTask != nil)

        // Launching immediately flushes pending writes registered with setPendingWrite
        let playTask = model.play(id)
        await waitUntil { !runner.processes.isEmpty }
        #expect(store.record(id)?.game.description == "A marine fights demons on Phobos.")

        runner.processes[0].finish(0)
        await playTask?.value
    }

    @Test func addAndRemoveArtAndSessionEndBumpArtRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "art-strip-ops-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let lib = root.appending(path: "Library", directoryHint: .isDirectory)
        try fm.createDirectory(at: lib, withIntermediateDirectories: true)

        let io = CrateIO()
        let crate = try io.makeCrate(title: "Doom", in: lib)
        var game = Game(title: "Doom", source: .managed)
        game.launch.executable = "DOOM.EXE"
        try io.save(game, extra: [:], to: crate)
        let exeURL = crate.appending(path: "files/DOOM.EXE")
        try fm.createDirectory(at: exeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: exeURL)

        let dosbox = root.appending(path: "dosbox")
        try Data("#!/bin/sh\n".utf8).write(to: dosbox)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dosbox.path)

        let defaults = UserDefaults(suiteName: "doscrate-art-ops-\(UUID().uuidString)")!
        let prefs = Preferences(defaults: defaults)
        let store = LibraryStore(library: lib)
        await store.reload()

        let runner = FakeRunner()
        let model = AppModel(
            prefs: prefs,
            store: store,
            sessions: SessionManager(runner: runner),
            importer: Importer(),
            dosbox: dosbox,
            verifyDosbox: { _ in }
        )
        let record = try #require(store.record(game.id))

        // Create a valid 2x2 image file to add as cover and screenshot
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let pngData = try #require(rep.representation(using: .png, properties: [:]))
        let sampleImageURL = root.appending(path: "sample.png")
        try pngData.write(to: sampleImageURL)

        #expect(model.metadata.artRevision[record.id, default: 0] == 0)

        // Setting cover writes cover.png and bumps artRevision
        #expect(GameDetailView.setCover(from: [sampleImageURL], for: record, in: model))
        #expect(fm.fileExists(atPath: io.coverURL(crate).path))
        #expect(model.metadata.artRevision[record.id] == 1)

        // Removing cover trashes cover.png and bumps artRevision
        #expect(GameDetailView.removeCover(for: record, in: model))
        #expect(!fm.fileExists(atPath: io.coverURL(crate).path))
        #expect(model.metadata.artRevision[record.id] == 2)

        // Adding screenshot writes screenshot-01.png and bumps artRevision
        #expect(ArtStripView.addScreenshots(from: [sampleImageURL], in: crate, gameID: record.id, model: model))
        let items = ArtStripView.items(in: crate)
        #expect(items.map(\.lastPathComponent) == ["screenshot-01.png"])
        #expect(model.metadata.artRevision[record.id] == 3)

        // Removing screenshot trashes screenshot-01.png and bumps artRevision
        #expect(ArtStripView.removeArtItem(at: items[0], gameID: record.id, model: model))
        #expect(ArtStripView.items(in: crate).isEmpty)
        #expect(model.metadata.artRevision[record.id] == 4)

        // Ending a gameplay session bumps artRevision so DOSBox captures appear immediately
        let playTask = model.play(record.id)
        await waitUntil { !runner.processes.isEmpty }
        runner.processes[0].finish(0)
        await playTask?.value
        await waitUntil { model.metadata.artRevision[record.id] == 5 }
        #expect(model.metadata.artRevision[record.id] == 5)
    }
}

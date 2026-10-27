import Foundation
import Testing
import LibraryKit
@testable import LauncherKit

/// A temp library with a managed crate and a fake (executable) dosbox.
struct Fixture {
    let root: URL
    let crate: URL
    let dosbox: URL
    let io = CrateIO()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doscrate-\(UUID().uuidString)")
        crate = root.appendingPathComponent("G.doscrate")
        try FileManager.default.createDirectory(at: crate.appendingPathComponent("files"), withIntermediateDirectories: true)
        dosbox = root.appendingPathComponent("dosbox")
        try Data("#!/bin/sh\n".utf8).write(to: dosbox)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dosbox.path)
    }

    func touch(_ rel: String) throws {
        let url = crate.appendingPathComponent("files/" + rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    func record(executable: String?, exitWhenDone: Bool = true) -> GameRecord {
        var g = Game(title: "G", source: .managed)
        g.launch.executable = executable
        g.launch.exitWhenDone = exitWhenDone
        return GameRecord(game: g, crateURL: crate)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct PreflightTests {
    @Test func preflightOK() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.touch("GAME.EXE")
        let c = try Preflight.check(f.record(executable: "GAME.EXE"), io: f.io, dosbox: f.dosbox)
        #expect(c.lastPathComponent == "files")
    }

    @Test func preflightReportsNonDOSPathWithSuggestedRoot() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.touch("Commander Keen/keen1.exe")
        #expect(throws: LaunchError.nonDOSPath(component: "Commander Keen", suggestedCRoot: "Commander Keen")) {
            try Preflight.check(f.record(executable: "Commander Keen/keen1.exe"), io: f.io, dosbox: f.dosbox)
        }
        try f.touch("KEEN/Long Name.exe")
        #expect(throws: LaunchError.nonDOSPath(component: "Long Name.exe", suggestedCRoot: "KEEN/Long Name.exe")) {
            try Preflight.check(f.record(executable: "KEEN/Long Name.exe"), io: f.io, dosbox: f.dosbox)
        }
    }

    @Test func preflightMissingExecutable() throws {
        let f = try Fixture(); defer { f.cleanup() }
        #expect(throws: LaunchError.executableMissing(path: "GAME.EXE")) {
            try Preflight.check(f.record(executable: "GAME.EXE"), io: f.io, dosbox: f.dosbox)
        }
    }

    @Test func preflightExecutableNotSetOnlyAllowedWithMedia() throws {
        let f = try Fixture(); defer { f.cleanup() }
        #expect(throws: LaunchError.executableNotSet) {
            try Preflight.check(f.record(executable: nil), io: f.io, dosbox: f.dosbox)
        }
        var r = f.record(executable: nil)
        try FileManager.default.createDirectory(at: f.crate.appendingPathComponent("media"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: f.crate.appendingPathComponent("media/d.iso"))
        r.game.media = [MediaImage(relativePath: "media/d.iso", kind: .cdrom)]
        _ = try Preflight.check(r, io: f.io, dosbox: f.dosbox)
    }

    @Test func preflightUnreachableReference() throws {
        let f = try Fixture(); defer { f.cleanup() }
        var r = f.record(executable: "GAME.EXE")
        r.status = .missingSource
        r.game.source = .referenced(path: "/nope/game", bookmark: Data())
        #expect(throws: LaunchError.sourceUnreachable(path: "/nope/game")) {
            try Preflight.check(r, io: f.io, dosbox: f.dosbox)
        }
    }

    @Test func preflightMissingMediaIsMediaMissing() throws {
        let f = try Fixture(); defer { f.cleanup() }
        var r = f.record(executable: nil)
        r.game.media = [MediaImage(relativePath: "media/gone.iso", kind: .cdrom)]
        #expect(throws: LaunchError.mediaMissing(path: f.crate.appendingPathComponent("media/gone.iso").path)) {
            try Preflight.check(r, io: f.io, dosbox: f.dosbox)
        }
    }

    @Test func preflightBadDriveCRootIsCRootMissing() throws {
        let f = try Fixture(); defer { f.cleanup() }
        var r = f.record(executable: "GAME.EXE")
        r.game.launch.driveCRoot = "NOPE"
        #expect(throws: LaunchError.cRootMissing(path: f.crate.appendingPathComponent("files/NOPE").path)) {
            try Preflight.check(r, io: f.io, dosbox: f.dosbox)
        }
    }

    @Test func preflightManagedWithoutFilesIsCRootMissing() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try FileManager.default.removeItem(at: f.crate.appendingPathComponent("files"))
        #expect(throws: LaunchError.cRootMissing(path: f.crate.appendingPathComponent("files").path)) {
            try Preflight.check(f.record(executable: "GAME.EXE"), io: f.io, dosbox: f.dosbox)
        }
    }

    @Test func preflightNeedsRepair() throws {
        let f = try Fixture(); defer { f.cleanup() }
        var r = f.record(executable: "GAME.EXE")
        r.status = .needsRepair(reason: "bad")
        #expect(throws: LaunchError.needsRepair) { try Preflight.check(r, io: f.io, dosbox: f.dosbox) }
    }

    @Test func preflightDosboxMissing() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.touch("GAME.EXE")
        #expect(throws: LaunchError.dosboxMissing) {
            try Preflight.check(f.record(executable: "GAME.EXE"), io: f.io, dosbox: f.root.appendingPathComponent("nodosbox"))
        }
    }

    @Test func locatorVerifyRejectsMissingAndUnsigned() throws {
        let f = try Fixture(); defer { f.cleanup() }
        #expect(throws: LaunchError.dosboxMissing) { try StagingLocator.verify(f.root.appendingPathComponent("nope")) }
        #expect(throws: LaunchError.dosboxMissing) { try StagingLocator.verify(f.dosbox) }
        #expect(StagingLocator.dosboxURL(appBundle: Bundle(path: f.root.path) ?? .main).path.hasSuffix("DOSBox Staging.app/Contents/MacOS/dosbox"))
    }
}

@Test(.enabled(if: TestStaging.dosboxURL != nil))
func locatorVerifyAcceptsVendoredStaging() throws {
    try StagingLocator.verify(try #require(TestStaging.dosboxURL))
}

import Foundation
import Testing
import LibraryKit
@testable import ConfigKit

private func lines(_ l: LaunchSpec, c: String = "/tmp/Keen", media: [(URL, MediaKind)] = []) throws -> [String] {
    try AutoexecBuilder.lines(cDrive: URL(fileURLWithPath: c), media: media, launch: l)
}

@Test func isValid83() {
    for ok in ["KEEN1.EXE", "keen1.exe", "A"] { #expect(DOSPath.isValid83(ok), "\(ok)") }
    for bad in ["startgame.bat", "Commander Keen", "A.B.C", "TOOLONGNM.EXE", "X.ABCD", "", ".EXE", "A."] {
        #expect(!DOSPath.isValid83(bad), "\(bad)")
    }
}

@Test func dosPathUppercasesAndUsesBackslashes() throws {
    #expect(try DOSPath.dosPath(relative: "game/keen1.exe") == "GAME\\KEEN1.EXE")
    #expect(try DOSPath.dosPath(relative: "KEEN1.EXE") == "KEEN1.EXE")
}

@Test func mountQuotesSpacesAndRejectsQuoteChars() throws {
    let l = try lines(LaunchSpec(executable: "KEEN1.EXE"), c: "/tmp/My Games/Keen")
    #expect(l[0] == "mount c \"/tmp/My Games/Keen\"")
    #expect(throws: DOSPathError.unquotablePath("/tmp/a\"b")) {
        try lines(LaunchSpec(executable: "KEEN1.EXE"), c: "/tmp/a\"b")
    }
}

@Test func exeInSubdirEmitsCd() throws {
    let l = try lines(LaunchSpec(executable: "GAME/KEEN1.EXE"))
    #expect(l == ["mount c \"/tmp/Keen\"", "c:", "cd \\GAME", "KEEN1.EXE"])
}

@Test func multiDiscImgmount() throws {
    let media: [(URL, MediaKind)] = [
        (URL(fileURLWithPath: "/m/d1.iso"), .cdrom), (URL(fileURLWithPath: "/m/boot.img"), .floppy),
        (URL(fileURLWithPath: "/m/d2.iso"), .cdrom),
    ]
    let l = try lines(LaunchSpec(executable: "SETUP.EXE"), media: media)
    #expect(l[1] == "imgmount d \"/m/d1.iso\" \"/m/d2.iso\" -t iso")
    #expect(l[2] == "imgmount a \"/m/boot.img\" -t floppy")
    #expect(l[3] == "c:")
}

@Test func multipleFloppiesShareOneImgmount() throws {
    let media: [(URL, MediaKind)] = [
        (URL(fileURLWithPath: "/m/disk1.img"), .floppy), (URL(fileURLWithPath: "/m/disk2.img"), .floppy),
    ]
    let l = try lines(LaunchSpec(executable: "INSTALL.EXE"), media: media)
    #expect(l.filter { $0.hasPrefix("imgmount a") } == ["imgmount a \"/m/disk1.img\" \"/m/disk2.img\" -t floppy"])
}

@Test func argumentsAndPrePostCommandsOrdered() throws {
    let l = try lines(LaunchSpec(executable: "GAME/G.EXE", arguments: " /v ", preCommands: ["set X=1"], postCommands: ["echo done"]))
    #expect(Array(l.dropFirst()) == ["c:", "cd \\GAME", "set X=1", "G.EXE /v", "echo done"])
}

@Test func nonDOSPathThrows() {
    #expect(throws: DOSPathError.notDOSName(component: "Commander Keen", parentRelative: "")) {
        try lines(LaunchSpec(executable: "Commander Keen/keen1.exe"))
    }
    #expect(throws: DOSPathError.notDOSName(component: "my game", parentRelative: "GAME")) {
        try DOSPath.dosPath(relative: "GAME/my game/a.exe")
    }
}

@Test func noExitLine() throws {
    let l = try lines(LaunchSpec(executable: "A.EXE", exitWhenDone: true))
    #expect(!l.contains("exit"))
}

@Test func noExecutableStopsAtShell() throws {
    #expect(try lines(LaunchSpec()) == ["mount c \"/tmp/Keen\"", "c:"])
}

@Test func extraFolderMountsEmitBeforeSwitchingToCDrive() throws {
    let media: [(URL, MediaKind)] = [
        (URL(fileURLWithPath: "/m/disc.iso"), .cdrom)
    ]
    let mounts: [(String, URL)] = [
        ("E", URL(fileURLWithPath: "/tmp/Extra Saves")),
        ("F", URL(fileURLWithPath: "/tmp/Patches")),
    ]
    let l = try AutoexecBuilder.lines(
        cDrive: URL(fileURLWithPath: "/tmp/Keen"),
        media: media,
        folderMounts: mounts,
        launch: LaunchSpec(executable: "KEEN1.EXE")
    )
    #expect(l == [
        "mount c \"/tmp/Keen\"",
        "imgmount d \"/m/disc.iso\" -t iso",
        "mount e \"/tmp/Extra Saves\"",
        "mount f \"/tmp/Patches\"",
        "c:",
        "KEEN1.EXE",
    ])
}

@Test func folderMountOnDShiftsToFirstFreeLetterWhenCDROMPresent() throws {
    let media: [(URL, MediaKind)] = [
        (URL(fileURLWithPath: "/m/disc.iso"), .cdrom)
    ]
    let mounts: [(String, URL)] = [
        ("D", URL(fileURLWithPath: "/tmp/Saves")),
        ("E", URL(fileURLWithPath: "/tmp/Mods")),
    ]
    let l = try AutoexecBuilder.lines(
        cDrive: URL(fileURLWithPath: "/tmp/Keen"),
        media: media,
        folderMounts: mounts,
        launch: LaunchSpec(executable: "KEEN1.EXE")
    )
    #expect(l == [
        "mount c \"/tmp/Keen\"",
        "imgmount d \"/m/disc.iso\" -t iso",
        "mount f \"/tmp/Saves\"",
        "mount e \"/tmp/Mods\"",
        "c:",
        "KEEN1.EXE",
    ])
}

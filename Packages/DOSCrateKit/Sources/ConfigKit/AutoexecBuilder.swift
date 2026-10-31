import Foundation
import LibraryKit

public enum AutoexecBuilder {
    public static func lines(
        cDrive: URL,
        media: [(URL, MediaKind)],
        folderMounts: [(String, URL)] = [],
        launch: LaunchSpec,
        launchSetup: Bool = false
    ) throws(DOSPathError) -> [String] {
        var out = ["mount c \(try quoted(cDrive.path))"]
        var cds: [String] = []
        for (url, kind) in media where kind == .cdrom { cds.append(try quoted(url.path)) }
        if !cds.isEmpty { out.append("imgmount d \(cds.joined(separator: " ")) -t iso") }
        var floppies: [String] = []
        for (url, kind) in media where kind == .floppy { floppies.append(try quoted(url.path)) }
        if !floppies.isEmpty { out.append("imgmount a \(floppies.joined(separator: " ")) -t floppy") }
        let hasCDROM = !cds.isEmpty
        var usedLetters = Set(folderMounts.map { $0.0.uppercased() })
        if hasCDROM { usedLetters.insert("D") }
        for (rawLetter, url) in folderMounts {
            var letter = rawLetter.uppercased()
            if hasCDROM && letter == "D",
               let fallback = FolderMount.availableDriveLetters.first(where: { !usedLetters.contains($0) }) {
                letter = fallback
                usedLetters.insert(letter)
            }
            out.append("mount \(letter.lowercased()) \(try quoted(url.path))")
        }
        out.append("c:")
        let targetExecutable = launchSetup ? launch.setupExecutable : launch.executable
        if let exe = targetExecutable, !exe.isEmpty {
            let dos = try DOSPath.dosPath(relative: exe)
            let name: String
            if let slash = dos.lastIndex(of: "\\") {
                out.append("cd \\" + dos[..<slash])
                name = String(dos[dos.index(after: slash)...])
            } else {
                name = dos
            }
            out += launch.preCommands
            if launchSetup {
                out.append(name)
            } else {
                let args = launch.arguments.trimmingCharacters(in: .whitespaces)
                out.append(args.isEmpty ? name : "\(name) \(args)")
            }
        } else {
            out += launch.preCommands
        }
        out += launch.postCommands
        return out
    }

    private static func quoted(_ path: String) throws(DOSPathError) -> String {
        if path.contains("\"") { throw .unquotablePath(path) }
        return "\"\(path)\""
    }
}

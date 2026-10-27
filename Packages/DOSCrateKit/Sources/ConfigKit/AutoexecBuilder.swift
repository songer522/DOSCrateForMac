import Foundation
import LibraryKit

public enum AutoexecBuilder {
    public static func lines(cDrive: URL, media: [(URL, MediaKind)], launch: LaunchSpec) throws(DOSPathError) -> [String] {
        var out = ["mount c \(try quoted(cDrive.path))"]
        var cds: [String] = []
        for (url, kind) in media where kind == .cdrom { cds.append(try quoted(url.path)) }
        if !cds.isEmpty { out.append("imgmount d \(cds.joined(separator: " ")) -t iso") }
        var floppies: [String] = []
        for (url, kind) in media where kind == .floppy { floppies.append(try quoted(url.path)) }
        if !floppies.isEmpty { out.append("imgmount a \(floppies.joined(separator: " ")) -t floppy") }
        out.append("c:")
        if let exe = launch.executable, !exe.isEmpty {
            let dos = try DOSPath.dosPath(relative: exe)
            let name: String
            if let slash = dos.lastIndex(of: "\\") {
                out.append("cd \\" + dos[..<slash])
                name = String(dos[dos.index(after: slash)...])
            } else {
                name = dos
            }
            out += launch.preCommands
            let args = launch.arguments.trimmingCharacters(in: .whitespaces)
            out.append(args.isEmpty ? name : "\(name) \(args)")
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

import Foundation

public enum DOSPathError: Error, Equatable {
    case notDOSName(component: String, parentRelative: String)
    case unquotablePath(String)
}

public enum DOSPath {
    private static let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&'()-@^_`{}~")

    /// True for a plain 8.3 name: 1-8 chars, optional 1-3 char extension, no spaces.
    public static func isValid83(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let base = parts.first else { return false }
        guard (1...8).contains(base.count), base.allSatisfy(allowed.contains) else { return false }
        if parts.count == 2 {
            let ext = parts[1]
            guard (1...3).contains(ext.count), ext.allSatisfy(allowed.contains) else { return false }
        }
        return true
    }

    /// '/'-separated relative path to an uppercased, backslash-separated DOS path, e.g. `GAME\KEEN1.EXE`.
    public static func dosPath(relative: String) throws(DOSPathError) -> String {
        let components = relative.split(separator: "/").map(String.init)
        var out: [String] = []
        for (i, c) in components.enumerated() {
            guard isValid83(c) else {
                throw .notDOSName(component: c, parentRelative: components[..<i].joined(separator: "/"))
            }
            out.append(c.uppercased())
        }
        return out.joined(separator: "\\")
    }
}

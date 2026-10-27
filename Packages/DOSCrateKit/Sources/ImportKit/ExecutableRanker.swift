import Foundation

public struct ExecutableCandidate: Equatable, Sendable {
    /// '/'-separated path relative to the ranked root.
    public var relativePath: String
    public var score: Int

    public init(relativePath: String, score: Int) {
        self.relativePath = relativePath
        self.score = score
    }
}

public enum ExecutableRanker {
    static let maxDepth = 4
    static let extensions: Set<String> = ["exe", "com", "bat"]
    static let setupNames: Set<String> = [
        "setup", "install", "installer", "config", "setsound", "sound", "uninst", "uninstal", "setmain", "readme",
    ]
    static let utilityNames: Set<String> = ["pkunzip", "pkzip", "lha", "arj", "unzip", "dos4gw", "cwsdpmi"]

    public static func rank(root: URL, title: String) throws -> [ExecutableCandidate] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let titleWords = title.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }.filter { !$0.isEmpty }
        var found: [(candidate: ExecutableCandidate, depth: Int, size: Int)] = []

        for case let url as URL in walker {
            let parts = Array(url.pathComponents.suffix(walker.level))
            let depth = walker.level - 1
            if depth > maxDepth {
                walker.skipDescendants()
                continue
            }
            // One unreadable entry must not fail the whole import; it just isn't a candidate.
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, extensions.contains(url.pathExtension.lowercased()) else { continue }

            let base = url.deletingPathExtension().lastPathComponent
            var score = 100
            if matches(name: normalize(base), words: titleWords) { score += 50 }
            if depth == 0 { score += 20 }
            score -= 10 * depth
            let lowered = base.lowercased()
            if setupNames.contains(lowered) { score -= 80 }
            if utilityNames.contains(lowered) { score -= 60 }
            found.append((ExecutableCandidate(relativePath: parts.joined(separator: "/"), score: score),
                          depth, values.fileSize ?? 0))
        }

        return found.sorted {
            if $0.candidate.score != $1.candidate.score { return $0.candidate.score > $1.candidate.score }
            if $0.depth != $1.depth { return $0.depth < $1.depth }
            if $0.size != $1.size { return $0.size > $1.size }
            return $0.candidate.relativePath < $1.candidate.relativePath
        }.map(\.candidate)
    }

    private static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    private static func matches(name: String, words: [String]) -> Bool {
        guard name.count >= 3, !words.isEmpty else { return false }
        let joined = words.joined()
        if joined.hasPrefix(name) || name.hasPrefix(joined) { return true }
        if words.contains(name) { return true }
        return zip(words, words.dropFirst()).contains { $0 + $1 == name }
    }
}

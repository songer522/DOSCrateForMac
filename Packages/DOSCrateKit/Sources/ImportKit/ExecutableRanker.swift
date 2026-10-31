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
        "setup", "install", "installer", "config", "configure", "setsound", "sndsetup", "sound",
        "uninst", "uninstal", "setmain", "readme",
    ]
    static let setupUtilityStems: [String] = [
        "setup", "install", "setsound", "sndsetup", "sound", "config", "configure",
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

    public static func rankSetup(root: URL) throws -> [ExecutableCandidate] {
        rankSetup(in: try rank(root: root, title: ""))
    }

    public static func rankSetup(in candidates: [ExecutableCandidate]) -> [ExecutableCandidate] {
        var found: [(candidate: ExecutableCandidate, depth: Int, extRank: Int, stemIndex: Int)] = []
        for candidate in candidates {
            let parts = candidate.relativePath.split(separator: "/")
            let depth = max(0, parts.count - 1)
            let fileName = parts.last.map(String.init) ?? candidate.relativePath
            let url = URL(filePath: fileName)
            let ext = url.pathExtension.lowercased()
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            guard let stemIndex = setupUtilityStems.firstIndex(of: stem),
                  let extRank = extensionRank(ext) else { continue }
            let stemBonus = setupUtilityStems.count - stemIndex
            let score = 200 - 30 * depth + extRank + stemBonus
            found.append((ExecutableCandidate(relativePath: candidate.relativePath, score: score),
                          depth, extRank, stemIndex))
        }
        return found.sorted {
            if $0.depth != $1.depth { return $0.depth < $1.depth }
            if $0.extRank != $1.extRank { return $0.extRank > $1.extRank }
            if $0.stemIndex != $1.stemIndex { return $0.stemIndex < $1.stemIndex }
            return $0.candidate.relativePath < $1.candidate.relativePath
        }.map(\.candidate)
    }

    public static func bestSetupExecutable(
        in candidates: [ExecutableCandidate],
        excluding executable: String? = nil
    ) -> String? {
        let excluded = executable?.trimmingCharacters(in: .whitespacesAndNewlines)
        return rankSetup(in: candidates).first { candidate in
            guard let excluded, !excluded.isEmpty else { return true }
            return candidate.relativePath.caseInsensitiveCompare(excluded) != .orderedSame
        }?.relativePath
    }

    private static func extensionRank(_ ext: String) -> Int? {
        switch ext {
        case "exe": 30
        case "com": 20
        case "bat": 10
        default: nil
        }
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

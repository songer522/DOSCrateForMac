import Foundation

public struct MatchCandidate: Sendable, Equatable {
    public var record: LaunchBoxRecord
    public var score: Double

    public init(record: LaunchBoxRecord, score: Double) {
        self.record = record
        self.score = score
    }
}

public enum TitleMatcher {
    public static let autoThreshold = 0.9
    public static let autoMargin = 0.1
    public static let searchFloor = 0.3

    private static let romanToDigits: [String: String] = [
        "ii": "2",
        "iii": "3",
        "iv": "4",
        "v": "5",
        "vi": "6",
        "vii": "7",
        "viii": "8",
        "ix": "9",
        "x": "10",
    ]

    public static func parseYear(_ s: String) -> Int? {
        guard let match = s.firstMatch(of: /\(((?:19|20)\d{2})\)/) else {
            return nil
        }
        return Int(match.1)
    }

    public static func normalize(_ s: String) -> String {
        var text = s.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()

        // Strip trailing version and parenthesized/bracketed tags repeatedly.
        let trailingTagPattern = /(?:\s*(?:\([^)]*\)|\[[^\]]*\])|\s+v\d+(?:[.\d]*[a-z]?)?)\s*$/
        while let match = text.firstMatch(of: trailingTagPattern) {
            text.removeSubrange(match.range)
        }

        text = text.replacingOccurrences(of: "&", with: " and ")

        var cleaned = ""
        cleaned.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                cleaned.unicodeScalars.append(scalar)
            } else {
                cleaned.append(" ")
            }
        }

        // Split trailing digits from letters on tokens (e.g., doom2 -> doom 2).
        var words: [String] = []
        for rawToken in cleaned.split(whereSeparator: \.isWhitespace) {
            let token = String(rawToken)
            if let splitMatch = token.wholeMatch(of: /([a-z]+)(\d+)/) {
                words.append(String(splitMatch.1))
                words.append(String(splitMatch.2))
            } else {
                words.append(token)
            }
        }

        if words.count > 1, words.first == "the" {
            words.removeFirst()
        }

        words = words.map { romanToDigits[$0] ?? $0 }
        return words.joined(separator: " ")
    }

    public static func matches(
        for title: String,
        in records: [LaunchBoxRecord],
        limit: Int
    ) -> [MatchCandidate] {
        guard limit > 0 else { return [] }
        let queryNorm = normalize(title)
        guard !queryNorm.isEmpty else { return [] }
        let queryWords = queryNorm.split(separator: " ").map(String.init)
        let queryBigrams = bigrams(for: queryWords)
        let queryYear = parseYear(title)

        var candidates: [(candidate: MatchCandidate, yearMatched: Bool, wordCount: Int)] = []
        candidates.reserveCapacity(records.count)

        for record in records {
            let nameNorm = normalize(record.name)
            var best = scoreNormalized(queryNorm: queryNorm, queryWords: queryWords, queryBigrams: queryBigrams, candNorm: nameNorm)
            for alt in record.alternateNames {
                let altNorm = normalize(alt)
                let s = scoreNormalized(queryNorm: queryNorm, queryWords: queryWords, queryBigrams: queryBigrams, candNorm: altNorm)
                if s > best { best = s }
            }
            guard best > 0 else { continue }
            let yearMatched = (queryYear != nil && queryYear == record.releaseYear)
            if yearMatched {
                best = min(1.0, best + 0.05)
            }
            let nameWordCount = nameNorm.split(separator: " ").count
            candidates.append((MatchCandidate(record: record, score: best), yearMatched, nameWordCount))
        }

        candidates.sort { lhs, rhs in
            if abs(lhs.candidate.score - rhs.candidate.score) > 1e-12 {
                return lhs.candidate.score > rhs.candidate.score
            }
            if lhs.yearMatched != rhs.yearMatched {
                return lhs.yearMatched && !rhs.yearMatched
            }
            if lhs.wordCount != rhs.wordCount {
                return lhs.wordCount < rhs.wordCount
            }
            let cmp = lhs.candidate.record.name.localizedStandardCompare(rhs.candidate.record.name)
            if cmp != .orderedSame {
                return cmp == .orderedAscending
            }
            return lhs.candidate.record.id < rhs.candidate.record.id
        }

        return Array(candidates.prefix(limit).map(\.candidate))
    }

    public static func searchScore(_ query: String, _ record: LaunchBoxRecord) -> Double {
        let queryNorm = normalize(query)
        guard !queryNorm.isEmpty else { return 0 }
        let queryWords = queryNorm.split(separator: " ").map(String.init)
        let queryBigrams = bigrams(for: queryWords)
        let queryTrigrams = charTrigrams(for: queryNorm)
        let queryYear = parseYear(query)

        return searchScorePrecomputed(
            queryNorm: queryNorm,
            queryWords: queryWords,
            queryBigrams: queryBigrams,
            queryTrigrams: queryTrigrams,
            queryYear: queryYear,
            record: record
        ).score
    }

    public static func search(
        for title: String,
        in records: [LaunchBoxRecord],
        limit: Int
    ) -> [MatchCandidate] {
        guard limit > 0 else { return [] }
        let queryNorm = normalize(title)
        guard !queryNorm.isEmpty else { return [] }
        let queryWords = queryNorm.split(separator: " ").map(String.init)
        let queryBigrams = bigrams(for: queryWords)
        let queryTrigrams = charTrigrams(for: queryNorm)
        let queryYear = parseYear(title)

        var candidates: [(candidate: MatchCandidate, yearMatched: Bool, wordCount: Int)] = []
        candidates.reserveCapacity(records.count)

        for record in records {
            let result = searchScorePrecomputed(
                queryNorm: queryNorm,
                queryWords: queryWords,
                queryBigrams: queryBigrams,
                queryTrigrams: queryTrigrams,
                queryYear: queryYear,
                record: record
            )
            guard result.score + 1e-12 >= searchFloor else { continue }
            candidates.append((MatchCandidate(record: record, score: result.score), result.yearMatched, result.nameWordCount))
        }

        candidates.sort { lhs, rhs in
            if abs(lhs.candidate.score - rhs.candidate.score) > 1e-12 {
                return lhs.candidate.score > rhs.candidate.score
            }
            if lhs.yearMatched != rhs.yearMatched {
                return lhs.yearMatched && !rhs.yearMatched
            }
            if lhs.wordCount != rhs.wordCount {
                return lhs.wordCount < rhs.wordCount
            }
            let cmp = lhs.candidate.record.name.localizedStandardCompare(rhs.candidate.record.name)
            if cmp != .orderedSame {
                return cmp == .orderedAscending
            }
            return lhs.candidate.record.id < rhs.candidate.record.id
        }

        return Array(candidates.prefix(limit).map(\.candidate))
    }

    public static func autoMatch(
        for title: String,
        in records: [LaunchBoxRecord]
    ) -> LaunchBoxRecord? {
        let top = matches(for: title, in: records, limit: 2)
        guard let best = top.first, best.score + 1e-9 >= autoThreshold else {
            return nil
        }
        if top.count >= 2 {
            let runnerUp = top[1]
            guard (best.score - runnerUp.score) + 1e-9 >= autoMargin else {
                return nil
            }
        }
        return best.record
    }

    private static func scoreNormalized(
        queryNorm: String,
        queryWords: [String],
        queryBigrams: Set<String>,
        candNorm: String
    ) -> Double {
        guard !candNorm.isEmpty else { return 0 }
        if queryNorm == candNorm {
            return 1.0
        }
        let candWords = candNorm.split(separator: " ").map(String.init)
        let candBigrams = bigrams(for: candWords)

        let diceScore: Double = {
            guard !queryBigrams.isEmpty, !candBigrams.isEmpty else { return 0 }
            let shared = queryBigrams.intersection(candBigrams).count
            return (2.0 * Double(shared)) / Double(queryBigrams.count + candBigrams.count)
        }()

        let containmentScore: Double = {
            let (shorter, longer) = queryWords.count <= candWords.count
                ? (queryWords, candWords)
                : (candWords, queryWords)
            guard !shorter.isEmpty else { return 0 }
            let longerSet = Set(longer)
            guard shorter.allSatisfy({ longerSet.contains($0) }) else { return 0 }
            let sharedCount = shorter.filter { longerSet.contains($0) }.count
            return 0.85 * (Double(sharedCount) / Double(shorter.count))
        }()

        return max(diceScore, containmentScore)
    }

    private static func bigrams(for words: [String]) -> Set<String> {
        guard !words.isEmpty else { return [] }
        if words.count == 1 {
            return [words[0]]
        }
        var out = Set<String>()
        out.reserveCapacity(words.count - 1)
        for i in 0..<(words.count - 1) {
            out.insert("\(words[i]) \(words[i + 1])")
        }
        return out
    }

    private static func searchScorePrecomputed(
        queryNorm: String,
        queryWords: [String],
        queryBigrams: Set<String>,
        queryTrigrams: Set<String>,
        queryYear: Int?,
        record: LaunchBoxRecord
    ) -> (score: Double, yearMatched: Bool, nameWordCount: Int) {
        let nameNorm = normalize(record.name)
        var best = max(
            scoreNormalized(queryNorm: queryNorm, queryWords: queryWords, queryBigrams: queryBigrams, candNorm: nameNorm),
            trigramDiceNormalized(queryNorm: queryNorm, queryTrigrams: queryTrigrams, candNorm: nameNorm)
        )
        for alt in record.alternateNames {
            let altNorm = normalize(alt)
            let s = max(
                scoreNormalized(queryNorm: queryNorm, queryWords: queryWords, queryBigrams: queryBigrams, candNorm: altNorm),
                trigramDiceNormalized(queryNorm: queryNorm, queryTrigrams: queryTrigrams, candNorm: altNorm)
            )
            if s > best { best = s }
        }
        guard best > 0 else { return (0, false, 0) }
        let yearMatched = (queryYear != nil && queryYear == record.releaseYear)
        if yearMatched {
            best = min(1.0, best + 0.05)
        }
        let nameWordCount = nameNorm.split(separator: " ").count
        return (best, yearMatched, nameWordCount)
    }

    private static func trigramDiceNormalized(
        queryNorm: String,
        queryTrigrams: Set<String>,
        candNorm: String
    ) -> Double {
        guard !candNorm.isEmpty else { return 0 }
        if queryNorm == candNorm {
            return 1.0
        }
        let candTrigrams = charTrigrams(for: candNorm)
        guard !queryTrigrams.isEmpty, !candTrigrams.isEmpty else { return 0 }
        let shared = queryTrigrams.intersection(candTrigrams).count
        return (2.0 * Double(shared)) / Double(queryTrigrams.count + candTrigrams.count)
    }

    private static func charTrigrams(for norm: String) -> Set<String> {
        let compact = norm.replacingOccurrences(of: " ", with: "")
        guard !compact.isEmpty else { return [] }
        let chars = Array("  " + compact + "  ")
        guard chars.count >= 3 else { return [] }
        var out = Set<String>()
        out.reserveCapacity(chars.count - 2)
        for i in 0..<(chars.count - 2) {
            out.insert(String(chars[i...(i + 2)]))
        }
        return out
    }
}

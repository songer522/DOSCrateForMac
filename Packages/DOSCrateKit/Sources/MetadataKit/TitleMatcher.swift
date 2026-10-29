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
        guard let precomputed = PrecomputedSearchQuery(query) else { return 0 }
        return searchScorePrecomputed(precomputed, record: record).score
    }

    public static func search(
        for title: String,
        in records: [LaunchBoxRecord],
        limit: Int
    ) -> [MatchCandidate] {
        guard limit > 0, let precomputed = PrecomputedSearchQuery(title) else { return [] }

        var candidates: [(candidate: MatchCandidate, yearMatched: Bool, wordCount: Int)] = []
        candidates.reserveCapacity(records.count)

        for record in records {
            let result = searchScorePrecomputed(precomputed, record: record)
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

    private struct PrecomputedSearchQuery {
        let queryNorm: String
        let queryWords: [String]
        let queryBigrams: Set<String>
        let queryTrigrams: Set<String>
        let effectiveYear: Int?
        let nonYearNorm: String
        let nonYearWords: [String]
        let nonYearBigrams: Set<String>

        init?(_ raw: String) {
            let parenthesizedYear = TitleMatcher.parseYear(raw)
            let norm = TitleMatcher.normalize(raw)
            let words = norm.isEmpty ? [] : norm.split(separator: " ").map(String.init)
            let standaloneYear = words.lazy.compactMap { word -> Int? in
                guard word.count == 4, let y = Int(word), (1970...2099).contains(y) else { return nil }
                return y
            }.first
            let year = parenthesizedYear ?? standaloneYear
            guard !norm.isEmpty || year != nil else { return nil }
            self.queryNorm = norm
            self.queryWords = words
            self.queryBigrams = TitleMatcher.bigrams(for: words)
            self.queryTrigrams = norm.isEmpty ? [] : TitleMatcher.charTrigrams(for: norm)
            self.effectiveYear = year
            let strippedWords = standaloneYear != nil ? words.filter { Int($0) != standaloneYear } : words
            self.nonYearWords = strippedWords
            self.nonYearNorm = strippedWords.joined(separator: " ")
            self.nonYearBigrams = TitleMatcher.bigrams(for: strippedWords)
        }
    }

    private static func searchScorePrecomputed(
        _ q: PrecomputedSearchQuery,
        record: LaunchBoxRecord
    ) -> (score: Double, yearMatched: Bool, nameWordCount: Int) {
        let nameNorm = normalize(record.name)
        let altNorms = record.alternateNames.map(normalize)

        var titleBest = 0.0
        if !q.queryNorm.isEmpty {
            titleBest = max(
                scoreNormalized(queryNorm: q.queryNorm, queryWords: q.queryWords, queryBigrams: q.queryBigrams, candNorm: nameNorm),
                trigramDiceNormalized(queryNorm: q.queryNorm, queryTrigrams: q.queryTrigrams, candNorm: nameNorm)
            )
            for altNorm in altNorms {
                let s = max(
                    scoreNormalized(queryNorm: q.queryNorm, queryWords: q.queryWords, queryBigrams: q.queryBigrams, candNorm: altNorm),
                    trigramDiceNormalized(queryNorm: q.queryNorm, queryTrigrams: q.queryTrigrams, candNorm: altNorm)
                )
                if s > titleBest { titleBest = s }
            }
        }

        let yearMatchesRecord = (q.effectiveYear != nil && q.effectiveYear == record.releaseYear)

        if yearMatchesRecord, !q.nonYearNorm.isEmpty, q.nonYearNorm != q.queryNorm {
            let strippedMain = scoreNormalized(
                queryNorm: q.nonYearNorm,
                queryWords: q.nonYearWords,
                queryBigrams: q.nonYearBigrams,
                candNorm: nameNorm
            )
            if strippedMain > titleBest { titleBest = strippedMain }
            for altNorm in altNorms {
                let s = scoreNormalized(
                    queryNorm: q.nonYearNorm,
                    queryWords: q.nonYearWords,
                    queryBigrams: q.nonYearBigrams,
                    candNorm: altNorm
                )
                if s > titleBest { titleBest = s }
            }
        }

        let yearOnlyBest: Double = (q.nonYearWords.isEmpty && yearMatchesRecord) ? 0.85 : 0.0

        var makerBest = 0.0
        var combinedBest = 0.0
        if !q.nonYearWords.isEmpty, q.effectiveYear == nil || yearMatchesRecord {
            let pubNorm = record.publisher.map(normalize) ?? ""
            let devNorm = record.developer.map(normalize) ?? ""
            makerBest = max(
                scoreMaker(queryNorm: q.nonYearNorm, queryWords: q.nonYearWords, makerNorm: pubNorm),
                scoreMaker(queryNorm: q.nonYearNorm, queryWords: q.nonYearWords, makerNorm: devNorm)
            )

            if q.nonYearWords.count >= 2, !pubNorm.isEmpty || !devNorm.isEmpty {
                let makerWords = Set(pubNorm.split(separator: " ").map(String.init))
                    .union(devNorm.split(separator: " ").map(String.init))
                let inMaker = q.nonYearWords.filter { wordMatchesMaker($0, in: makerWords) }
                let notInMaker = q.nonYearWords.filter { !wordMatchesMaker($0, in: makerWords) }
                if !inMaker.isEmpty, !notInMaker.isEmpty {
                    let titlePartNorm = notInMaker.joined(separator: " ")
                    let titlePartBigrams = bigrams(for: notInMaker)
                    var titlePartScore = scoreQueryWordsInTitle(
                        queryNorm: titlePartNorm,
                        queryWords: notInMaker,
                        queryBigrams: titlePartBigrams,
                        candNorm: nameNorm
                    )
                    for altNorm in altNorms {
                        let s = scoreQueryWordsInTitle(
                            queryNorm: titlePartNorm,
                            queryWords: notInMaker,
                            queryBigrams: titlePartBigrams,
                            candNorm: altNorm
                        )
                        if s > titlePartScore { titlePartScore = s }
                    }
                    if titlePartScore >= 0.5 {
                        combinedBest = min(1.0, titlePartScore + 0.10)
                    }
                }
            }
        }

        var best = max(titleBest, yearOnlyBest, makerBest, combinedBest)
        guard best > 0 else { return (0, false, 0) }
        if yearMatchesRecord {
            best = min(1.0, best + 0.05)
        }
        let nameWordCount = nameNorm.split(separator: " ").count
        return (best, yearMatchesRecord, nameWordCount)
    }

    private static func wordMatchesMaker(_ word: String, in makerWords: Set<String>) -> Bool {
        if makerWords.contains(word) { return true }
        guard word.count >= 4 else { return false }
        return makerWords.contains { $0.hasPrefix(word) }
    }

    private static func scoreMaker(queryNorm: String, queryWords: [String], makerNorm: String) -> Double {
        guard !makerNorm.isEmpty, !queryWords.isEmpty else { return 0 }
        if queryNorm == makerNorm {
            return 0.85
        }
        let makerWords = Set(makerNorm.split(separator: " ").map(String.init))
        guard queryWords.allSatisfy({ wordMatchesMaker($0, in: makerWords) }) else {
            return 0
        }
        return 0.75
    }

    private static func scoreQueryWordsInTitle(
        queryNorm: String,
        queryWords: [String],
        queryBigrams: Set<String>,
        candNorm: String
    ) -> Double {
        guard !candNorm.isEmpty, !queryWords.isEmpty else { return 0 }
        if queryNorm == candNorm {
            return 1.0
        }
        let candWords = candNorm.split(separator: " ").map(String.init)
        let candSet = Set(candWords)
        if queryWords.allSatisfy({ candSet.contains($0) }) {
            return 0.85
        }
        let candBigrams = bigrams(for: candWords)
        guard !queryBigrams.isEmpty, !candBigrams.isEmpty else { return 0 }
        let shared = queryBigrams.intersection(candBigrams).count
        return (2.0 * Double(shared)) / Double(queryBigrams.count + candBigrams.count)
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

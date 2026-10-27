import Foundation

/// Reads and writes `game.json`, preserving unknown keys at the top level and inside
/// `launch`, `settings` and `stats`.
public enum GameFileCodec {
    public static let schemaVersion = 1

    /// Nested objects whose unknown keys are carried in `extra` under the same key and merged back on encode.
    static let nestedKnownKeys: [String: Set<String>] = [
        "launch": LaunchSpec.knownKeys, "settings": GameSettings.knownKeys, "stats": PlayStats.knownKeys,
        "origin": ImportOrigin.knownKeys,
    ]

    public static func decode(_ data: Data) throws -> (game: Game, extra: [String: JSONValue]) {
        try decode(data, lenient: false)
    }

    /// Like `decode`, but an enum value this version doesn't know reads as nil (or a display default)
    /// instead of failing. Only for showing a record that must never be written back.
    public static func decodeLenient(_ data: Data) throws -> (game: Game, extra: [String: JSONValue]) {
        try decode(data, lenient: true)
    }

    /// The file's top-level JSON object.
    public static func rawObject(_ data: Data) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    /// The file's `schemaVersion`; files written before it existed count as version 1.
    public static func schemaVersion(of raw: [String: JSONValue]) -> Int {
        if case .number(let n)? = raw["schemaVersion"] { return Int(n) }
        return 1
    }

    private static func decode(_ data: Data, lenient: Bool) throws -> (game: Game, extra: [String: JSONValue]) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if lenient { decoder.userInfo[.lenientEnums] = true }
        let game = try decoder.decode(Game.self, from: data)
        let all = try rawObject(data)
        var extra = all.filter { !Game.knownKeys.contains($0.key) && $0.key != "schemaVersion" }
        for (key, known) in nestedKnownKeys {
            guard case .object(let nested)? = all[key] else { continue }
            let unknown = nested.filter { !known.contains($0.key) }
            if !unknown.isEmpty { extra[key] = .object(unknown) }
        }
        return (game, extra)
    }

    public static func encode(_ game: Game, extra: [String: JSONValue]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var all = try JSONDecoder().decode([String: JSONValue].self, from: encoder.encode(game))
        for (key, value) in extra {
            switch (all[key], value) {
            case (nil, _):
                all[key] = value
            case (.object(var ours)?, .object(let theirs)):
                // Only keys the model doesn't own are carried, so a field set back to nil stays nil.
                for (k, v) in theirs where ours[k] == nil { ours[k] = v }
                all[key] = .object(ours)
            default:
                break
            }
        }
        all["schemaVersion"] = .number(Double(schemaVersion))
        return try encoder.encode(all)
    }
}

extension CodingUserInfoKey {
    static let lenientEnums = CodingUserInfoKey(rawValue: "com.songer522.DOSCrate.lenientEnums")!
}

extension Decoder {
    var decodesEnumsLeniently: Bool { userInfo[.lenientEnums] as? Bool == true }
}

extension KeyedDecodingContainer {
    /// `decodeIfPresent`, except that when `lenient` an unknown enum value reads as nil.
    func decodeEnumIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key, lenient: Bool) throws -> T? {
        do {
            return try decodeIfPresent(type, forKey: key)
        } catch DecodingError.dataCorrupted(_) where lenient {
            return nil
        }
    }
}

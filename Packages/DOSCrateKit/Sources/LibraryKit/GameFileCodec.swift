import Foundation

/// Reads and writes `game.json`, preserving unknown top-level keys.
public enum GameFileCodec {
    public static let schemaVersion = 1

    public static func decode(_ data: Data) throws -> (game: Game, extra: [String: JSONValue]) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let game = try decoder.decode(Game.self, from: data)
        var all = try decoder.decode([String: JSONValue].self, from: data)
        for key in Game.knownKeys { all[key] = nil }
        all["schemaVersion"] = nil
        return (game, all)
    }

    public static func encode(_ game: Game, extra: [String: JSONValue]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var all = try JSONDecoder().decode([String: JSONValue].self, from: encoder.encode(game))
        for (key, value) in extra where all[key] == nil { all[key] = value }
        all["schemaVersion"] = .number(Double(schemaVersion))
        return try encoder.encode(all)
    }
}

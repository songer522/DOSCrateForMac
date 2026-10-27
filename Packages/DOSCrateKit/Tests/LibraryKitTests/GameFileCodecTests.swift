import Foundation
import Testing
@testable import LibraryKit

struct GameFileCodecTests {
    @Test func roundTripPreservesAllFields() throws {
        var game = Game(title: "Commander Keen", source: .referenced(path: "/tmp/keen", bookmark: Data([1, 2, 3])))
        game.year = 1990
        game.developer = "id Software"
        game.publisher = "Apogee"
        game.genre = "Platformer"
        game.notes = "Goodbye, Galaxy!"
        game.tags = ["classic", "shareware"]
        game.isFavorite = true
        game.media = [MediaImage(relativePath: "media/disc.iso", kind: .cdrom)]
        game.launch = LaunchSpec(executable: "KEEN1.EXE", arguments: "/x", preCommands: ["a"], postCommands: ["b"],
                                 exitWhenDone: false, driveCRoot: "GAME")
        game.settings = GameSettings(
            preset: .pc486, cycles: .fixed(25000), core: .dynamic, memoryMB: 16, machine: .svga_s3,
            shader: "crt-auto", aspect: .squarePixels, fullscreen: true, soundCard: .sb16,
            midi: .mt32, mouseCapture: .seamless, keyboardLayout: "us")
        game.stats = PlayStats(totalPlaySeconds: 123.5, lastPlayed: Date(timeIntervalSince1970: 1_700_000_000), launchCount: 4)

        let data = try GameFileCodec.encode(game, extra: [:])
        let decoded = try GameFileCodec.decode(data)
        #expect(decoded.game == game)
        #expect(decoded.extra.isEmpty)
    }

    @Test func originRoundTripsAndOldJSONWithoutOriginDecodesNil() throws {
        var game = Game(title: "Keen", source: .managed)
        game.origin = ImportOrigin(
            path: "/Volumes/DOS/keen.zip",
            fileSize: 123_456,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoded = try GameFileCodec.encode(game, extra: [:])
        let decoded = try GameFileCodec.decode(encoded)
        #expect(decoded.game.origin == game.origin)
        #expect(decoded.extra.isEmpty)

        let legacyJSON = """
        {"id":"\(UUID())","title":"Legacy","source":{"type":"managed"}}
        """
        let legacy = try GameFileCodec.decode(Data(legacyJSON.utf8))
        #expect(legacy.game.origin == nil)

        let withFutureOriginKey = """
        {"schemaVersion":1,"id":"\(UUID())","title":"FutureOrigin","source":{"type":"managed"},
         "origin":{"path":"/tmp/keen","futureOriginFlag":true}}
        """
        let futureDecoded = try GameFileCodec.decode(Data(withFutureOriginKey.utf8))
        #expect(futureDecoded.game.origin == ImportOrigin(path: "/tmp/keen"))
        let reencoded = try GameFileCodec.encode(futureDecoded.game, extra: futureDecoded.extra)
        let raw = try GameFileCodec.rawObject(reencoded)
        guard case .object(let originObj) = raw["origin"] else {
            Issue.record("expected origin object")
            return
        }
        #expect(originObj["futureOriginFlag"] == .bool(true))
    }

    @Test func unknownTopLevelKeysPreserved() throws {
        let json = """
        {"schemaVersion":1,"id":"\(UUID())","title":"X","source":{"type":"managed"},"futureField":{"a":1}}
        """
        let decoded = try GameFileCodec.decode(Data(json.utf8))
        #expect(decoded.extra["futureField"] == .object(["a": .number(1)]))
        let out = try GameFileCodec.encode(decoded.game, extra: decoded.extra)
        let back = try GameFileCodec.decode(out)
        #expect(back.extra["futureField"] == .object(["a": .number(1)]))
        #expect(String(decoding: out, as: UTF8.self).contains("\"schemaVersion\" : 1"))
    }

    @Test func cyclesCodableForms() throws {
        let enc = JSONEncoder()
        #expect(String(decoding: try enc.encode(Cycles.fixed(25000)), as: UTF8.self) == "25000")
        #expect(try JSONDecoder().decode(Cycles.self, from: Data("\"max\"".utf8)) == .max)
        #expect(try JSONDecoder().decode(Cycles.self, from: Data("\"auto\"".utf8)) == .auto)
    }

    @Test func missingOptionalFieldsUseDefaults() throws {
        let json = """
        {"id":"\(UUID())","title":"X","source":{"type":"managed"}}
        """
        let game = try GameFileCodec.decode(Data(json.utf8)).game
        #expect(game.launch.exitWhenDone == true)
        #expect(game.tags == [])
    }

    @Test func nestedUnknownKeysSurviveRewrite() throws {
        let json = """
        {"schemaVersion":1,"id":"\(UUID())","title":"X","source":{"type":"managed"},
         "launch":{"executable":"A.EXE","futureLaunch":"x"},
         "settings":{"memoryMB":16,"futureKnob":3},"stats":{"launchCount":2,"futureStat":[1]}}
        """
        var decoded = try GameFileCodec.decode(Data(json.utf8))
        decoded.game.settings.memoryMB = nil
        decoded.game.settings.preset = .pc486
        let out = try GameFileCodec.encode(decoded.game, extra: decoded.extra)
        let raw = try JSONDecoder().decode([String: JSONValue].self, from: out)
        guard case .object(let settings) = raw["settings"], case .object(let launch) = raw["launch"],
              case .object(let stats) = raw["stats"] else { Issue.record("missing nested objects"); return }
        #expect(settings["futureKnob"] == .number(3))
        #expect(settings["memoryMB"] == nil)
        #expect(settings["preset"] == .string("pc486"))
        #expect(launch["futureLaunch"] == .string("x"))
        #expect(launch["executable"] == .string("A.EXE"))
        #expect(stats["futureStat"] == .array([.number(1)]))
        #expect(try GameFileCodec.decode(out).game == decoded.game)
    }

    @Test func lenientDecodeOnlyRelaxesEnumValues() throws {
        let json = """
        {"id":"\(UUID())","title":"X","source":{"type":"managed"},"settings":{"preset":"pentium4","core":"jit"}}
        """
        #expect(throws: DecodingError.self) { try GameFileCodec.decode(Data(json.utf8)) }
        let game = try GameFileCodec.decodeLenient(Data(json.utf8)).game
        #expect(game.settings.preset == nil && game.settings.core == nil)
        let wrongType = """
        {"id":"\(UUID())","title":7,"source":{"type":"managed"}}
        """
        #expect(throws: DecodingError.self) { try GameFileCodec.decodeLenient(Data(wrongType.utf8)) }
    }
}

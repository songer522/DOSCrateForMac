import Foundation

public enum Preset: String, Sendable, Equatable, Codable, CaseIterable {
    case auto, early80s, pc286, pc386, pc486, pentium
    public var displayName: String {
        switch self {
        case .auto: "Auto"
        case .early80s: "Early 80s"
        case .pc286: "286"
        case .pc386: "386"
        case .pc486: "486"
        case .pentium: "Pentium"
        }
    }
}

public enum Cycles: Sendable, Equatable, Codable {
    case auto
    case max
    case fixed(Int)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) { self = .fixed(n); return }
        switch try c.decode(String.self) {
        case "auto": self = .auto
        case "max": self = .max
        case let other:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown cycles value \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .auto: try c.encode("auto")
        case .max: try c.encode("max")
        case .fixed(let n): try c.encode(n)
        }
    }

    public var displayName: String {
        switch self {
        case .auto: "Auto"
        case .max: "Max"
        case .fixed(let n): "\(n) cycles"
        }
    }
}

public enum CPUCore: String, Sendable, Equatable, Codable, CaseIterable {
    case auto, normal, simple, dynamic
    public var displayName: String {
        switch self {
        case .auto: "Auto"
        case .normal: "Normal"
        case .simple: "Simple"
        case .dynamic: "Dynamic"
        }
    }
}

public enum Machine: String, Sendable, Equatable, Codable, CaseIterable {
    case hercules, cga, tandy, pcjr, ega
    case svga_s3, svga_et4000, svga_paradise
    public var displayName: String {
        switch self {
        case .hercules: "Hercules"
        case .cga: "CGA"
        case .tandy: "Tandy"
        case .pcjr: "PCjr"
        case .ega: "EGA"
        case .svga_s3: "SVGA (S3)"
        case .svga_et4000: "SVGA (ET4000)"
        case .svga_paradise: "SVGA (Paradise)"
        }
    }
}

public enum Aspect: String, Sendable, Equatable, Codable, CaseIterable {
    case auto
    case squarePixels = "square-pixels"
    case stretch
    public var displayName: String {
        switch self {
        case .auto: "Auto"
        case .squarePixels: "Square pixels"
        case .stretch: "Stretch"
        }
    }
}

public enum SoundCard: String, Sendable, Equatable, Codable, CaseIterable {
    case sb16, sbPro, adlib, gus, none
    public var displayName: String {
        switch self {
        case .sb16: "Sound Blaster 16"
        case .sbPro: "Sound Blaster Pro"
        case .adlib: "AdLib"
        case .gus: "Gravis UltraSound"
        case .none: "None"
        }
    }
}

public enum MIDIMode: String, Sendable, Equatable, Codable, CaseIterable {
    case none, generalMIDI, mt32
    public var displayName: String {
        switch self {
        case .none: "None"
        case .generalMIDI: "General MIDI"
        case .mt32: "Roland MT-32"
        }
    }
}

public enum MouseCapture: String, Sendable, Equatable, Codable, CaseIterable {
    case onclick, onstart, seamless, nomouse
    public var displayName: String {
        switch self {
        case .onclick: "On click"
        case .onstart: "On start"
        case .seamless: "Seamless"
        case .nomouse: "No mouse"
        }
    }
}

/// Per-game overrides. Every field is optional; nil means "inherit the default".
public struct GameSettings: Sendable, Equatable, Codable {
    public var preset: Preset?
    public var cycles: Cycles?
    public var core: CPUCore?
    public var memoryMB: Int?
    public var machine: Machine?
    public var shader: String?
    public var aspect: Aspect?
    public var fullscreen: Bool?
    public var soundCard: SoundCard?
    public var midi: MIDIMode?
    public var mouseCapture: MouseCapture?
    public var keyboardLayout: String?

    public init(
        preset: Preset? = nil, cycles: Cycles? = nil, core: CPUCore? = nil,
        memoryMB: Int? = nil, machine: Machine? = nil, shader: String? = nil,
        aspect: Aspect? = nil, fullscreen: Bool? = nil, soundCard: SoundCard? = nil,
        midi: MIDIMode? = nil, mouseCapture: MouseCapture? = nil, keyboardLayout: String? = nil
    ) {
        self.preset = preset; self.cycles = cycles; self.core = core
        self.memoryMB = memoryMB; self.machine = machine; self.shader = shader
        self.aspect = aspect; self.fullscreen = fullscreen; self.soundCard = soundCard
        self.midi = midi; self.mouseCapture = mouseCapture; self.keyboardLayout = keyboardLayout
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case preset, cycles, core, memoryMB, machine, shader, aspect, fullscreen, soundCard, midi, mouseCapture, keyboardLayout
    }

    static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lenient = decoder.decodesEnumsLeniently
        preset = try c.decodeEnumIfPresent(Preset.self, forKey: .preset, lenient: lenient)
        cycles = try c.decodeEnumIfPresent(Cycles.self, forKey: .cycles, lenient: lenient)
        core = try c.decodeEnumIfPresent(CPUCore.self, forKey: .core, lenient: lenient)
        memoryMB = try c.decodeIfPresent(Int.self, forKey: .memoryMB)
        machine = try c.decodeEnumIfPresent(Machine.self, forKey: .machine, lenient: lenient)
        shader = try c.decodeIfPresent(String.self, forKey: .shader)
        aspect = try c.decodeEnumIfPresent(Aspect.self, forKey: .aspect, lenient: lenient)
        fullscreen = try c.decodeIfPresent(Bool.self, forKey: .fullscreen)
        soundCard = try c.decodeEnumIfPresent(SoundCard.self, forKey: .soundCard, lenient: lenient)
        midi = try c.decodeEnumIfPresent(MIDIMode.self, forKey: .midi, lenient: lenient)
        mouseCapture = try c.decodeEnumIfPresent(MouseCapture.self, forKey: .mouseCapture, lenient: lenient)
        keyboardLayout = try c.decodeIfPresent(String.self, forKey: .keyboardLayout)
    }
}

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

public enum ControllerMode: String, Sendable, Equatable, Codable, CaseIterable {
    case keyboard
    case auto
    case twoAxis = "2axis"
    case fourAxis = "4axis"
    case fcs
    case ch
    case disabled

    public var displayName: String {
        switch self {
        case .keyboard: "Keyboard mapping"
        case .auto: "PC Joystick (Auto)"
        case .twoAxis: "PC Joystick (2-Axis)"
        case .fourAxis: "PC Joystick (4-Axis)"
        case .fcs: "Thrustmaster FCS"
        case .ch: "CH Flightstick"
        case .disabled: "Off"
        }
    }

    public var joystickType: String {
        switch self {
        case .keyboard: "hidden"
        case .auto: "auto"
        case .twoAxis: "2axis"
        case .fourAxis: "4axis"
        case .fcs: "fcs"
        case .ch: "ch"
        case .disabled: "disabled"
        }
    }

    public var isJoystickEmulation: Bool {
        switch self {
        case .auto, .twoAxis, .fourAxis, .fcs, .ch: true
        case .keyboard, .disabled: false
        }
    }
}

public enum ControllerButton: String, Sendable, Equatable, Codable, CaseIterable, Hashable {
    case a
    case b
    case x
    case y
    case leftTrigger
    case rightTrigger
    case start

    public var displayName: String {
        switch self {
        case .a: "A / Cross"
        case .b: "B / Circle"
        case .x: "X / Square"
        case .y: "Y / Triangle"
        case .leftTrigger: "Left Trigger (L2 / LT)"
        case .rightTrigger: "Right Trigger (R2 / RT)"
        case .start: "Start / Options"
        }
    }

    public var defaultKeyboardKey: ControllerKey? {
        switch self {
        case .a: .leftCtrl
        case .b: .leftAlt
        case .x: .space
        case .y: .enter
        case .leftTrigger: nil
        case .rightTrigger: nil
        case .start: .escape
        }
    }

    public func defaultLabel(for mode: ControllerMode?) -> String {
        if let mode, mode.isJoystickEmulation {
            return switch self {
            case .a: "Default (Joystick Button 1)"
            case .b: "Default (Joystick Button 2)"
            case .x: "Default (Joystick Button 3)"
            case .y: "Default (Joystick Button 4)"
            case .leftTrigger: "Default (Joystick Button 5)"
            case .rightTrigger: "Default (Joystick Button 6)"
            case .start: "Default (Esc)"
            }
        }
        if let key = defaultKeyboardKey {
            return "Default (\(key.displayName))"
        }
        return "Default (Unbound)"
    }
}

public enum ControllerKey: String, Sendable, Equatable, Codable, CaseIterable, Hashable {
    case unbound = "none"
    case leftCtrl, leftAlt, leftShift
    case rightCtrl, rightAlt, rightShift
    case space, enter, escape, tab, backspace
    case up, down, left, right
    case insert, delete, home, end, pageUp, pageDown
    case a, b, c, d, e, f, g, h, i, j, k, l, m
    case n, o, p, q, r, s, t, u, v, w, x, y, z
    case num1 = "1", num2 = "2", num3 = "3", num4 = "4", num5 = "5"
    case num6 = "6", num7 = "7", num8 = "8", num9 = "9", num0 = "0"
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    case minus, equals, leftBracket, rightBracket, comma, period, slash

    public var displayName: String {
        switch self {
        case .unbound: "Unbound"
        case .leftCtrl: "Left Ctrl"
        case .leftAlt: "Left Alt"
        case .leftShift: "Left Shift"
        case .rightCtrl: "Right Ctrl"
        case .rightAlt: "Right Alt"
        case .rightShift: "Right Shift"
        case .space: "Space"
        case .enter: "Enter"
        case .escape: "Esc"
        case .tab: "Tab"
        case .backspace: "Backspace"
        case .up: "Up Arrow"
        case .down: "Down Arrow"
        case .left: "Left Arrow"
        case .right: "Right Arrow"
        case .insert: "Insert"
        case .delete: "Delete"
        case .home: "Home"
        case .end: "End"
        case .pageUp: "Page Up"
        case .pageDown: "Page Down"
        case .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m,
             .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z:
            rawValue.uppercased()
        case .num1, .num2, .num3, .num4, .num5, .num6, .num7, .num8, .num9, .num0:
            rawValue
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
            rawValue.uppercased()
        case .minus: "-"
        case .equals: "="
        case .leftBracket: "["
        case .rightBracket: "]"
        case .comma: ","
        case .period: "."
        case .slash: "/"
        }
    }

    /// The DOSBox Staging mapper event name (`key_<name>`), or `nil` when unbound (`.unbound`).
    public var mapperEvent: String? {
        switch self {
        case .unbound: nil
        case .leftCtrl: "key_lctrl"
        case .leftAlt: "key_lalt"
        case .leftShift: "key_lshift"
        case .rightCtrl: "key_rctrl"
        case .rightAlt: "key_ralt"
        case .rightShift: "key_rshift"
        case .space: "key_space"
        case .enter: "key_enter"
        case .escape: "key_esc"
        case .tab: "key_tab"
        case .backspace: "key_bspace"
        case .up: "key_up"
        case .down: "key_down"
        case .left: "key_left"
        case .right: "key_right"
        case .insert: "key_insert"
        case .delete: "key_delete"
        case .home: "key_home"
        case .end: "key_end"
        case .pageUp: "key_pageup"
        case .pageDown: "key_pagedown"
        case .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m,
             .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z,
             .num1, .num2, .num3, .num4, .num5, .num6, .num7, .num8, .num9, .num0,
             .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12,
             .minus, .equals, .comma, .period, .slash:
            "key_\(rawValue)"
        case .leftBracket: "key_lbracket"
        case .rightBracket: "key_rbracket"
        }
    }
}

public struct ControllerBindings: Sendable, Equatable, Codable {
    public var a: ControllerKey?
    public var b: ControllerKey?
    public var x: ControllerKey?
    public var y: ControllerKey?
    public var leftTrigger: ControllerKey?
    public var rightTrigger: ControllerKey?
    public var start: ControllerKey?

    public init(
        a: ControllerKey? = nil,
        b: ControllerKey? = nil,
        x: ControllerKey? = nil,
        y: ControllerKey? = nil,
        leftTrigger: ControllerKey? = nil,
        rightTrigger: ControllerKey? = nil,
        start: ControllerKey? = nil
    ) {
        self.a = a
        self.b = b
        self.x = x
        self.y = y
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
        self.start = start
    }

    public subscript(button: ControllerButton) -> ControllerKey? {
        get {
            switch button {
            case .a: a
            case .b: b
            case .x: x
            case .y: y
            case .leftTrigger: leftTrigger
            case .rightTrigger: rightTrigger
            case .start: start
            }
        }
        set {
            switch button {
            case .a: a = newValue
            case .b: b = newValue
            case .x: x = newValue
            case .y: y = newValue
            case .leftTrigger: leftTrigger = newValue
            case .rightTrigger: rightTrigger = newValue
            case .start: start = newValue
            }
        }
    }

    public var isEmpty: Bool {
        ControllerButton.allCases.allSatisfy { self[$0] == nil }
    }

    public var nonEmpty: ControllerBindings? {
        isEmpty ? nil : self
    }

    public static func merged(base: ControllerBindings?, override: ControllerBindings?) -> ControllerBindings {
        var result = base ?? ControllerBindings()
        guard let override else { return result }
        for button in ControllerButton.allCases {
            if let key = override[button] {
                result[button] = key
            }
        }
        return result
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case a, b, x, y, leftTrigger, rightTrigger, start
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lenient = decoder.decodesEnumsLeniently
        a = try c.decodeEnumIfPresent(ControllerKey.self, forKey: .a, lenient: lenient)
        b = try c.decodeEnumIfPresent(ControllerKey.self, forKey: .b, lenient: lenient)
        x = try c.decodeEnumIfPresent(ControllerKey.self, forKey: .x, lenient: lenient)
        y = try c.decodeEnumIfPresent(ControllerKey.self, forKey: .y, lenient: lenient)
        leftTrigger = try c.decodeEnumIfPresent(ControllerKey.self, forKey: .leftTrigger, lenient: lenient)
        rightTrigger = try c.decodeEnumIfPresent(ControllerKey.self, forKey: .rightTrigger, lenient: lenient)
        start = try c.decodeEnumIfPresent(ControllerKey.self, forKey: .start, lenient: lenient)
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
    public var controllerMode: ControllerMode?
    public var controllerBindings: ControllerBindings?

    public init(
        preset: Preset? = nil, cycles: Cycles? = nil, core: CPUCore? = nil,
        memoryMB: Int? = nil, machine: Machine? = nil, shader: String? = nil,
        aspect: Aspect? = nil, fullscreen: Bool? = nil, soundCard: SoundCard? = nil,
        midi: MIDIMode? = nil, mouseCapture: MouseCapture? = nil, keyboardLayout: String? = nil,
        controllerMode: ControllerMode? = nil, controllerBindings: ControllerBindings? = nil
    ) {
        self.preset = preset; self.cycles = cycles; self.core = core
        self.memoryMB = memoryMB; self.machine = machine; self.shader = shader
        self.aspect = aspect; self.fullscreen = fullscreen; self.soundCard = soundCard
        self.midi = midi; self.mouseCapture = mouseCapture; self.keyboardLayout = keyboardLayout
        self.controllerMode = controllerMode; self.controllerBindings = controllerBindings?.nonEmpty
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case preset, cycles, core, memoryMB, machine, shader, aspect, fullscreen, soundCard, midi, mouseCapture, keyboardLayout
        case controllerMode, controllerBindings
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
        controllerMode = try c.decodeEnumIfPresent(ControllerMode.self, forKey: .controllerMode, lenient: lenient)
        controllerBindings = try c.decodeIfPresent(ControllerBindings.self, forKey: .controllerBindings)?.nonEmpty
    }
}

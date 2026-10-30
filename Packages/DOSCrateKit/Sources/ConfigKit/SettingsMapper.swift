import LibraryKit

public enum SettingsMapper {
    public static func document(_ s: GameSettings, env: ConfigEnvironment) -> ConfigDocument {
        var d = ConfigDocument()
        if let cycles = s.cycles {
            let (real, protected): (String, String)
            switch cycles {
            case .fixed(let n): (real, protected) = ("\(n)", "\(n)")
            case .max: (real, protected) = ("max", "max")
            case .auto: (real, protected) = ("3000", "60000")
            }
            d.set("cpu", "cpu_cycles", real)
            d.set("cpu", "cpu_cycles_protected", protected)
        }
        if let v = s.core { d.set("cpu", "core", v.rawValue) }
        if let v = s.memoryMB { d.set("dosbox", "memsize", String(v)) }
        if let v = s.machine { d.set("dosbox", "machine", v.rawValue) }
        if let v = s.shader { d.set("render", "shader", v) }
        if let v = s.aspect { d.set("render", "aspect", v.rawValue) }
        if let v = s.fullscreen { d.set("sdl", "fullscreen", v ? "true" : "false") }
        // Each card sets every audio key it implies, so a preset or global config can't leave FM or GUS off/on.
        if let card = s.soundCard {
            switch card {
            case .sb16, .sbPro:
                d.set("sblaster", "sbtype", card == .sb16 ? "sb16" : "sbpro2")
                d.set("sblaster", "oplmode", "auto")
                d.set("gus", "gus", "false")
            case .adlib:
                d.set("sblaster", "sbtype", "none")
                d.set("sblaster", "oplmode", "opl2")
                d.set("gus", "gus", "false")
            case .gus: d.set("gus", "gus", "true")
            case .none:
                d.set("sblaster", "sbtype", "none")
                d.set("sblaster", "oplmode", "none")
                d.set("gus", "gus", "false")
            }
        }
        if let midi = s.midi {
            switch midi {
            case .none: d.set("midi", "mididevice", "none")
            case .generalMIDI:
                d.set("midi", "mididevice", "fluidsynth")
                if let p = env.soundfontPath { d.set("fluidsynth", "soundfont", p) }
            case .mt32:
                d.set("midi", "mididevice", "mt32")
                if let p = env.mt32RomDir { d.set("mt32", "romdir", p) }
            }
        }
        if let v = s.mouseCapture { d.set("mouse", "mouse_capture", v.rawValue) }
        if let v = s.keyboardLayout { d.set("dos", "keyboard_layout", v) }
        if let v = s.controllerMode { d.set("joystick", "joysticktype", v.joystickType) }
        return d
    }
}

import Testing
import LibraryKit
@testable import ConfigKit

private func row(_ p: Preset) -> [String?] {
    let d = Presets.document(p)
    return [d.value("dosbox", "machine"), d.value("dosbox", "memsize"),
            d.value("cpu", "cpu_cycles"), d.value("cpu", "cpu_cycles_protected"),
            d.value("cpu", "core"), d.value("sblaster", "sbtype"), d.value("sblaster", "oplmode")]
}

@Test func presetTableValues() {
    #expect(row(.early80s) == ["cga", "1", "300", "300", "normal", "none", "none"])
    #expect(row(.pc286) == ["ega", "1", "1500", "1500", "normal", "sb1", "auto"])
    #expect(row(.pc386) == ["svga_et4000", "4", "6000", "6000", "auto", "sbpro2", "auto"])
    #expect(row(.pc486) == ["svga_s3", "16", "25000", "25000", "auto", "sb16", "auto"])
    #expect(row(.pentium) == ["svga_s3", "32", "50000", "50000", "dynamic", "sb16", "auto"])
    #expect(Presets.document(.auto) == ConfigDocument())
}

private let env = ConfigEnvironment(soundfontPath: nil, mt32RomDir: nil)

@Test func fixedCyclesSetsBothKeys() {
    let d = SettingsMapper.document(GameSettings(cycles: .fixed(4000)), env: env)
    #expect(d.value("cpu", "cpu_cycles") == "4000")
    #expect(d.value("cpu", "cpu_cycles_protected") == "4000")
}

@Test func maxAndAutoCycles() {
    let m = SettingsMapper.document(GameSettings(cycles: .max), env: env)
    #expect(m.value("cpu", "cpu_cycles") == "max")
    #expect(m.value("cpu", "cpu_cycles_protected") == "max")
    let a = SettingsMapper.document(GameSettings(cycles: .auto), env: env)
    #expect(a.value("cpu", "cpu_cycles") == "3000")
    #expect(a.value("cpu", "cpu_cycles_protected") == "60000")
}

@Test func adlibMapping() {
    let d = SettingsMapper.document(GameSettings(soundCard: .adlib), env: env)
    #expect(d.value("sblaster", "sbtype") == "none")
    #expect(d.value("sblaster", "oplmode") == "opl2")
}

@Test func soundCardMappings() {
    func doc(_ c: SoundCard) -> ConfigDocument { SettingsMapper.document(GameSettings(soundCard: c), env: env) }
    #expect(doc(.sb16).value("sblaster", "sbtype") == "sb16")
    #expect(doc(.sbPro).value("sblaster", "sbtype") == "sbpro2")
    #expect(doc(.gus).value("gus", "gus") == "true")
    let none = doc(.none)
    #expect(none.value("sblaster", "sbtype") == "none")
    #expect(none.value("sblaster", "oplmode") == "none")
    #expect(none.value("gus", "gus") == "false")
}

@Test func soundBlasterOverridesInheritedAudio() {
    var preset = Presets.document(.early80s)
    for card in [SoundCard.sb16, .sbPro] {
        preset.merge(SettingsMapper.document(GameSettings(soundCard: card), env: env))
        #expect(preset.value("sblaster", "oplmode") == "auto")
        #expect(preset.value("gus", "gus") == "false")
    }
    let adlib = SettingsMapper.document(GameSettings(soundCard: .adlib), env: env)
    #expect(adlib.value("gus", "gus") == "false")
}

@Test func generalMIDIUsesSoundfontWhenSet() {
    let e = ConfigEnvironment(soundfontPath: "/sf/gm.sf2", mt32RomDir: "/roms")
    let gm = SettingsMapper.document(GameSettings(midi: .generalMIDI), env: e)
    #expect(gm.value("midi", "mididevice") == "fluidsynth")
    #expect(gm.value("fluidsynth", "soundfont") == "/sf/gm.sf2")
    let bare = SettingsMapper.document(GameSettings(midi: .generalMIDI), env: env)
    #expect(bare.value("fluidsynth", "soundfont") == nil)
    let mt = SettingsMapper.document(GameSettings(midi: .mt32), env: e)
    #expect(mt.value("midi", "mididevice") == "mt32")
    #expect(mt.value("mt32", "romdir") == "/roms")
    #expect(SettingsMapper.document(GameSettings(midi: MIDIMode.none), env: e).value("midi", "mididevice") == "none")
}

@Test func miscMappings() {
    let s = GameSettings(core: .dynamic, memoryMB: 8, machine: .ega, shader: "crt-auto",
                         aspect: .squarePixels, fullscreen: false, mouseCapture: .seamless,
                         keyboardLayout: "uk")
    let d = SettingsMapper.document(s, env: env)
    #expect(d.value("cpu", "core") == "dynamic")
    #expect(d.value("dosbox", "memsize") == "8")
    #expect(d.value("dosbox", "machine") == "ega")
    #expect(d.value("render", "shader") == "crt-auto")
    #expect(d.value("render", "aspect") == "square-pixels")
    #expect(d.value("sdl", "fullscreen") == "false")
    #expect(d.value("mouse", "mouse_capture") == "seamless")
    #expect(d.value("dos", "keyboard_layout") == "uk")
}

@Test func nilSettingsProduceEmptyDocument() {
    #expect(SettingsMapper.document(GameSettings(), env: env) == ConfigDocument())
}

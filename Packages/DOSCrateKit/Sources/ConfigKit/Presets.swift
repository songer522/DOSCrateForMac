import LibraryKit

public enum Presets {
    public static func document(_ preset: Preset) -> ConfigDocument {
        var d = ConfigDocument()
        let row: (machine: String, mem: String, cycles: String, core: String, sb: String, opl: String)
        switch preset {
        case .auto: return d
        case .early80s: row = ("cga", "1", "300", "normal", "none", "none")
        case .pc286: row = ("ega", "1", "1500", "normal", "sb1", "auto")
        case .pc386: row = ("svga_et4000", "4", "6000", "auto", "sbpro2", "auto")
        case .pc486: row = ("svga_s3", "16", "25000", "auto", "sb16", "auto")
        case .pentium: row = ("svga_s3", "32", "50000", "dynamic", "sb16", "auto")
        }
        d.set("dosbox", "machine", row.machine)
        d.set("dosbox", "memsize", row.mem)
        d.set("cpu", "cpu_cycles", row.cycles)
        d.set("cpu", "cpu_cycles_protected", row.cycles)
        d.set("cpu", "core", row.core)
        d.set("sblaster", "sbtype", row.sb)
        d.set("sblaster", "oplmode", row.opl)
        return d
    }
}

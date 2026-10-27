import Testing
@testable import ConfigKit

@Test func renderPutsAutoexecLast() {
    var d = ConfigDocument()
    d.autoexec = ["c:", "game.exe"]
    d.set("cpu", "core", "auto")
    d.set("dosbox", "memsize", "16")
    #expect(d.render() == "[cpu]\ncore = auto\n\n[dosbox]\nmemsize = 16\n\n[autoexec]\nc:\ngame.exe\n")
}

@Test func renderOmitsEmptyAutoexec() {
    var d = ConfigDocument()
    d.set("cpu", "core", "auto")
    #expect(!d.render().contains("[autoexec]"))
}

@Test func mergeHigherWinsAndAppendsAutoexec() {
    var low = ConfigDocument()
    low.set("cpu", "core", "normal")
    low.set("cpu", "cpu_cycles", "300")
    low.autoexec = ["a"]
    var high = ConfigDocument()
    high.set("cpu", "core", "dynamic")
    high.set("sdl", "fullscreen", "true")
    high.autoexec = ["b"]
    low.merge(high)
    #expect(low.value("cpu", "core") == "dynamic")
    #expect(low.value("cpu", "cpu_cycles") == "300")
    #expect(low.value("sdl", "fullscreen") == "true")
    #expect(low.autoexec == ["a", "b"])
}

@Test func parseIgnoresCommentsAndKeepsAutoexecVerbatim() {
    let text = "# x\n; y\n[CPU]\ncpu_cycles=500\n\n[autoexec]\necho  hi\n"
    let d = ConfigDocument.parse(text)
    #expect(d.value("cpu", "cpu_cycles") == "500")
    #expect(d.autoexec == ["echo  hi"])
}

@Test func parseTrimsKeysAndValues() {
    let d = ConfigDocument.parse("[sdl]\n  fullscreen  =  true  \r\n")
    #expect(d.value("sdl", "fullscreen") == "true")
}

@Test func parseRenderRoundTrip() {
    var d = ConfigDocument()
    d.set("cpu", "core", "auto")
    d.set("midi", "mididevice", "none")
    d.autoexec = ["mount c \"/x\"", "c:"]
    #expect(ConfigDocument.parse(d.render()) == d)
}

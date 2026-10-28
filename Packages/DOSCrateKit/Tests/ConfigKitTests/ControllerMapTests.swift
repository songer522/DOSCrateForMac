import Testing
@testable import ConfigKit

@Suite struct ControllerMapTests {
    @Test func standardBindings() {
        let l = ControllerLayout.standard
        #expect(l.binding(.a) == "stick_0 button 0"); #expect(l.binding(.start) == "stick_0 button 6")
        #expect(l.binding(.dpadDown) == "stick_0 button 12"); #expect(l.binding(.stickUp) == "stick_0 axis 1 0")
    }
    @Test func steamBindings() {
        let l = ControllerLayout.steam
        #expect(l.binding(.a) == "stick_0 button 4"); #expect(l.binding(.x) == "stick_0 button 9")
        #expect(l.binding(.y) == "stick_0 button 10"); #expect(l.binding(.start) == "stick_0 button 7")
        #expect(l.binding(.dpadUp) == "stick_0 button 14"); #expect(l.binding(.dpadDown) == "stick_0 button 11")
    }
    @Test func xboxUSBBindings() {
        let l = ControllerLayout.xboxUSB
        #expect(l.binding(.x) == "stick_0 button 6"); #expect(l.binding(.start) == "stick_0 button 3")
        #expect(l.binding(.dpadDown) == "stick_0 button 8")
        #expect(l.binding(.stickUp) == "stick_0 axis 1 1"); #expect(l.binding(.stickDown) == "stick_0 axis 1 0")
    }
    @Test func renderAppendsToKeyLines() {
        let lines = ControllerMap.render(.standard).split(separator: "\n").map(String.init)
        let up = lines.first { $0.hasPrefix("key_up ") }!
        #expect(up.contains("\"key 82\"") && up.contains("\"stick_0 button 11\"") && up.contains("\"stick_0 axis 1 0\""))
        #expect(lines.first { $0.hasPrefix("key_lctrl ") }!.contains("\"stick_0 button 0\""))
        #expect(lines.first { $0.hasPrefix("key_lalt ") }!.contains("\"stick_0 button 1\""))
        #expect(lines.first { $0.hasPrefix("key_esc ") }!.contains("\"stick_0 button 6\""))
    }
    @Test(arguments: ControllerLayout.allCases) func untouchedLinesUnchanged(_ l: ControllerLayout) {
        let touched: Set = ["key_up", "key_down", "key_left", "key_right", "key_lctrl", "key_lalt", "key_space", "key_enter", "key_esc"]
        let tpl = ControllerTemplate.text.split(separator: "\n", omittingEmptySubsequences: false)
        let out = ControllerMap.render(l).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(tpl.count == out.count)
        for (t, o) in zip(tpl, out) where !touched.contains(String(t.split(separator: " ").first ?? "")) { #expect(t == o) }
    }
}

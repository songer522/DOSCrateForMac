import LibraryKit
import Testing
@testable import ConfigKit

@Suite struct ControllerMapTests {
    @Test func standardBindings() {
        let l = ControllerLayout.standard
        #expect(l.binding(.a) == "stick_0 button 0"); #expect(l.binding(.start) == "stick_0 button 6")
        #expect(l.binding(.leftTrigger) == "stick_0 axis 4 1"); #expect(l.binding(.rightTrigger) == "stick_0 axis 5 1")
        #expect(l.binding(.dpadDown) == "stick_0 button 12"); #expect(l.binding(.stickUp) == "stick_0 axis 1 0")
    }
    @Test func steamBindings() {
        let l = ControllerLayout.steam
        #expect(l.binding(.a) == "stick_0 button 4"); #expect(l.binding(.x) == "stick_0 button 9")
        #expect(l.binding(.y) == "stick_0 button 10"); #expect(l.binding(.start) == "stick_0 button 7")
        #expect(l.binding(.leftTrigger) == "stick_0 button 17"); #expect(l.binding(.rightTrigger) == "stick_0 button 24")
        #expect(l.binding(.dpadUp) == "stick_0 button 14"); #expect(l.binding(.dpadDown) == "stick_0 button 11")
        #expect(l.binding(.stickUp) == "stick_0 axis 1 1"); #expect(l.binding(.stickDown) == "stick_0 axis 1 0")
    }
    @Test func xboxUSBBindings() {
        let l = ControllerLayout.xboxUSB
        #expect(l.binding(.x) == "stick_0 button 6"); #expect(l.binding(.start) == "stick_0 button 3")
        #expect(l.binding(.leftTrigger) == "stick_0 button 14"); #expect(l.binding(.rightTrigger) == "stick_0 button 17")
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
    @Test func customKeyboardBindingsAndTriggers() {
        let bindings = ControllerBindings(
            a: .space,
            b: .unbound,
            leftTrigger: .z,
            rightTrigger: .x
        )
        let lines = ControllerMap.render(.standard, mode: .keyboard, bindings: bindings)
            .split(separator: "\n")
            .map(String.init)
        let spaceLine = lines.first { $0.hasPrefix("key_space ") }!
        // Both A (custom) and X (default) map to Space
        #expect(spaceLine.contains("\"stick_0 button 0\"") && spaceLine.contains("\"stick_0 button 2\""))
        // B is explicitly unbound (.none)
        let altLine = lines.first { $0.hasPrefix("key_lalt ") }!
        #expect(!altLine.contains("stick_0"))
        // Triggers mapped to Z and X
        #expect(lines.first { $0.hasPrefix("key_z ") }!.contains("\"stick_0 axis 4 1\""))
        #expect(lines.first { $0.hasPrefix("key_x ") }!.contains("\"stick_0 axis 5 1\""))
    }
    @Test func renderJoystickNormalizesAxesButtonsAndDpad() {
        let lines = ControllerMap.render(.steam, mode: .twoAxis)
            .split(separator: "\n")
            .map(String.init)
        // Steam Y axis is inverted (up = axis 1 1, down = axis 1 0) and D-pad is buttons 14/11/12/13
        #expect(lines.contains("jaxis_0_1- \"stick_0 axis 1 1\" \"stick_0 button 14\" "))
        #expect(lines.contains("jaxis_0_1+ \"stick_0 axis 1 0\" \"stick_0 button 11\" "))
        #expect(lines.contains("jaxis_0_0- \"stick_0 axis 0 0\" \"stick_0 button 12\" "))
        #expect(lines.contains("jaxis_0_0+ \"stick_0 axis 0 1\" \"stick_0 button 13\" "))
        // Steam A/B/X/Y/LT/RT are buttons 4/5/9/10/17/24
        #expect(lines.contains("jbutton_0_0 \"stick_0 button 4\" "))
        #expect(lines.contains("jbutton_0_1 \"stick_0 button 5\" "))
        #expect(lines.contains("jbutton_0_2 \"stick_0 button 9\" "))
        #expect(lines.contains("jbutton_0_3 \"stick_0 button 10\" "))
        #expect(lines.contains("jbutton_0_4 \"stick_0 button 17\" "))
        #expect(lines.contains("jbutton_0_5 \"stick_0 button 24\" "))
        // Start maps to Esc by default in joystick mode
        #expect(lines.first { $0.hasPrefix("key_esc ") }!.contains("\"stick_0 button 7\""))
        // Arrow keys do not also get stick/dpad in joystick mode
        #expect(!lines.first { $0.hasPrefix("key_up ") }!.contains("stick_0"))
    }
    @Test func renderJoystickAllowsCustomKeyOverrideOnTrigger() {
        let bindings = ControllerBindings(leftTrigger: .space, rightTrigger: .unbound)
        let lines = ControllerMap.render(.xboxUSB, mode: .fourAxis, bindings: bindings)
            .split(separator: "\n")
            .map(String.init)
        #expect(lines.contains("jbutton_0_4 "))
        #expect(lines.contains("jbutton_0_5 "))
        #expect(lines.first { $0.hasPrefix("key_space ") }!.contains("\"stick_0 button 14\""))
    }
    @Test func allControllerKeysExistInTemplate() {
        let templateEvents = Set(
            ControllerTemplate.text
                .split(separator: "\n")
                .compactMap { $0.split(separator: " ").first.map(String.init) }
        )
        for key in ControllerKey.allCases {
            if let event = key.mapperEvent {
                #expect(templateEvents.contains(event), "Missing template event \(event) for \(key)")
            }
        }
    }
}

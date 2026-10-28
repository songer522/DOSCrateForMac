import Testing
import ConfigKit
@testable import LauncherKit

@Suite struct LayoutSelectorTests {
    let xboxUSB = GamepadInfo(vendorID: 0x045e, productID: 0x0b12, transport: "USB", product: "Controller", usagePage: 1, usage: 5)
    let xboxBT = GamepadInfo(vendorID: 0x045e, productID: 0x0b13, transport: "Bluetooth", product: "Xbox Wireless Controller", usagePage: 1, usage: 5)
    let dualSense = GamepadInfo(vendorID: 0x054c, productID: 0x0ce6, transport: "Bluetooth", product: "DualSense Wireless Controller", usagePage: 1, usage: 5)
    let puck = GamepadInfo(vendorID: 0x28de, productID: 0x1304, transport: "USB", product: "Steam Controller Puck", usagePage: 1, usage: 2)
    let switch2 = GamepadInfo(vendorID: 0x057e, productID: 0x2069, transport: "USB", product: "Pro Controller", usagePage: 1, usage: 5)
    let mouse = GamepadInfo(vendorID: 0x05ac, productID: 0x0269, transport: "USB", product: "Magic Mouse", usagePage: 1, usage: 2)
    let keyboard = GamepadInfo(vendorID: 0x05ac, productID: 0x0342, transport: "SPI", product: "Apple Internal Keyboard", usagePage: 1, usage: 6)

    @Test func picksLayouts() {
        #expect(LayoutSelector.select([xboxUSB]) == .xboxUSB)
        #expect(LayoutSelector.select([xboxBT]) == .standard)
        #expect(LayoutSelector.select([dualSense]) == .standard)
        #expect(LayoutSelector.select([puck]) == .steam)
    }
    @Test func ignoresUnusable() {
        #expect(LayoutSelector.select([switch2]) == nil)
        #expect(LayoutSelector.select([mouse, keyboard]) == nil)
        #expect(LayoutSelector.select([]) == nil)
    }
    @Test func microsoftPeripheralsAreNotXboxUSB() {
        let msKeyboard = GamepadInfo(vendorID: 0x045e, productID: 0x07a5, transport: "USB", product: "Microsoft Keyboard", usagePage: 1, usage: 6)
        let msMouse = GamepadInfo(vendorID: 0x045e, productID: 0x0823, transport: "USB", product: "Microsoft Mouse", usagePage: 1, usage: 2)
        #expect(LayoutSelector.select([msKeyboard, msMouse]) == nil)
        #expect(LayoutSelector.select([msKeyboard, dualSense]) == .standard)
        #expect(LayoutSelector.select([msMouse, xboxBT]) == .standard)
    }
    @Test func switch2WithXbox() { #expect(LayoutSelector.select([switch2, xboxBT]) == .standard) }
    @Test func priority() {
        #expect(LayoutSelector.select([dualSense, puck]) == .steam)
        #expect(LayoutSelector.select([dualSense, xboxUSB]) == .xboxUSB)
    }
    @Test func joystickAndMultiAxisAreStandard() {
        var j = dualSense; j.vendorID = 0x1234; j.usage = 4; #expect(LayoutSelector.select([j]) == .standard)
        j.usage = 8; #expect(LayoutSelector.select([j]) == .standard)
    }
}

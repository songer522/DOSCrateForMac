import Testing
@testable import LauncherKit

@Suite struct ControllerStatusTests {
    let xboxUSB = GamepadInfo(vendorID: 0x045e, productID: 0x0b12, transport: "USB", product: "Controller", usagePage: 1, usage: 5)
    let xboxBT = GamepadInfo(vendorID: 0x045e, productID: 0x0b13, transport: "Bluetooth", product: "Xbox Wireless Controller", usagePage: 1, usage: 5)
    let dualSense = GamepadInfo(vendorID: 0x054c, productID: 0x0ce6, transport: "Bluetooth", product: "DualSense Wireless Controller", usagePage: 1, usage: 5)
    let puck1 = GamepadInfo(vendorID: 0x28de, productID: 0x1304, transport: "USB", product: "Steam Controller Puck", usagePage: 1, usage: 1)
    let puck2 = GamepadInfo(vendorID: 0x28de, productID: 0x1304, transport: "USB", product: "Steam Controller Puck", usagePage: 1, usage: 2)
    let puck3 = GamepadInfo(vendorID: 0x28de, productID: 0x1304, transport: "USB", product: "Steam Controller Puck", usagePage: 1, usage: 2)
    let switch2 = GamepadInfo(vendorID: 0x057e, productID: 0x2069, transport: "USB", product: "Pro Controller", usagePage: 1, usage: 5)
    let mouse = GamepadInfo(vendorID: 0x05ac, productID: 0x0269, transport: "USB", product: "Magic Mouse", usagePage: 1, usage: 2)
    let keyboard = GamepadInfo(vendorID: 0x05ac, productID: 0x0342, transport: "SPI", product: "Apple Internal Keyboard", usagePage: 1, usage: 6)

    @Test func xboxBTName() {
        let s = ControllerStatus.make([xboxBT], enabled: true)
        #expect(s == ControllerStatus(name: "Xbox Wireless Controller", extraCount: 0, supported: true, enabled: true))
        #expect(s?.label == "Xbox Wireless Controller")
    }

    @Test func wiredXboxGenericNameBecomesXboxController() {
        let s = ControllerStatus.make([xboxUSB], enabled: true)
        #expect(s == ControllerStatus(name: "Xbox Controller", extraCount: 0, supported: true, enabled: true))
        #expect(s?.label == "Xbox Controller")
    }

    @Test func emptyNamesFallback() {
        var unnamedXbox = xboxBT; unnamedXbox.product = ""
        #expect(ControllerStatus.make([unnamedXbox], enabled: true)?.name == "Xbox Controller")
        var unnamedOther = dualSense; unnamedOther.product = ""
        #expect(ControllerStatus.make([unnamedOther], enabled: true)?.name == "Game Controller")
    }

    @Test func steamPuckThreeEntriesCountAsOne() {
        let s = ControllerStatus.make([puck1, puck2, puck3], enabled: true)
        #expect(s == ControllerStatus(name: "Steam Controller Puck", extraCount: 0, supported: true, enabled: true))
        #expect(s?.label == "Steam Controller Puck")
    }

    @Test func prioritySteamOverXboxUSBOverOthers() {
        let all = [dualSense, xboxUSB, puck1, puck2, puck3]
        let s = ControllerStatus.make(all, enabled: true)
        #expect(s == ControllerStatus(name: "Steam Controller Puck", extraCount: 2, supported: true, enabled: true))
        #expect(s?.label == "Steam Controller Puck +2")
    }

    @Test func dualSensePlusXboxUSBShowsXboxWithPlusOne() {
        let s = ControllerStatus.make([dualSense, xboxUSB], enabled: true)
        #expect(s == ControllerStatus(name: "Xbox Controller", extraCount: 1, supported: true, enabled: true))
        #expect(s?.label == "Xbox Controller +1")
    }

    @Test func switch2AloneIsUnsupported() {
        let s = ControllerStatus.make([switch2], enabled: true)
        #expect(s == ControllerStatus(name: "Pro Controller", extraCount: 0, supported: false, enabled: true))
        #expect(s?.label == "Pro Controller — not supported")
    }

    @Test func switch2PlusXboxBTShowsXboxPlusOne() {
        let s = ControllerStatus.make([switch2, xboxBT], enabled: true)
        #expect(s == ControllerStatus(name: "Xbox Wireless Controller", extraCount: 1, supported: true, enabled: true))
        #expect(s?.label == "Xbox Wireless Controller +1")
    }

    @Test func switchOffAppendsOff() {
        let s = ControllerStatus.make([xboxBT], enabled: false)
        #expect(s == ControllerStatus(name: "Xbox Wireless Controller", extraCount: 0, supported: true, enabled: false))
        #expect(s?.label == "Xbox Wireless Controller (off)")
        let two = ControllerStatus.make([dualSense, xboxUSB], enabled: false)
        #expect(two?.label == "Xbox Controller +1 (off)")
    }

    @Test func mouseAndKeyboardOrEmptyReturnsNil() {
        #expect(ControllerStatus.make([mouse, keyboard], enabled: true) == nil)
        #expect(ControllerStatus.make([], enabled: true) == nil)
    }
}

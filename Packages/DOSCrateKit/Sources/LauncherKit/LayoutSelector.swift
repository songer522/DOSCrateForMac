import ConfigKit

public struct GamepadInfo: Equatable, Sendable {
    public var vendorID: Int
    public var productID: Int
    public var transport: String
    public var product: String
    public var usagePage: Int
    public var usage: Int

    public init(vendorID: Int, productID: Int, transport: String, product: String, usagePage: Int, usage: Int) {
        self.vendorID = vendorID
        self.productID = productID
        self.transport = transport
        self.product = product
        self.usagePage = usagePage
        self.usage = usage
    }
}

public enum LayoutSelector {
    public static func select(_ devices: [GamepadInfo]) -> ControllerLayout? {
        let usable = devices.filter { !($0.vendorID == 0x057e && $0.productID == 0x2069) }
        if usable.contains(where: { $0.vendorID == 0x28de }) { return .steam }
        if usable.contains(where: { $0.vendorID == 0x045e && $0.transport == "USB" }) { return .xboxUSB }
        if usable.contains(where: { $0.usagePage == 1 && (4...5 ~= $0.usage || $0.usage == 8) }) { return .standard }
        return nil
    }
}

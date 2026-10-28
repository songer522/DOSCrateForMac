public struct ControllerStatus: Equatable, Sendable {
    public var name: String
    public var extraCount: Int
    public var supported: Bool
    public var enabled: Bool

    public init(name: String, extraCount: Int, supported: Bool, enabled: Bool) {
        self.name = name
        self.extraCount = extraCount
        self.supported = supported
        self.enabled = enabled
    }

    public var label: String {
        var text = extraCount > 0 ? "\(name) +\(extraCount)" : name
        if !supported {
            text += " — not supported"
        } else if !enabled {
            text += " (off)"
        }
        return text
    }

    public static func make(_ devices: [GamepadInfo], enabled: Bool) -> ControllerStatus? {
        let controllers = dedupe(devices.filter(isController))
        guard !controllers.isEmpty else { return nil }
        let usable = controllers.filter { !isUnsupported($0) }
        let chosen: GamepadInfo
        let supported: Bool
        if let steam = usable.first(where: { $0.vendorID == 0x28de }) {
            chosen = steam
            supported = true
        } else if let xboxUSB = usable.first(where: { $0.vendorID == 0x045e && $0.transport == "USB" }) {
            chosen = xboxUSB
            supported = true
        } else if let other = usable.first {
            chosen = other
            supported = true
        } else {
            chosen = controllers[0]
            supported = false
        }
        return ControllerStatus(
            name: displayName(chosen),
            extraCount: controllers.count - 1,
            supported: supported,
            enabled: enabled
        )
    }

    private static func isController(_ d: GamepadInfo) -> Bool {
        d.vendorID == 0x28de
            || (d.usagePage == 1 && (4...5 ~= d.usage || d.usage == 8))
            || isUnsupported(d)
    }

    private static func isUnsupported(_ d: GamepadInfo) -> Bool {
        d.vendorID == 0x057e && d.productID == 0x2069
    }

    private static func dedupe(_ devices: [GamepadInfo]) -> [GamepadInfo] {
        struct Key: Hashable { var vendorID: Int; var productID: Int; var transport: String }
        var seen: Set<Key> = []
        return devices.filter { seen.insert(Key(vendorID: $0.vendorID, productID: $0.productID, transport: $0.transport)).inserted }
    }

    private static func displayName(_ d: GamepadInfo) -> String {
        if d.product.isEmpty || (d.vendorID == 0x045e && d.product == "Controller") {
            return d.vendorID == 0x045e ? "Xbox Controller" : "Game Controller"
        }
        return d.product
    }
}

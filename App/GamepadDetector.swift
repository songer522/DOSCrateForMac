import Foundation
import IOKit.hid
import LauncherKit

enum GamepadDetector {
    static func snapshot() -> [GamepadInfo] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return devices.map(GamepadInfo.init(device:))
    }
}

extension GamepadInfo {
    init(device: IOHIDDevice) {
        self.init(
            vendorID: Self.int(device, kIOHIDVendorIDKey),
            productID: Self.int(device, kIOHIDProductIDKey),
            transport: Self.string(device, kIOHIDTransportKey),
            product: Self.string(device, kIOHIDProductKey),
            usagePage: Self.int(device, kIOHIDPrimaryUsagePageKey),
            usage: Self.int(device, kIOHIDPrimaryUsageKey)
        )
    }

    private static func int(_ d: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(d, key as CFString) as? NSNumber)?.intValue ?? 0
    }

    private static func string(_ d: IOHIDDevice, _ key: String) -> String {
        IOHIDDeviceGetProperty(d, key as CFString) as? String ?? ""
    }
}

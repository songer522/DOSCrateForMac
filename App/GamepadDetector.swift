import Foundation
import IOKit.hid
import LauncherKit

enum GamepadDetector {
    static func snapshot() -> [GamepadInfo] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return devices.map { d in
            GamepadInfo(
                vendorID: int(d, kIOHIDVendorIDKey),
                productID: int(d, kIOHIDProductIDKey),
                transport: string(d, kIOHIDTransportKey),
                product: string(d, kIOHIDProductKey),
                usagePage: int(d, kIOHIDPrimaryUsagePageKey),
                usage: int(d, kIOHIDPrimaryUsageKey)
            )
        }
    }

    private static func int(_ d: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(d, key as CFString) as? NSNumber)?.intValue ?? 0
    }

    private static func string(_ d: IOHIDDevice, _ key: String) -> String {
        IOHIDDeviceGetProperty(d, key as CFString) as? String ?? ""
    }
}

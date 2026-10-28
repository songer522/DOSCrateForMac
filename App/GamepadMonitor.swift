import Foundation
import IOKit.hid
import LauncherKit
import Observation

@MainActor @Observable
final class GamepadMonitor {
    private(set) var devices: [GamepadInfo] = []
    @ObservationIgnored nonisolated(unsafe) private let manager: IOHIDManager

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        let context = Unmanaged.passUnretained(self).toOpaque()
        // The removal callback fires while IOHIDManagerCopyDevices still lists the device,
        // so track the set from the callbacks instead of re-reading it.
        let added: IOHIDDeviceCallback = { context, _, _, device in
            guard let context else { return }
            let monitor = Unmanaged<GamepadMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.update { $0.insert(device) } }
        }
        let removed: IOHIDDeviceCallback = { context, _, _, device in
            guard let context else { return }
            let monitor = Unmanaged<GamepadMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.update { $0.remove(device) } }
        }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, added, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, removed, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        update { $0 = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? [] }
    }

    deinit {
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    @ObservationIgnored private var connected: Set<IOHIDDevice> = []

    private func update(_ change: (inout Set<IOHIDDevice>) -> Void) {
        change(&connected)
        devices = connected.map(GamepadInfo.init(device:)).sorted {
            ($0.vendorID, $0.productID, $0.transport, $0.usagePage, $0.usage, $0.product)
                < ($1.vendorID, $1.productID, $1.transport, $1.usagePage, $1.usage, $1.product)
        }
    }
}

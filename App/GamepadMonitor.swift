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
        let callback: IOHIDDeviceCallback = { context, _, _, _ in
            guard let context else { return }
            let monitor = Unmanaged<GamepadMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                monitor.refresh()
            }
        }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, callback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, callback, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        refresh()
    }

    deinit {
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    private func refresh() {
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            devices = []
            return
        }
        devices = set.map(GamepadInfo.init(device:)).sorted {
            ($0.vendorID, $0.productID, $0.transport, $0.usagePage, $0.usage, $0.product)
                < ($1.vendorID, $1.productID, $1.transport, $1.usagePage, $1.usage, $1.product)
        }
    }
}

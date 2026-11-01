import Foundation
import IOKit.hid

/// Reads the Nape Pro's battery level through the 2.4GHz receiver (Keychron
/// Link-KM). The device's own interface over the USB cable is asked too, but
/// that path has not been measured.
///
/// The receiver exposes the same 32-byte raw HID channel as the device itself
/// (usage page 0xFF60) and relays it over the air, so the device's own
/// `KC_USER_CMD_NAPE_GET_BAT_REPORT` reaches it: send `A7 31`, and the reply is
/// `A7 31 <percent> <charging>`. The command comes from Keychron Launcher,
/// which asks exactly this whenever it connects to a Nape Pro; it is a read.
/// Keyboards answer `FF 31` (unknown sub-command) and change nothing, but the
/// request still goes only to interfaces named like a receiver or the device.
///
/// A receiver with nothing paired, or with the device asleep or on Bluetooth,
/// simply never answers, so silence after `timeout` means no level.
///
/// Everything runs on the queue given at init, and `onLevel` is called there.
final class ReceiverBattery: @unchecked Sendable {
    var onLevel: ((Int?) -> Void)?

    static let vendorID = 0x3434
    static let usagePage = 0xFF60
    static let request: [UInt8] = [0xA7, 0x31]
    private static let reportSize = 32
    private static let timeout: TimeInterval = 2

    private let queue: DispatchQueue
    private let names: [String]
    private var manager: IOHIDManager?
    /// Bumped per query, so a timeout left over from an earlier one cannot
    /// clear a level that a later query already got.
    private var generation = 0
    private var answered = false

    init(queue: DispatchQueue, names: [String] = ["Link", "Nape Pro"]) {
        self.queue = queue
        self.names = names
    }

    /// Pulls the level out of an input report, or nil if the report is not
    /// the answer to `request`.
    static func level(fromReport bytes: [UInt8]) -> Int? {
        guard bytes.count >= 3, bytes[0] == request[0], bytes[1] == request[1] else { return nil }
        return min(100, Int(bytes[2]))
    }

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: Self.vendorID,
            kIOHIDPrimaryUsagePageKey: Self.usagePage,
        ] as CFDictionary)
        IOHIDManagerRegisterInputReportCallback(manager, { context, _, _, _, _, report, length in
            let reader = Unmanaged<ReceiverBattery>.fromOpaque(context!).takeUnretainedValue()
            reader.received(Array(UnsafeBufferPointer(start: report, count: length)))
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerSetDispatchQueue(manager, queue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerActivate(manager)
        self.manager = manager
    }

    func stop() {
        guard let manager else { return }
        IOHIDManagerCancel(manager)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        generation += 1
    }

    /// Asks every matching interface. Two receivers can be plugged in with
    /// only one paired to the device; the other stays silent.
    func query() {
        guard let manager else { return }
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        let targets = devices.filter { device in
            let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
            return names.contains { name.localizedCaseInsensitiveContains($0) }
        }
        guard !targets.isEmpty else {
            onLevel?(nil)
            return
        }
        generation += 1
        answered = false
        var packet = [UInt8](repeating: 0, count: Self.reportSize)
        packet.replaceSubrange(0..<Self.request.count, with: Self.request)
        for device in targets {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, packet, packet.count)
        }
        let sent = generation
        queue.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
            guard let self, self.generation == sent, !self.answered else { return }
            self.onLevel?(nil)
        }
    }

    private func received(_ bytes: [UInt8]) {
        guard let level = Self.level(fromReport: bytes) else { return }
        answered = true
        onLevel?(level)
    }
}

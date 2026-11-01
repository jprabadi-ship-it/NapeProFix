import CoreBluetooth
import Foundation

/// Reads the Nape Pro's battery level, over Bluetooth LE or through the
/// 2.4GHz receiver, whichever the device is on.
///
/// Over Bluetooth the device publishes the standard Battery Service (0x180F,
/// characteristic 0x2A19). On the receiver there is no standard route, and
/// these were ruled out by measurement:
///
/// - No HID Battery System page (0x85) in the report descriptor.
/// - The VIA channel (0xFF60) answers 0xFF for every `id_get_keyboard_value`
///   sub-id past the documented four, and has no `id_custom_get_value`
///   channels at all.
/// - macOS does not republish the level in the IO registry for this device —
///   `BatteryPercent` is absent even while the system's own Bluetooth menu
///   shows a number — so there is nothing to read there either.
///
/// What does work is Keychron's own command on that same 0xFF60 channel; see
/// `ReceiverBattery`. The two sources never both answer, since the device is
/// on one link at a time; Bluetooth wins if they somehow do.
///
/// The Bluetooth device is reached through `retrieveConnectedPeripherals`,
/// which hands back a peripheral the system already owns: no scanning, no
/// pairing, and it keeps working as a pointing device throughout. Needs the
/// Bluetooth permission (`NSBluetoothAlwaysUsageDescription`); denied, only the
/// receiver route is left.
final class BatteryMonitor: NSObject, @unchecked Sendable {
    /// Called on the main actor, only when the value changes. nil means no
    /// level is available: device absent, asleep, or unreachable both ways.
    var onChange: (@MainActor (Int?) -> Void)?

    // Instance rather than static: CBUUID is not Sendable, and Swift 6 rejects
    // it as a global. Immutable per-instance state is fine under
    // @unchecked Sendable.
    private let batteryService = CBUUID(string: "180F")
    private let batteryLevel = CBUUID(string: "2A19")

    private let productName: String

    /// Everything below is touched only on this queue. Core Bluetooth delivers
    /// its delegate calls here, and the public methods hop onto it.
    private let queue = DispatchQueue(label: "jp.local.NapeProFix.battery")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private lazy var receiver = ReceiverBattery(queue: queue)
    private var bluetoothLevel: Int? { didSet { publish() } }
    private var receiverLevel: Int? { didSet { publish() } }
    private var published: Int?

    init(productName: String = "Nape Pro") {
        self.productName = productName
    }

    private func publish() {
        let value = bluetoothLevel ?? receiverLevel
        guard value != published else { return }
        published = value
        DispatchQueue.main.async { [onChange] in
            MainActor.assumeIsolated { onChange?(value) }
        }
    }

    /// Creating the central is what triggers the Bluetooth permission prompt,
    /// so it happens here rather than in init.
    func start() {
        queue.async {
            guard self.central == nil else { return }
            self.central = CBCentralManager(delegate: self, queue: self.queue)
            self.receiver.onLevel = { [weak self] in self?.receiverLevel = $0 }
            self.receiver.start()
            self.receiver.query()
        }
    }

    func stop() {
        queue.async {
            if let peripheral = self.peripheral {
                self.central?.cancelPeripheralConnection(peripheral)
            }
            self.peripheral = nil
            self.characteristic = nil
            self.central = nil
            self.receiver.stop()
            self.bluetoothLevel = nil
            self.receiverLevel = nil
        }
    }

    /// Re-reads the level, and re-checks whether the device is reachable at
    /// all. Switching the device between the receiver and Bluetooth produces
    /// no notification, so this has to be polled.
    func refresh() {
        queue.async {
            self.attach()
            self.receiver.query()
        }
    }

    private func attach() {
        guard let central, central.state == .poweredOn else { return }
        if let peripheral, peripheral.state == .connected {
            if let characteristic { peripheral.readValue(for: characteristic) }
            return
        }
        let found = central.retrieveConnectedPeripherals(withServices: [batteryService])
            .first { $0.name?.localizedCaseInsensitiveContains(productName) == true }
        guard let found else {
            peripheral = nil
            characteristic = nil
            bluetoothLevel = nil
            return
        }
        peripheral = found
        found.delegate = self
        central.connect(found, options: nil)
    }
}

extension BatteryMonitor: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            attach()
        } else {
            peripheral = nil
            characteristic = nil
            bluetoothLevel = nil
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([batteryService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        self.peripheral = nil
        bluetoothLevel = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        self.peripheral = nil
        characteristic = nil
        bluetoothLevel = nil
    }
}

extension BatteryMonitor: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == batteryService {
            peripheral.discoverCharacteristics([batteryLevel], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for found in service.characteristics ?? [] where found.uuid == batteryLevel {
            characteristic = found
            peripheral.readValue(for: found)
            // Pushed by the device as it drains, so the number stays current
            // between polls without asking for it.
            peripheral.setNotifyValue(true, for: found)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil, let byte = characteristic.value?.first else { return }
        bluetoothLevel = min(100, Int(byte))
    }
}

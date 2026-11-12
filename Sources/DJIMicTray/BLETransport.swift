// 蓝牙通道：直连单个发射器（TX），不经过接收器。
// 服务 0xFFF0，读写共用特征 0xFFF4（写用 without response，与上游 Web Bluetooth 版一致）。

import CoreBluetooth
import Foundation

struct BLEDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    var rssi: Int
}

final class BLETransport: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let serviceUUID = CBUUID(string: "FFF0")
    static let charUUID = CBUUID(string: "FFF4")

    var onDiscover: (([BLEDevice]) -> Void)?
    var onScanStateChange: ((Bool) -> Void)?
    var onReady: ((String) -> Void)?
    var onBytes: (([UInt8]) -> Void)?
    var onClose: ((Error?) -> Void)?
    var onError: ((String) -> Void)?

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var devices: [UUID: BLEDevice] = [:]
    private var wantScan = false
    private var stopScanWork: DispatchWorkItem?

    private var active: CBPeripheral?
    private var activeName = ""
    private var characteristic: CBCharacteristic?
    private var pendingWrites: [[UInt8]] = []
    private var writing = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: 扫描

    func startScan(duration: TimeInterval = 10) {
        devices.removeAll()
        onDiscover?([])
        wantScan = true
        if central.state == .poweredOn { beginScan(duration: duration) }
        else if central.state == .unauthorized { onError?("没有蓝牙权限：请在“系统设置 → 隐私与安全性 → 蓝牙”里允许 DJIMicTray") }
        else if central.state == .poweredOff { onError?("蓝牙已关闭") }
    }

    private func beginScan(duration: TimeInterval) {
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        onScanStateChange?(true)
        stopScanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.stopScan() }
        stopScanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func stopScan() {
        wantScan = false
        stopScanWork?.cancel()
        if central.isScanning { central.stopScan() }
        onScanStateChange?(false)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if wantScan { beginScan(duration: 10) }
        case .unauthorized:
            if wantScan { onError?("没有蓝牙权限：请在“系统设置 → 隐私与安全性 → 蓝牙”里允许 DJIMicTray") }
            stopScan()
        case .poweredOff:
            if wantScan { onError?("蓝牙已关闭") }
            stopScan()
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard name.contains("DJI Mic") else { return }
        peripherals[peripheral.identifier] = peripheral
        devices[peripheral.identifier] = BLEDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        onDiscover?(devices.values.sorted { $0.rssi > $1.rssi })
    }

    // MARK: 连接

    func connect(_ device: BLEDevice) {
        guard let p = peripherals[device.id] else { return }
        stopScan()
        disconnect()
        active = p
        activeName = device.name
        p.delegate = self
        central.connect(p)
    }

    func disconnect() {
        pendingWrites.removeAll()
        writing = false
        characteristic = nil
        if let p = active { central.cancelPeripheralConnection(p) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral == active else { return }
        active = nil
        onClose?(error ?? NSError(domain: "DJIMicTray", code: 1, userInfo: [NSLocalizedDescriptionKey: "蓝牙连接失败"]))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral == active else { return }
        active = nil
        characteristic = nil
        pendingWrites.removeAll()
        writing = false
        onClose?(error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            fail(peripheral, "设备上没有找到控制服务 FFF0")
            return
        }
        peripheral.discoverCharacteristics([Self.charUUID], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let ch = service.characteristics?.first(where: { $0.uuid == Self.charUUID }) else {
            fail(peripheral, "设备上没有找到控制特征 FFF4")
            return
        }
        characteristic = ch
        peripheral.setNotifyValue(true, for: ch)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            fail(peripheral, "订阅设备通知失败：\(error.localizedDescription)")
            return
        }
        onReady?(activeName)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let v = characteristic.value else { return }
        onBytes?([UInt8](v))
    }

    private func fail(_ peripheral: CBPeripheral, _ msg: String) {
        onError?(msg)
        central.cancelPeripheralConnection(peripheral)
    }

    // MARK: 写

    func write(_ bytes: [UInt8]) {
        pendingWrites.append(bytes)
        flushWrites()
    }

    /// 逐包写出，包之间间隔 10ms，与上游一致。
    private func flushWrites() {
        guard !writing, !pendingWrites.isEmpty, let p = active, let ch = characteristic else { return }
        let bytes = pendingWrites.removeFirst()
        let type: CBCharacteristicWriteType = ch.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(Data(bytes), for: ch, type: type)
        writing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            self?.writing = false
            self?.flushWrites()
        }
    }
}

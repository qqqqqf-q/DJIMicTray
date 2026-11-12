// 连接与状态的唯一来源：管理当前通道（USB 或蓝牙）、解析回包、把界面上的修改编码成命令发出去。

import AppKit
import Foundation
import ServiceManagement

enum ConnectionKind: Equatable {
    case usb
    case ble(String)
}

enum ConnectionPhase: Equatable {
    case idle
    case connecting(String)
    case connected(ConnectionKind)
}

@MainActor
final class MicController: ObservableObject {
    @Published private(set) var state = DeviceState()
    @Published private(set) var phase: ConnectionPhase = .idle
    @Published var lastError: String?
    @Published private(set) var bleDevices: [BLEDevice] = []
    @Published private(set) var bleScanning = false
    @Published var autoConnectUSB: Bool {
        didSet { UserDefaults.standard.set(autoConnectUSB, forKey: "autoConnectUSB") }
    }
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    private var proto: MicProtocol?
    private var framer = PacketFramer()
    private var seq: UInt16 = 0
    private var usb: USBTransport?
    private lazy var ble: BLETransport = makeBLE()
    private var hotplug: USBHotplugMonitor?

    init() {
        autoConnectUSB = UserDefaults.standard.object(forKey: "autoConnectUSB") as? Bool ?? true
        hotplug = USBHotplugMonitor { [weak self] in
            Task { @MainActor in self?.autoConnectIfNeeded() }
        }
        autoConnectIfNeeded()
    }

    var isConnected: Bool { if case .connected = phase { return true } else { return false } }

    /// 设备名就绪，可以写入。
    var isReady: Bool { proto?.isReady(state) ?? false }

    var isRecording: Bool {
        state.nodes.values.contains { $0["rec"]?.boolValue == true }
    }

    // MARK: 连接

    private func autoConnectIfNeeded() {
        guard autoConnectUSB, phase == .idle, USBTransport.isReceiverPresent() else { return }
        connectUSB(silent: true)
    }

    func connectUSB(silent: Bool = false) {
        guard phase == .idle else { return }
        lastError = nil
        let t = USBTransport()
        do {
            try t.open()
        } catch {
            // 自动连接时没找到设备属于正常情况，不打扰用户
            if silent, case USBTransportError.notFound = error { return }
            lastError = error.localizedDescription
            return
        }
        t.onBytes = { [weak self] bytes in self?.receive(bytes) }
        t.onClose = { [weak self] error in self?.transportClosed(error) }
        usb = t
        begin(USBProtocol(), kind: .usb)
    }

    func scanBluetooth() {
        lastError = nil
        ble.startScan()
    }

    func stopBluetoothScan() { ble.stopScan() }

    func connectBluetooth(_ device: BLEDevice) {
        guard phase == .idle else { return }
        lastError = nil
        phase = .connecting(device.name)
        ble.connect(device)
    }

    func disconnect() {
        if let usb {
            usb.close()
        } else {
            ble.disconnect()
        }
    }

    private func makeBLE() -> BLETransport {
        let t = BLETransport()
        t.onDiscover = { [weak self] list in self?.bleDevices = list }
        t.onScanStateChange = { [weak self] s in self?.bleScanning = s }
        t.onError = { [weak self] msg in self?.lastError = msg }
        t.onBytes = { [weak self] bytes in self?.receive(bytes) }
        t.onClose = { [weak self] error in self?.transportClosed(error) }
        t.onReady = { [weak self] name in
            self?.begin(BLEProtocol(advertisedName: name), kind: .ble(name))
        }
        return t
    }

    private func begin(_ p: MicProtocol, kind: ConnectionKind) {
        proto = p
        framer.reset()
        seq = 0
        state = p.initialState()
        phase = .connected(kind)
    }

    private func transportClosed(_ error: Error?) {
        if let error { lastError = error.localizedDescription }
        usb = nil
        proto = nil
        framer.reset()
        state = DeviceState()
        phase = .idle
    }

    // MARK: 收

    private func receive(_ bytes: [UInt8]) {
        guard let proto else { return }
        var next = state
        for pkt in framer.push(bytes) {
            proto.parse(pkt, into: &next)
        }
        if next != state { state = next }
    }

    // MARK: 发

    /// 字段当前是否应在界面上显示为可修改：可写、机型支持、并且设备已经报告过它的值。
    func canEdit(_ node: Node, _ key: String) -> Bool {
        guard let proto, state.value(node, key) != nil else { return false }
        return proto.canWrite(node, key, state)
    }

    /// 应用一批修改。与上游 apply() 一致：先同步一次时钟，plugFreeExternalSpeaker 放在最后发。
    func apply(_ changes: [(Node, String, FieldValue)]) {
        guard let proto, isReady else { return }
        let ordered = changes.filter { !($0.0 == .rx && $0.1 == "plugFreeExternalSpeaker") }
            + changes.filter { $0.0 == .rx && $0.1 == "plugFreeExternalSpeaker" }

        var commands: [(cmd: UInt8, node: Node, val: UInt8)] = []
        var optimistic = state
        for (node, key, value) in ordered {
            // 值未变化不重复发送（上游以“值和类型都相同”为准，FieldValue 的相等比较已包含类型）
            guard state.value(node, key) != value,
                  proto.canWrite(node, key, state),
                  let rule = proto.rule(node, key), let cmd = rule.cmd,
                  let enc = rule.encode?.encode(value) else { continue }
            commands.append((cmd, node, enc))
            // 先在界面上反映修改，设备的下一个状态包会覆盖成实际值。格式化不做本地预测。
            if key != "recordingTimeRemaining" { optimistic[node]?[key] = value }
        }
        guard !commands.isEmpty else { return }
        if let time = proto.timePacket(seq: seq) {
            seq &+= 1
            send(time)
        }
        for c in commands {
            send(proto.commandPacket(node: c.node, cmd: c.cmd, val: c.val, seq: seq))
            seq &+= 1
        }
        state = optimistic
    }

    func set(_ node: Node, _ key: String, _ value: FieldValue) {
        apply([(node, key, value)])
    }

    private func send(_ pkt: [UInt8]) {
        if let usb { usb.write(pkt) } else { ble.write(pkt) }
    }

    // MARK: 杂项

    func copyStateJSON() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.jsonString, forType: .string)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = "设置登录启动失败：\(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

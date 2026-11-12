// DJI Mic Mini 系列私有控制协议。
//
// 移植自 usokawa/dji-mic-mo（BSD 2-Clause，Copyright (c) 2026 usokawa_，许可全文见仓库根目录
// LICENSE-dji-mic-mo.md），基线 commit 7c2dd5b0262f35b475193224fca2681d75987e9c。
// 字段表、偏移、命令号和编码规则与上游 dji-mic-mo.py / dji-mic-mo-ble.py 保持一一对应，
// 修改时先对照上游，不要凭理解改写：这些数字来自抓包逆向，没有公开文档可以校验。

import Foundation

// MARK: - 基础类型

enum FieldValue: Equatable, CustomStringConvertible {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    var boolValue: Bool? { if case .bool(let v) = self { return v } else { return nil } }
    var intValue: Int? { if case .int(let v) = self { return v } else { return nil } }
    var doubleValue: Double? { if case .double(let v) = self { return v } else { return nil } }
    var stringValue: String? { if case .string(let v) = self { return v } else { return nil } }

    var description: String {
        switch self {
        case .bool(let v): return v ? "true" : "false"
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .string(let v): return v
        }
    }

    var jsonObject: Any {
        switch self {
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        }
    }
}

/// 状态树里的节点。USB 模式下 rx 是接收器，tx 是“全部发射器”的广播视图，tx1…tx4 是单个发射器；
/// 蓝牙直连只有 tx 一个节点。
enum Node: String, CaseIterable, Comparable {
    case rx, tx, tx1, tx2, tx3, tx4

    /// USB 写命令里的目标地址；tx 用 0xffff 广播给所有发射器。
    var usbAddress: UInt16 {
        switch self {
        case .rx: return 0x00
        case .tx: return 0xffff
        case .tx1: return 0x01
        case .tx2: return 0x02
        case .tx3: return 0x04
        case .tx4: return 0x08
        }
    }

    var isIndividualTX: Bool { [.tx1, .tx2, .tx3, .tx4].contains(self) }

    static func < (a: Node, b: Node) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

typealias NodeState = [String: FieldValue]

struct DeviceState: Equatable {
    /// 节点存在即表示设备当前报告了它；值里只放已经解析出来的字段。
    var nodes: [Node: NodeState] = [:]

    subscript(node: Node) -> NodeState? {
        get { nodes[node] }
        set { nodes[node] = newValue }
    }

    func value(_ node: Node, _ key: String) -> FieldValue? { nodes[node]?[key] }

    var jsonString: String {
        var obj: [String: Any] = [:]
        for (node, fields) in nodes {
            obj[node.rawValue] = fields.mapValues { $0.jsonObject }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - 字段解码 / 编码

enum Decoder {
    case ver(reversed: Bool)
    case fstr(Int)
    case vstr
    case f16
    case i8
    case u8
    case bits(shift: Int, mask: UInt8)
    case bit(UInt8)

    /// 上游 Python 依赖切片越界自动截断，这里用 clamp 复现同样的宽容行为。
    func decode(_ buf: [UInt8], _ off: Int) -> FieldValue {
        func slice(_ start: Int, _ count: Int) -> ArraySlice<UInt8> {
            let s = max(0, min(start, buf.count))
            let e = max(s, min(start + count, buf.count))
            return buf[s..<e]
        }
        switch self {
        case .ver(let rev):
            let b = Array(slice(off, 4))
            let parts = (rev ? b.reversed() : b).map { String(format: "%02d", $0) }
            return .string(parts.joined(separator: "."))
        case .fstr(let n):
            return .string(String(decoding: slice(off, n), as: UTF8.self))
        case .vstr:
            let len = off >= 1 && off - 1 < buf.count ? Int(buf[off - 1]) : 0
            return .string(String(decoding: slice(off, len), as: UTF8.self))
        case .f16:
            var v = 0
            for (i, b) in slice(off, 2).enumerated() { v |= Int(b) << (8 * i) }
            return .double(Double(v) / 10)
        case .i8:
            return .int(Int(Int8(bitPattern: buf[off])))
        case .u8:
            return .int(Int(buf[off]))
        case .bits(let shift, let mask):
            return .int(Int((buf[off] >> shift) & mask))
        case .bit(let mask):
            return .bool(buf[off] & mask != 0)
        }
    }
}

enum Encoder {
    case bl1, bl2, bl21, bl4
    /// RX 增益只接受 6dB 步进。
    case gain
    /// 1dB 步进，-12…12。
    case gain1

    func encode(_ v: FieldValue) -> UInt8? {
        switch (self, v) {
        case (.bl1, .bool(let b)): return b ? 1 : 0
        case (.bl2, .bool(let b)): return b ? 2 : 0
        case (.bl21, .bool(let b)): return b ? 2 : 1
        case (.bl4, .bool(let b)): return b ? 4 : 0
        case (.gain, .int(let g)) where [-12, -6, 0, 6, 12].contains(g):
            return UInt8(bitPattern: Int8(g))
        case (.gain1, .int(let g)) where (-12...12).contains(g):
            return UInt8(bitPattern: Int8(g))
        default: return nil
        }
    }
}

/// 一条字段规则。typ 是数据块类型（0x01 设备信息 / 0x03 设置 / 0x05 电平 等），off 是相对节点基址的偏移。
/// cmd/encode 为空表示只读。model 限定机型：
///   "X"   读写都只对设备名 == X 生效
///   "!X"  读写都只对设备名 != X 生效
///   "+X"  读不限机型，写只对 == X 生效
///   "-X"  读不限机型，写只对 != X 生效
struct Rule {
    let key: String
    let typ: UInt8
    let off: Int
    let decode: Decoder
    let cmd: UInt8?
    let encode: Encoder?
    let model: String?

    init(_ key: String, _ typ: UInt8, _ off: Int, _ decode: Decoder,
         _ cmd: UInt8? = nil, _ encode: Encoder? = nil, _ model: String? = nil) {
        self.key = key; self.typ = typ; self.off = off; self.decode = decode
        self.cmd = cmd; self.encode = encode; self.model = model
    }

    init(_ key: String, _ typ: UInt8, _ off: Int, _ decode: Decoder, model: String) {
        self.init(key, typ, off, decode, nil, nil, model)
    }

    var writable: Bool { cmd != nil && encode != nil }

    /// 对应上游 valid() 里的机型判断部分。
    func modelMatches(nodeName: String?, write: Bool) -> Bool {
        guard let m = model else { return true }
        if !write && (m.hasPrefix("+") || m.hasPrefix("-")) { return true }
        guard let name = nodeName else { return false }
        if m.hasPrefix("!") || m.hasPrefix("-") { return name != String(m.dropFirst()) }
        return name == (m.hasPrefix("+") ? String(m.dropFirst()) : m)
    }
}

// MARK: - CRC 与分帧

enum DJICRC {
    static let tables: ([UInt8], [UInt16]) = {
        var t8 = [UInt8](repeating: 0, count: 256)
        var t16 = [UInt16](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt8(i)
            var k = UInt16(i)
            for _ in 0..<8 {
                c = (c >> 1) ^ ((c & 1) != 0 ? 0x8c : 0)
                k = (k >> 1) ^ ((k & 1) != 0 ? 0x8408 : 0)
            }
            t8[i] = c
            t16[i] = k
        }
        return (t8, t16)
    }()

    static func crc8<C: Collection>(_ buf: C) -> UInt8 where C.Element == UInt8 {
        var c: UInt8 = 0x77
        for b in buf { c = tables.0[Int(c ^ b)] }
        return c
    }

    static func crc16<C: Collection>(_ buf: C) -> UInt16 where C.Element == UInt8 {
        var c: UInt16 = 0x3692
        for b in buf { c = (c >> 8) ^ tables.1[Int((c ^ UInt16(b)) & 0xff)] }
        return c
    }
}

/// 从字节流里切出完整数据包：0x55 起始，3 字节头带 crc8，总长在头里低 10 位，末尾 crc16。
struct PacketFramer {
    private var buf: [UInt8] = []

    mutating func reset() { buf.removeAll() }

    mutating func push(_ chunk: [UInt8]) -> [[UInt8]] {
        buf.append(contentsOf: chunk)
        var out: [[UInt8]] = []
        var off = 0
        while off < buf.count {
            guard let idx = buf[off...].firstIndex(of: 0x55) else { off = buf.count; break }
            off = idx
            if buf.count - off < 4 { break }
            if DJICRC.crc8(buf[off..<off + 3]) != buf[off + 3] { off += 1; continue }
            let sz = (Int(buf[off + 1]) | Int(buf[off + 2]) << 8) & 0x3ff
            if sz < 13 { off += 1; continue }
            if sz > buf.count - off { break }
            let pkt = Array(buf[off..<off + sz])
            let tail = UInt16(pkt[sz - 2]) | UInt16(pkt[sz - 1]) << 8
            if DJICRC.crc16(pkt[0..<sz - 2]) != tail { off += 1; continue }
            off += sz
            out.append(pkt)
        }
        buf.removeFirst(off)
        return out
    }
}

// MARK: - 发包

enum PacketBuilder {
    /// USB 发往接收器时第 5 字节是 0x5a，蓝牙直连发射器时是 0x3a。
    static func command(dst: UInt8, addr: UInt16, cmd: UInt8, val: UInt8, seq: UInt16) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 22)
        p[0] = 0x55
        p[1] = 0x16; p[2] = 0x04
        p[3] = DJICRC.crc8(p[0..<3])
        p[4] = 0x02; p[5] = dst
        p[6] = UInt8(seq & 0xff); p[7] = UInt8(seq >> 8)
        let body: [UInt8] = [0x40, 0x5b, 0x01, 0x02, UInt8(addr & 0xff), UInt8(addr >> 8), 0x00, 0x00, cmd, 0x00, 0x01, val]
        p.replaceSubrange(8..<20, with: body)
        let crc = DJICRC.crc16(p[0..<20])
        p[20] = UInt8(crc & 0xff); p[21] = UInt8(crc >> 8)
        return p
    }

    /// 旧款发射器（非 Mini 2S）蓝牙直连用的短格式。
    static func legacyCommand(dst: UInt8, cmd: UInt8, val: UInt8, seq: UInt16) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 19)
        p[0] = 0x55
        p[1] = 0x13; p[2] = 0x04
        p[3] = DJICRC.crc8(p[0..<3])
        p[4] = 0x02; p[5] = dst
        p[6] = UInt8(seq & 0xff); p[7] = UInt8(seq >> 8)
        p.replaceSubrange(8..<17, with: [0x40, 0x5b, 0x01, 0x00, 0x00, cmd, 0x00, 0x01, val])
        let crc = DJICRC.crc16(p[0..<17])
        p[17] = UInt8(crc & 0xff); p[18] = UInt8(crc >> 8)
        return p
    }

    /// 同步设备时钟。上游在每批设置写入前都先发一次，录音文件的时间戳依赖它。
    static func time(dst: UInt8, seq: UInt16, date: Date = Date()) -> [UInt8] {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        var p = [UInt8](repeating: 0, count: 29)
        p[0] = 0x55
        p[1] = 0x1d; p[2] = 0x04
        p[3] = DJICRC.crc8(p[0..<3])
        p[4] = 0x02; p[5] = dst
        p[6] = UInt8(seq & 0xff); p[7] = UInt8(seq >> 8)
        let body: [UInt8] = [
            0x40, 0x5b, 0x01, 0x02, 0x00, 0x00, 0x00, 0x00, 0x33, 0x00, 0x08, 0x09,
            UInt8(c.year! % 100), UInt8(c.month!), UInt8(c.day!),
            UInt8(c.hour!), UInt8(c.minute!), UInt8(c.second!), 0x00,
        ]
        p.replaceSubrange(8..<27, with: body)
        let crc = DJICRC.crc16(p[0..<27])
        p[27] = UInt8(crc & 0xff); p[28] = UInt8(crc >> 8)
        return p
    }
}

/// 状态包：第 10、11 字节为 0x5b 0x03，负载在头 11 字节之后、末尾 crc16 之前。
func statusPayload(_ pkt: [UInt8]) -> [UInt8]? {
    guard pkt.count >= 13, pkt[9] == 0x5b, pkt[10] == 0x03 else { return nil }
    return Array(pkt[11..<pkt.count - 2])
}

// MARK: - 协议适配（USB 接收器 / 蓝牙发射器）

protocol MicProtocol {
    /// 解析一个完整数据包并更新状态。
    func parse(_ pkt: [UInt8], into state: inout DeviceState)
    func rule(_ node: Node, _ key: String) -> Rule?
    /// 对应上游 valid(write=True)：字段可写且当前机型支持。
    func canWrite(_ node: Node, _ key: String, _ state: DeviceState) -> Bool
    func commandPacket(node: Node, cmd: UInt8, val: UInt8, seq: UInt16) -> [UInt8]
    func timePacket(seq: UInt16) -> [UInt8]?
    /// 设备名就绪后才允许写入（上游 apply() 的前置条件）。
    func isReady(_ state: DeviceState) -> Bool
    func initialState() -> DeviceState
}

struct USBProtocol: MicProtocol {
    static let rxRules: [Rule] = [
        Rule("deviceName",              0x01, 45, .vstr),
        Rule("addressSuffix",           0x01, 33, .fstr(6)),
        Rule("serialNumber",            0x01, 13, .fstr(14)),
        Rule("firmwareVersion",         0x01,  9, .ver(reversed: true)),
        Rule("batteryLevel",            0x03, 10, .bits(shift: 5, mask: 0x07), model: "!DJI Mic Mini 2"),
        Rule("charging",                0x03, 10, .bit(0x10), model: "!DJI Mic Mini 2"),
        Rule("stereo",                  0x03, 10, .bit(0x04), 0x08, .bl2),
        Rule("quadraphonic",            0x03, 10, .bit(0x08), 0x08, .bl4, "DJI Mic Mini 2S"),
        Rule("safetyTrack",             0x03, 37, .bit(0x40), 0x21, .bl1),
        Rule("gainControl",             0x03, 11, .i8,        0x39, .gain, "+DJI Mic Mini 2"),
        Rule("monitoringGain",          0x03, 16, .i8,        0x26, .gain1, "DJI Mic Mini 2"),
        Rule("clippingControl",         0x03, 37, .bit(0x10), 0x1e, .bl1),
        Rule("autoOff",                 0x03, 10, .bit(0x01), 0x10, .bl1, "!DJI Mic Mini 2"),
        Rule("receiverOnOffWithCamera", 0x03,  9, .bit(0x80), 0x20, .bl1, "!DJI Mic Mini 2"),
        Rule("plugFreeExternalSpeaker", 0x03, 37, .bit(0x02), 0x23, .bl1),
    ]

    static let txRules: [Rule] = [
        Rule("noiseCancellation",          0x03,  7, .bit(0x01), 0x38, .bl1, "-DJI Mic Mini 2"),
        Rule("noiseCancellationStrong",    0x03,  6, .bit(0x20), 0x37, .bl1, "-DJI Mic Mini 2"),
        Rule("noiseCancellationViaButton", 0x03,  6, .bit(0x80), 0x0f, .bl1, "!DJI Mic Mini 2"),
        Rule("lowCut",                     0x03,  9, .bit(0x20), 0x03, .bl1),
        Rule("clippingControl",            0x03,  8, .bit(0x04), 0x24, .bl1),
        Rule("loudnessBalance",            0x03, 11, .bit(0x80), 0x2c, .bl21),
        Rule("autoOff",                    0x03,  6, .bit(0x10), 0x10, .bl1),
        Rule("micLedOff",                  0x03,  6, .bit(0x02), 0x0a, .bl2),
    ]

    static let txiRules: [Rule] = [
        Rule("deviceName",                0x01, 42, .vstr),
        Rule("addressSuffix",             0x01, 30, .fstr(6)),
        Rule("serialNumber",              0x01, 10, .fstr(14)),
        Rule("firmwareVersion",           0x01,  6, .ver(reversed: true)),
        Rule("batteryLevel",              0x03,  7, .bits(shift: 2, mask: 0x07)),
        Rule("charging",                  0x03,  7, .bit(0x02)),
        Rule("inputLevel",                0x05,  6, .u8),
        Rule("recordingTimeTotal",        0x03, 14, .f16, model: "DJI Mic Mini 2S"),
        // 读出来是剩余录音时长；写 true 会发 cmd 0x07 = 格式化，删除发射器内全部录音。
        Rule("recordingTimeRemaining",    0x03, 16, .f16,       0x07, .bl1, "DJI Mic Mini 2S"),
        Rule("rec",                       0x03,  9, .bit(0x10), 0x02, .bl1, "DJI Mic Mini 2S"),
        Rule("transmitterGain",           0x03, 13, .i8,        0x39, .gain1, "DJI Mic Mini 2S"),
        Rule("voiceToneRich",             0x03,  9, .bit(0x40), 0x29, .bl1, "!DJI Mic Mini"),
        Rule("voiceToneBright",           0x03,  9, .bit(0x80), 0x29, .bl2, "!DJI Mic Mini"),
        Rule("fileOptionEditedFile",      0x03, 31, .bit(0x80), 0x3d, .bl2, "DJI Mic Mini 2S"),
        Rule("float32Recording",          0x03,  9, .bit(0x08), 0x0c, .bl1, "DJI Mic Mini 2S"),
        Rule("startupAutoRecording1",     0x03,  8, .bit(0x80), 0x2e, .bl1, "DJI Mic Mini 2S"),
        Rule("startupAutoRecording2s",    0x03, 31, .bit(0x10), 0x3e, .bl1, "DJI Mic Mini 2S"),
        Rule("autoRecordingWithReceiver", 0x03, 31, .bit(0x20), 0x3e, .bl2, "DJI Mic Mini 2S"),
        Rule("lowPowerAutoRecording",     0x03, 11, .bit(0x10), 0x2b, .bl1, "DJI Mic Mini 2S"),
        Rule("loopRecording",             0x03, 11, .bit(0x08), 0x2a, .bl1, "DJI Mic Mini 2S"),
        Rule("recStop",                   0x03, 11, .bit(0x20), 0x0b, .bl1, "DJI Mic Mini 2S"),
        Rule("vibration",                 0x03,  9, .bit(0x01), 0x04, .bl1, "DJI Mic Mini 2S"),
    ]

    static func rules(for node: Node) -> [Rule] {
        switch node {
        case .rx: return rxRules
        case .tx: return txRules
        default: return txiRules
        }
    }

    func rule(_ node: Node, _ key: String) -> Rule? {
        Self.rules(for: node).first { $0.key == key }
    }

    /// rx 和广播 tx 按接收器型号判断，单个发射器按它自己的型号判断。
    private func nodeName(_ node: Node, _ state: DeviceState) -> String? {
        let owner: Node = node.isIndividualTX ? node : .rx
        return state.value(owner, "deviceName")?.stringValue
    }

    func canWrite(_ node: Node, _ key: String, _ state: DeviceState) -> Bool {
        guard let r = rule(node, key), r.writable, state[node] != nil else { return false }
        return r.modelMatches(nodeName: nodeName(node, state), write: true)
    }

    func commandPacket(node: Node, cmd: UInt8, val: UInt8, seq: UInt16) -> [UInt8] {
        PacketBuilder.command(dst: 0x5a, addr: node.usbAddress, cmd: cmd, val: val, seq: seq)
    }

    func timePacket(seq: UInt16) -> [UInt8]? { PacketBuilder.time(dst: 0x5a, seq: seq) }

    func isReady(_ state: DeviceState) -> Bool { state.value(.rx, "deviceName") != nil }

    func initialState() -> DeviceState { DeviceState(nodes: [.rx: [:]]) }

    private static func txSlot(_ addr: UInt8) -> Node? {
        switch addr {
        case 0x01: return .tx1
        case 0x02: return .tx2
        case 0x04: return .tx3
        case 0x08: return .tx4
        default: return nil
        }
    }

    /// 在负载里找出 rx 和各个发射器的数据块基址。
    private func scan(_ d: [UInt8]) -> (typ: UInt8?, rx: Int?, tx: [Node: Int]) {
        let sz = d.count
        guard sz >= 4 else { return (nil, nil, [:]) }
        let typ = d[3]
        var tx: [Node: Int] = [:]
        switch typ {
        case 0x01 where sz >= 45:
            var i = 45 + Int(d[44])
            while i + 42 <= sz {
                if d[i] == 0x01, let n = Self.txSlot(d[i + 1]) { tx[n] = i }
                i += 42 + Int(d[i + 41])
            }
            return (typ, 0, tx)
        case 0x03 where sz >= 41:
            for i in stride(from: 41, to: sz - 31, by: 32) where d[i] == 0x02 {
                if let n = Self.txSlot(d[i + 1]) { tx[n] = i }
            }
            return (typ, 0, tx)
        case 0x05 where sz >= 10:
            for i in stride(from: 3, to: sz - 6, by: 7) where d[i] == 0x05 {
                if let n = Self.txSlot(d[i + 1]) { tx[n] = i }
            }
            return (typ, nil, tx)
        default:
            return (typ, nil, [:])
        }
    }

    private func read(_ node: Node, _ d: [UInt8], _ typ: UInt8, _ base: Int, _ state: inout DeviceState) {
        guard var obj = state[node] else { return }
        for r in Self.rules(for: node) {
            guard r.typ == typ, base + r.off < d.count else { continue }
            guard r.modelMatches(nodeName: nodeName(node, state), write: false) else { continue }
            obj[r.key] = r.decode.decode(d, base + r.off)
            // deviceName 先写回，后续同一包内的字段才能按新机型判断
            if r.key == "deviceName" { state[node] = obj }
        }
        state[node] = obj
    }

    func parse(_ pkt: [UInt8], into state: inout DeviceState) {
        guard let d = statusPayload(pkt) else { return }
        let blk = scan(d)
        guard let typ = blk.typ else { return }
        // 0x01/0x03 是全量块：没出现的发射器视为已断开
        let full = typ == 0x01 || typ == 0x03

        if let base = blk.rx { read(.rx, d, typ, base, &state) }

        for n in [Node.tx1, .tx2, .tx3, .tx4] {
            guard let base = blk.tx[n] else {
                if full { state[n] = nil }
                continue
            }
            if state[n] == nil { state[n] = [:] }
            read(n, d, typ, base, &state)
        }

        guard let first = [Node.tx1, .tx2, .tx3, .tx4].compactMap({ blk.tx[$0] }).first else {
            if full { state[.tx] = nil }
            return
        }
        if state[.tx] == nil { state[.tx] = [:] }
        read(.tx, d, typ, first, &state)
    }
}

struct BLEProtocol: MicProtocol {
    /// 广播名形如 "DJI Mic Mini 2S-ABCDEF"，最后一段是地址后缀。
    let deviceName: String
    let addressSuffix: String
    let isMini2S: Bool

    init(advertisedName: String) {
        let parts = advertisedName.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        deviceName = parts.count >= 2 ? parts.dropLast().joined(separator: "-") : ""
        addressSuffix = parts.count >= 2 ? parts.last! : ""
        isMini2S = deviceName.contains("Mini 2S")
    }

    static let legacyRules: [Rule] = [
        Rule("serialNumber",               0x01, 12, .vstr),
        Rule("firmwareVersion",            0x01,  7, .ver(reversed: false)),
        Rule("batteryLevel",               0x01,  4, .bits(shift: 2, mask: 0x07)),
        Rule("charging",                   0x01,  4, .bit(0x02)),
        Rule("noiseCancellationViaButton", 0x01,  3, .bit(0x80), 0x0f, .bl1),
        Rule("autoOff",                    0x01,  3, .bit(0x10), 0x10, .bl1),
        Rule("micLedOff",                  0x01,  6, .bit(0x80), 0x0a, .bl2),
    ]

    static let mini2SRules: [Rule] = [
        Rule("serialNumber",               0x01, 13, .fstr(14)),
        Rule("firmwareVersion",            0x01,  9, .ver(reversed: true)),
        Rule("batteryLevel",               0x02, 10, .bits(shift: 2, mask: 0x07)),
        Rule("charging",                   0x02, 10, .bit(0x02)),
        Rule("recordingTimeTotal",         0x02, 17, .f16),
        // 写 true = 格式化（删除全部录音），见 USBProtocol 同名字段
        Rule("recordingTimeRemaining",     0x02, 19, .f16,       0x07, .bl1),
        Rule("rec",                        0x02, 12, .bit(0x10), 0x02, .bl1),
        Rule("transmitterGain",            0x02, 16, .i8,        0x39, .gain1),
        Rule("voiceToneRich",              0x02, 12, .bit(0x40), 0x29, .bl1),
        Rule("voiceToneBright",            0x02, 12, .bit(0x80), 0x29, .bl2),
        Rule("fileOptionEditedFile",       0x02, 34, .bit(0x80), 0x3d, .bl2),
        Rule("float32Recording",           0x02, 12, .bit(0x08), 0x0c, .bl1),
        Rule("startupAutoRecording2s",     0x02, 34, .bit(0x10), 0x3e, .bl1),
        Rule("autoRecordingWithReceiver",  0x02, 34, .bit(0x20), 0x3e, .bl2),
        Rule("lowPowerAutoRecording",      0x02, 14, .bit(0x10), 0x2b, .bl1),
        Rule("loopRecording",              0x02, 14, .bit(0x08), 0x2a, .bl1),
        Rule("recStop",                    0x02, 14, .bit(0x20), 0x0b, .bl1),
        Rule("vibration",                  0x02, 12, .bit(0x01), 0x04, .bl1),
        Rule("noiseCancellation",          0x02, 10, .bit(0x01), 0x0e, .bl1),
        Rule("noiseCancellationStrong",    0x02,  9, .bit(0x20), 0x1d, .bl1),
        Rule("noiseCancellationViaButton", 0x02,  9, .bit(0x80), 0x0f, .bl1),
        Rule("lowCut",                     0x02, 12, .bit(0x20), 0x03, .bl1),
        Rule("clippingControl",            0x02, 11, .bit(0x04), 0x24, .bl1),
        Rule("loudnessBalance",            0x02, 14, .bit(0x80), 0x2c, .bl21),
        Rule("autoOff",                    0x02,  9, .bit(0x10), 0x10, .bl1),
        Rule("micLedOff",                  0x02,  9, .bit(0x02), 0x0a, .bl2),
    ]

    var rules: [Rule] { isMini2S ? Self.mini2SRules : Self.legacyRules }

    func rule(_ node: Node, _ key: String) -> Rule? {
        node == .tx ? rules.first { $0.key == key } : nil
    }

    func canWrite(_ node: Node, _ key: String, _ state: DeviceState) -> Bool {
        guard let r = rule(node, key), r.writable else { return false }
        return state[node] != nil
    }

    func commandPacket(node: Node, cmd: UInt8, val: UInt8, seq: UInt16) -> [UInt8] {
        isMini2S
            ? PacketBuilder.command(dst: 0x3a, addr: 0, cmd: cmd, val: val, seq: seq)
            : PacketBuilder.legacyCommand(dst: 0x3a, cmd: cmd, val: val, seq: seq)
    }

    /// 只有 Mini 2S 发射器（带内录）需要同步时钟。
    func timePacket(seq: UInt16) -> [UInt8]? {
        isMini2S ? PacketBuilder.time(dst: 0x3a, seq: seq) : nil
    }

    func isReady(_ state: DeviceState) -> Bool { state.value(.tx, "deviceName") != nil }

    func initialState() -> DeviceState {
        DeviceState(nodes: [.tx: ["deviceName": .string(deviceName), "addressSuffix": .string(addressSuffix)]])
    }

    func parse(_ pkt: [UInt8], into state: inout DeviceState) {
        guard let d = statusPayload(pkt), d.count >= 4, var obj = state[.tx] else { return }
        let typ = isMini2S ? d[3] : d[0]
        for r in rules where r.typ == typ && r.off < d.count {
            obj[r.key] = r.decode.decode(d, r.off)
        }
        state[.tx] = obj
    }
}

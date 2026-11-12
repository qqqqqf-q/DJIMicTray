import AppKit
import SwiftUI

// MARK: - 字段显示定义

/// 普通开关字段的显示名。声道模式、音色、增益和格式化有专门控件，不在这里。
private let toggleLabels: [Node: [(String, String)]] = {
    let rx: [(String, String)] = [
        ("safetyTrack", "安全音轨"),
        ("clippingControl", "防削波（Clipping Control）"),
        ("autoOff", "自动关机"),
        ("receiverOnOffWithCamera", "随相机开关机"),
        ("plugFreeExternalSpeaker", "免插拔外放（需重启）"),
    ]
    let tx: [(String, String)] = [
        ("noiseCancellation", "降噪"),
        ("noiseCancellationStrong", "降噪：强"),
        ("noiseCancellationViaButton", "按键切换降噪"),
        ("lowCut", "低切"),
        ("clippingControl", "自适应增益：防削波"),
        ("loudnessBalance", "自适应增益：响度均衡"),
        ("autoOff", "自动关机"),
        ("micLedOff", "关闭指示灯"),
    ]
    let txi: [(String, String)] = [
        ("float32Recording", "32-bit 浮点录音"),
        ("fileOptionEditedFile", "文件选项：Edited File"),
        ("startupAutoRecording1", "开机自动录音（Mobile / Mini RX）"),
        ("startupAutoRecording2s", "开机自动录音（Mini 2S RX）"),
        ("autoRecordingWithReceiver", "随接收器自动录音（Mini 2S RX）"),
        ("lowPowerAutoRecording", "低功耗自动录音（Mini 2S RX）"),
        ("loopRecording", "循环录音"),
        ("recStop", "REC Stop"),
        ("vibration", "振动"),
    ]
    return [.rx: rx, .tx: tx, .tx1: txi, .tx2: txi, .tx3: txi, .tx4: txi]
}()

/// 蓝牙直连时 tx 节点同时具备“全部发射器”和“单个发射器”的字段。
private func toggles(for node: Node, ble: Bool) -> [(String, String)] {
    if node == .tx && ble { return toggleLabels[.tx1]! + toggleLabels[.tx]! }
    return toggleLabels[node] ?? []
}

private func nodeTitle(_ node: Node) -> String {
    switch node {
    case .rx: return "接收器"
    case .tx: return "发射器"
    default: return "发射器 " + node.rawValue.dropFirst(2)
    }
}

// MARK: - 电量

/// 设备只上报 7 个档位（1 = 满，7 = 空），没有真实百分比。这里按档位等分折算成约数，仅用于显示。
private struct Battery {
    let percent: Int
    let charging: Bool

    init?(_ fields: NodeState) {
        guard let lvl = fields["batteryLevel"]?.intValue else { return nil }
        let bars = max(0, min(6, 7 - lvl))
        percent = Int((Double(bars) / 6 * 100).rounded())
        charging = fields["charging"]?.boolValue == true
    }

    var symbol: String {
        if charging { return "battery.100percent.bolt" }
        switch percent {
        case 84...: return "battery.100percent"
        case 60...: return "battery.75percent"
        case 40...: return "battery.50percent"
        case 15...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    var low: Bool { percent <= 17 && !charging }
    /// 最低一档只知道“快没电了”，写成 0% 会被误读成已经关机
    var text: String { percent == 0 ? "<15%" : "\(percent)%" }
}

// MARK: - 根视图

struct MenuView: View {
    @ObservedObject var mic: MicController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let err = mic.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch mic.phase {
            case .idle: DisconnectedView(mic: mic)
            case .connecting(let name):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在连接 \(name)…").font(.callout).foregroundStyle(.secondary)
                }
            case .connected(let kind): ConnectedView(mic: mic, ble: kind != .usb)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("DJI Mic").font(.headline)
                HStack(spacing: 5) {
                    Circle()
                        .fill(mic.isConnected ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(statusLine).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu {
                Toggle("登录时启动", isOn: Binding(get: { mic.launchAtLogin }, set: { mic.setLaunchAtLogin($0) }))
                Toggle("接收器插入时自动连接", isOn: $mic.autoConnectUSB)
                if mic.isConnected {
                    Divider()
                    Button("复制状态 JSON") { mic.copyStateJSON() }
                    Button("断开连接") { mic.disconnect() }
                }
                Divider()
                Button("退出 DJIMicTray") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var statusLine: String {
        switch mic.phase {
        case .idle: return "未连接"
        case .connecting: return "连接中"
        case .connected(.usb): return mic.isReady ? "已通过 USB 连接" : "USB 已连接，等待设备信息…"
        case .connected(.ble(let name)): return "已通过蓝牙连接 \(name)"
        }
    }
}

/// 面板里各分组共用的圆角底板。
private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 分组里的一行：左边名称，右边值或控件。
private struct Row<Trailing: View>: View {
    let label: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
            Spacer(minLength: 8)
            trailing
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(minHeight: 28)
    }
}

private struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).padding(.leading, 2)
    }
}

// MARK: - 未连接

private struct DisconnectedView: View {
    @ObservedObject var mic: MicController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                actionRow("通过 USB 连接接收器", "cable.connector") { mic.connectUSB() }
                actionRow(mic.bleScanning ? "停止扫描" : "扫描蓝牙发射器", "antenna.radiowaves.left.and.right",
                          busy: mic.bleScanning) {
                    mic.bleScanning ? mic.stopBluetoothScan() : mic.scanBluetooth()
                }
            }
            if !mic.bleDevices.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionTitle(text: "附近的发射器")
                    Card {
                        ForEach(mic.bleDevices) { d in
                            Button { mic.connectBluetooth(d) } label: {
                                Row(label: d.name) {
                                    Text("\(d.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else if mic.bleScanning {
                Text("发射器需要开机，并且没有被其它设备占用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func actionRow(_ title: String, _ symbol: String, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(Color.accentColor)
                Text(title)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 已连接

/// 顶部一排设备卡片同时充当总览（电量、是否在录音）和切换器，下面显示选中设备的全部参数和设置。
private struct ConnectedView: View {
    @ObservedObject var mic: MicController
    let ble: Bool
    @State private var picked: Node?

    /// 每台实际存在的设备一张卡片。USB 下 tx 节点代表“全部发射器”，它的设置并入各发射器页面，
    /// 只有在没有任何单个发射器节点时（蓝牙直连，或发射器都没开机）才单独成卡。
    private var devices: [Node] {
        let nodes = mic.state.nodes.keys.sorted()
        let individual = nodes.filter { $0 != .tx }
        if nodes.contains(.tx) && !individual.contains(where: \.isIndividualTX) { return individual + [.tx] }
        return individual
    }

    private var selected: Node? {
        if let picked, devices.contains(picked) { return picked }
        return devices.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(devices, id: \.self) { node in
                    DeviceTile(node: node, fields: mic.state[node] ?? [:], selected: node == selected)
                        .onTapGesture { picked = node }
                }
            }
            if let node = selected {
                ScrollView {
                    DeviceDetail(mic: mic, node: node, ble: ble)
                        .padding(.trailing, 2)
                }
                // ScrollView 的最小高度是 0，放进按内容定尺寸的弹窗里会被压没。
                // fixedSize 让它按内容高度上报，maxHeight 封顶，超出才滚动。
                .frame(maxHeight: 460)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct DeviceTile: View {
    let node: Node
    let fields: NodeState
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(nodeTitle(node))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if fields["rec"]?.boolValue == true {
                    Circle().fill(.red).frame(width: 6, height: 6).help("正在内录")
                }
            }
            if let b = Battery(fields) {
                HStack(spacing: 4) {
                    Image(systemName: b.symbol)
                    Text(b.text).monospacedDigit()
                }
                .font(.callout.weight(.semibold))
                .foregroundStyle(b.low ? Color.red : Color.primary)
            } else {
                Text("—").font(.callout.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor.opacity(selected ? 0.7 : 0), lineWidth: 1)
        }
        .contentShape(Rectangle())
    }
}

/// 选中设备的详情：只读参数在上，可改的设置在下。
private struct DeviceDetail: View {
    @ObservedObject var mic: MicController
    let node: Node
    let ble: Bool

    private var fields: NodeState { mic.state[node] ?? [:] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                if let name = fields["deviceName"]?.stringValue { info("型号", name) }
                Row(label: "电量") { batteryValue }
                if let lvl = fields["inputLevel"]?.intValue {
                    Row(label: "输入电平") { LevelMeter(level: lvl) }
                }
                if let rem = fields["recordingTimeRemaining"]?.doubleValue,
                   let total = fields["recordingTimeTotal"]?.doubleValue {
                    // 上游没有注明单位，原样显示数值
                    info("内录时长", String(format: "剩余 %.1f / 共 %.1f", rem, total))
                }
                if let fw = fields["firmwareVersion"]?.stringValue { info("固件", fw) }
                if let sn = fields["serialNumber"]?.stringValue, !sn.isEmpty { info("序列号", sn) }
                if let addr = fields["addressSuffix"]?.stringValue, !addr.isEmpty { info("配对地址", addr) }
            }

            SettingsGroup(mic: mic, node: node, ble: ble, title: "设置")
            // USB 下降噪、低切等是对全部发射器广播的，接收器只保存一份
            if node.isIndividualTX {
                SettingsGroup(mic: mic, node: .tx, ble: ble, title: "所有发射器共用")
            }
        }
    }

    @ViewBuilder private var batteryValue: some View {
        if let b = Battery(fields) {
            HStack(spacing: 5) {
                Image(systemName: b.symbol)
                Text((b.percent == 0 ? b.text : "约 \(b.text)") + (b.charging ? " · 充电中" : "")).monospacedDigit()
            }
            .foregroundStyle(b.low ? Color.red : Color.primary)
            .help("设备只上报 7 个电量档位，百分比按档位折算")
        } else {
            Text("此型号不上报电量").foregroundStyle(.secondary)
        }
    }

    private func info(_ label: String, _ value: String) -> some View {
        Row(label: label) {
            Text(value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
        }
    }
}

/// 输入电平条。设备上报 0–255 的原始值，上游没有给出满刻度，
/// 所以量程取“本次见过的最大值”，并设一个下限避免安静时小数值把条撑满。
private struct LevelMeter: View {
    let level: Int
    @State private var peak = 60

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(Color.green)
                        .frame(width: geo.size.width * CGFloat(min(level, peak)) / CGFloat(peak))
                        .animation(.linear(duration: 0.1), value: level)
                }
            }
            .frame(width: 120, height: 5)
            Text("\(level)").monospacedDigit().foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
        }
        .onChange(of: level) { _, new in peak = max(peak, new) }
    }
}

// MARK: - 设置

private struct SettingsGroup: View {
    @ObservedObject var mic: MicController
    let node: Node
    let ble: Bool
    let title: String

    private var editableToggles: [(String, String)] {
        toggles(for: node, ble: ble).filter { mic.canEdit(node, $0.0) }
    }

    private var hasContent: Bool {
        !editableToggles.isEmpty || channelEditable || voiceToneEditable
            || ["gainControl", "monitoringGain", "transmitterGain", "rec", "recordingTimeRemaining"].contains { mic.canEdit(node, $0) }
    }

    var body: some View {
        if hasContent {
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(text: title)
                Card {
                    if mic.canEdit(node, "rec") { recRow }
                    if channelEditable { channelRow }
                    if voiceToneEditable { voiceToneRow }
                    gainRow("gainControl", "增益", step: 6)
                    gainRow("monitoringGain", "监听增益", step: 1)
                    gainRow("transmitterGain", "发射器增益", step: 1)
                    ForEach(editableToggles, id: \.0) { key, label in
                        Row(label: label) {
                            Toggle(label, isOn: boolBinding(key))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                        }
                    }
                    if mic.canEdit(node, "recordingTimeRemaining") { formatRow }
                }
            }
        }
    }

    private func boolBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { mic.state.value(node, key)?.boolValue ?? false },
            set: { mic.set(node, key, .bool($0)) }
        )
    }

    // 内录

    private var recRow: some View {
        let on = mic.state.value(node, "rec")?.boolValue == true
        return Row(label: on ? "正在内录" : "内录") {
            Button(on ? "停止" : "开始录音") { mic.set(node, "rec", .bool(!on)) }
                .controlSize(.small)
                .tint(on ? .red : nil)
        }
    }

    // 声道：stereo 和 quadraphonic 共用命令 0x08（0 单声道 / 2 立体声 / 4 四声道），所以合成一个选择器

    private var channelEditable: Bool { node == .rx && mic.canEdit(.rx, "stereo") }

    private var channelRow: some View {
        let quadOK = mic.canEdit(.rx, "quadraphonic")
        let current = mic.state.value(.rx, "quadraphonic")?.boolValue == true ? 2
            : mic.state.value(.rx, "stereo")?.boolValue == true ? 1 : 0
        return Row(label: "声道") {
            Picker("声道", selection: Binding(get: { current }, set: { new in
                switch new {
                case 1: mic.set(.rx, "stereo", .bool(true))
                case 2: mic.set(.rx, "quadraphonic", .bool(true))
                default:
                    // 回到单声道：把当前生效的那个置 false，编码后都是 0x08 = 0
                    mic.set(.rx, current == 2 ? "quadraphonic" : "stereo", .bool(false))
                }
            })) {
                Text("单声道").tag(0)
                Text("立体声").tag(1)
                if quadOK { Text("四声道（需重启）").tag(2) }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
    }

    // 音色：voiceToneRich / voiceToneBright 共用命令 0x29（0 常规 / 1 浑厚 / 2 明亮）

    private var voiceToneEditable: Bool { mic.canEdit(node, "voiceToneRich") }

    private var voiceToneRow: some View {
        let current = mic.state.value(node, "voiceToneBright")?.boolValue == true ? 2
            : mic.state.value(node, "voiceToneRich")?.boolValue == true ? 1 : 0
        return Row(label: "音色") {
            Picker("音色", selection: Binding(get: { current }, set: { new in
                switch new {
                case 1: mic.set(node, "voiceToneRich", .bool(true))
                case 2: mic.set(node, "voiceToneBright", .bool(true))
                default: mic.set(node, current == 2 ? "voiceToneBright" : "voiceToneRich", .bool(false))
                }
            })) {
                Text("常规").tag(0)
                Text("浑厚").tag(1)
                Text("明亮").tag(2)
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
    }

    // 增益

    @ViewBuilder
    private func gainRow(_ key: String, _ label: String, step: Int) -> some View {
        if mic.canEdit(node, key), let v = mic.state.value(node, key)?.intValue {
            GainRow(label: label, value: v, step: step) { mic.set(node, key, .int($0)) }
        }
    }

    // 格式化：写 recordingTimeRemaining = true 即清空发射器内全部录音，必须二次确认

    private var formatRow: some View {
        Row(label: "内部存储") {
            Button("格式化…", role: .destructive) {
                let alert = NSAlert()
                alert.messageText = "格式化\(nodeTitle(node))？"
                alert.informativeText = "发射器里的全部录音会被立即删除，无法恢复。"
                alert.alertStyle = .critical
                alert.addButton(withTitle: "取消")
                alert.addButton(withTitle: "格式化")
                alert.buttons[1].hasDestructiveAction = true
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertSecondButtonReturn {
                    mic.set(node, "recordingTimeRemaining", .bool(true))
                }
            }
            .controlSize(.small)
        }
    }
}

/// 拖动时只更新显示，松手才发命令，避免一次拖动发出几十条写入。
private struct GainRow: View {
    let label: String
    let value: Int
    let step: Int
    let commit: (Int) -> Void
    @State private var draft: Double?

    var body: some View {
        Row(label: label) {
            Slider(value: Binding(get: { draft ?? Double(value) }, set: { draft = $0 }),
                   in: -12...12, step: Double(step)) { editing in
                if !editing, let d = draft {
                    commit(Int(d))
                    draft = nil
                }
            }
            .controlSize(.small)
            .frame(width: 130)
            Text(String(format: "%+d dB", Int(draft ?? Double(value))))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }
}

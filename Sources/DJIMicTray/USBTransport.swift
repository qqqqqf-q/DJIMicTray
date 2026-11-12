// USB 通道：经接收器（RX）读写整套设备（RX + 所有已配对 TX）。
//
// 接收器同时是 USB 声卡；控制协议走一个独立的厂商接口（Mobile RX 为 6 号，其它为 4 号，
// 端点号同接口号），不影响 macOS 对声卡部分的驱动。这里用 IOUSBHost 在用户态直接打开这个接口，
// 和上游 WebUSB / pyusb 的做法一致，不需要 libusb，也不需要替换驱动。

import Foundation
import IOKit
import IOKit.usb
import IOUSBHost

enum USBTransportError: LocalizedError {
    case notFound
    case multipleFound
    case open(String)

    var errorDescription: String? {
        switch self {
        case .notFound: return "没有找到通过 USB 连接的 DJI Mic 接收器"
        case .multipleFound: return "同时连接了多个接收器，请只保留一个"
        case .open(let msg): return "无法打开接收器的控制接口：\(msg)"
        }
    }
}

final class USBTransport {
    static let vendorID = 0x2ca3
    /// 0x4011 = DJI Mic Series Mobile Receiver，0x4015 / 0x4115 = Mini / Mini 2S Receiver
    static let productIDs = [0x4011, 0x4015, 0x4115]

    var onBytes: (([UInt8]) -> Void)?
    var onClose: ((Error?) -> Void)?

    private let queue = DispatchQueue(label: "DJIMicTray.usb")
    private var iface: IOUSBHostInterface?
    private var inPipe: IOUSBHostPipe?
    private var outPipe: IOUSBHostPipe?
    private var pendingWrites: [[UInt8]] = []
    private var writing = false
    private var closed = false

    /// 当前连接着的接收器的 product ID，打开前为 nil。
    private(set) var productID: Int?

    private static func interfaceNumber(for pid: Int) -> Int { pid == 0x4011 ? 6 : 4 }

    /// 枚举已连接的接收器控制接口。
    private static func findServices() -> [(io_service_t, Int)] {
        var result: [(io_service_t, Int)] = []
        for pid in productIDs {
            // 接口级匹配不能把 idVendor 等直接放在顶层：IOUSBHostInterface 只接受 USB 规范规定的
            // 键组合（如再加 bConfigurationValue），否则一个也匹配不到。放进 IOPropertyMatch 按属性逐一比较。
            let dict: NSMutableDictionary = [
                kIOProviderClassKey: "IOUSBHostInterface",
                kIOPropertyMatchKey: [
                    kUSBVendorID: vendorID,
                    kUSBProductID: pid,
                    kUSBInterfaceNumber: interfaceNumber(for: pid),
                ],
            ]
            var iter: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, dict as CFDictionary, &iter) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iter) }
            while case let s = IOIteratorNext(iter), s != 0 {
                result.append((s, pid))
            }
        }
        return result
    }

    static func isReceiverPresent() -> Bool {
        let services = findServices()
        services.forEach { IOObjectRelease($0.0) }
        return !services.isEmpty
    }

    func open() throws {
        let services = Self.findServices()
        defer { services.forEach { IOObjectRelease($0.0) } }
        guard let (service, pid) = services.first else { throw USBTransportError.notFound }
        guard services.count == 1 else { throw USBTransportError.multipleFound }

        let ifNum = Self.interfaceNumber(for: pid)
        do {
            let iface = try IOUSBHostInterface(__ioService: service, options: [], queue: queue) { [weak self] _, messageType, _ in
                // kIOMessageServiceIsTerminated：设备被拔出
                if messageType == 0xE0000010 {
                    self?.queue.async { self?.shutdown(error: nil) }
                }
            }
            // Mini / Mini 2S 接收器的控制端点在备用设置 1 上
            if pid != 0x4011 {
                try iface.selectAlternateSetting(1)
            }
            let inPipe = try iface.copyPipe(withAddress: 0x80 | ifNum)
            let outPipe = try iface.copyPipe(withAddress: ifNum)
            self.iface = iface
            self.inPipe = inPipe
            self.outPipe = outPipe
            self.productID = pid
        } catch {
            throw USBTransportError.open(error.localizedDescription)
        }
        queue.async { self.enqueueRead() }
    }

    private func enqueueRead() {
        guard !closed, let pipe = inPipe, let iface else { return }
        guard let data = try? iface.ioData(withCapacity: 1024) else {
            shutdown(error: USBTransportError.open("无法分配读缓冲"))
            return
        }
        do {
            // 超时必须为 0：如果端点是中断传输，IOUSBHost 不允许设置超时
            try pipe.enqueueIORequest(with: data, completionTimeout: 0) { [weak self] status, transferred in
                guard let self else { return }
                if status == kIOReturnSuccess {
                    if transferred > 0 {
                        let bytes = [UInt8](data.prefix(transferred))
                        DispatchQueue.main.async { self.onBytes?(bytes) }
                    }
                    self.enqueueRead()
                } else if status == kIOReturnAborted || self.closed
                            // 拔线时读请求可能先于“设备已移除”通知以这些错误码结束，属于正常断开
                            || [kIOReturnNoDevice, kIOReturnNotResponding, kIOReturnNotAttached, kIOReturnOffline].contains(status) {
                    self.shutdown(error: nil)
                } else {
                    self.shutdown(error: USBTransportError.open(String(format: "读取失败 (0x%08x)", status)))
                }
            }
        } catch {
            shutdown(error: error)
        }
    }

    func write(_ bytes: [UInt8]) {
        queue.async {
            self.pendingWrites.append(bytes)
            self.flushWrites()
        }
    }

    /// 逐包串行写出，包之间间隔 10ms，与上游 WebUSB 版一致。
    private func flushWrites() {
        guard !closed, !writing, !pendingWrites.isEmpty, let pipe = outPipe, let iface else { return }
        let bytes = pendingWrites.removeFirst()
        // ioData 缓冲区由内核内存支撑，长度固定等于容量，不能改 length（改了会直接抛异常）
        guard let data = try? iface.ioData(withCapacity: bytes.count) else { return }
        data.replaceBytes(in: NSRange(location: 0, length: bytes.count), withBytes: bytes)
        writing = true
        do {
            try pipe.enqueueIORequest(with: data, completionTimeout: 0) { [weak self] _, _ in
                guard let self else { return }
                self.queue.asyncAfter(deadline: .now() + 0.01) {
                    self.writing = false
                    self.flushWrites()
                }
            }
        } catch {
            writing = false
        }
    }

    func close() {
        queue.async { self.shutdown(error: nil) }
    }

    private func shutdown(error: Error?) {
        guard !closed else { return }
        closed = true
        pendingWrites.removeAll()
        try? inPipe?.__abort(with: .synchronous)
        try? outPipe?.__abort(with: .synchronous)
        iface?.destroy()
        iface = nil
        inPipe = nil
        outPipe = nil
        DispatchQueue.main.async { self.onClose?(error) }
    }
}

/// 监听接收器插拔，插入时回调，用于自动连接。
final class USBHotplugMonitor {
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private let onArrival: () -> Void

    init(onArrival: @escaping () -> Void) {
        self.onArrival = onArrival
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for pid in USBTransport.productIDs {
            let dict: NSMutableDictionary = [
                kIOProviderClassKey: "IOUSBHostDevice",
                kUSBVendorID: USBTransport.vendorID,
                kUSBProductID: pid,
            ]
            var iter: io_iterator_t = 0
            let kr = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, dict as CFDictionary, { refcon, iter in
                guard let refcon else { return }
                let monitor = Unmanaged<USBHotplugMonitor>.fromOpaque(refcon).takeUnretainedValue()
                var arrived = false
                while case let s = IOIteratorNext(iter), s != 0 {
                    IOObjectRelease(s)
                    arrived = true
                }
                // 设备刚枚举时接口还没就绪，稍等再连
                if arrived {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { monitor.onArrival() }
                }
            }, refcon, &iter)
            guard kr == KERN_SUCCESS else { continue }
            // 必须先清空一次迭代器才会开始接收后续通知；启动时已插着的设备由调用方自行处理
            while case let s = IOIteratorNext(iter), s != 0 { IOObjectRelease(s) }
            iterators.append(iter)
        }
    }

    deinit {
        iterators.forEach { IOObjectRelease($0) }
        if let port { IONotificationPortDestroy(port) }
    }
}

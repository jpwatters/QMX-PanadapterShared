// DriverEndpoint.swift - the virtual USB serial port (QMXSerialDriver.dext) as
// the bridge's serial endpoint: programs open /dev/cu.QMX-NAS like any USB
// serial adapter; this side talks to the driver through its user client.

import Foundation
import IOKit
import IOKit.serial

final class DriverEndpoint: SerialEndpoint {
    enum DriverError: Error, CustomStringConvertible {
        case notInstalled, open(kern_return_t), notify(kern_return_t)
        var description: String {
            switch self {
            case .notInstalled: return "the QMX serial driver is not running (install it from the Driver tab)"
            case .open(let r): return "can't open the QMX serial driver (IOServiceOpen 0x\(String(UInt32(bitPattern: r), radix: 16)))"
            case .notify(let r): return "the QMX serial driver refused notifications (0x\(String(UInt32(bitPattern: r), radix: 16)))"
            }
        }
    }

    struct Status {
        var portReady = false, open = false, queues = false
        var rxSize = 0, txSize = 0, rxDropped = 0, baud = 0, ringMode = 0
    }

    private var service: io_service_t = 0
    private var connect: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private let q = DispatchQueue(label: "qmx.driver")
    private var onData: ((Data) -> Void)?
    private var onOpen: ((Bool) -> Void)?
    private var asyncRef = [io_user_reference_t](repeating: 0, count: Int(kOSAsyncRef64Count))

    var displayPath: String { Self.calloutPath() ?? "/dev/cu.\(kQMXSerialTTYBaseName)" }

    /// The /dev/cu.* path the serial family gave our port, if it exists.
    static func calloutPath() -> String? {
        guard let match = IOServiceMatching(kIOSerialBSDServiceValue) else { return nil }
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var found: String?
        while case let s = IOIteratorNext(it), s != 0 {
            defer { IOObjectRelease(s) }
            if let p = IORegistryEntryCreateCFProperty(s, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String, p.contains(kQMXSerialTTYBaseName) {
                found = p
            }
        }
        return found
    }

    static func controlService() -> io_service_t {
        let match: NSDictionary = [kIOPropertyMatchKey: ["IOUserClass": kQMXBridgeControlClass]]
        return IOServiceGetMatchingService(kIOMainPortDefault, match as CFDictionary)
    }

    static var isDriverRunning: Bool {
        let s = controlService()
        if s != 0 { IOObjectRelease(s); return true }
        return false
    }

    func start(onData: @escaping (Data) -> Void, onOpen: @escaping (Bool) -> Void) throws {
        self.onData = onData
        self.onOpen = onOpen
        service = Self.controlService()
        guard service != 0 else { throw DriverError.notInstalled }
        let r = IOServiceOpen(service, mach_task_self_, UInt32(kQMXBridgeUserClientType), &connect)
        guard r == KERN_SUCCESS else { IOObjectRelease(service); service = 0; throw DriverError.open(r) }

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { throw DriverError.notify(kIOReturnNoMemory) }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, q)
        let callback: IOAsyncCallback = { refcon, result, args, numArgs in
            guard let refcon = refcon else { return }
            let me = Unmanaged<DriverEndpoint>.fromOpaque(refcon).takeUnretainedValue()
            var vals: [UInt64] = []
            if let a = args {
                for i in 0..<Int(numArgs) { vals.append(UInt64(UInt(bitPattern: a[i]))) }
            }
            me.event(vals)
        }
        asyncRef[Int(kIOAsyncCalloutFuncIndex)] = io_user_reference_t(UInt(bitPattern: unsafeBitCast(callback, to: UnsafeRawPointer.self)))
        asyncRef[Int(kIOAsyncCalloutRefconIndex)] = io_user_reference_t(UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque()))
        var outCnt: UInt32 = 0
        let nr = IOConnectCallAsyncScalarMethod(connect, UInt32(kQMXMethodNotify), IONotificationPortGetMachPort(port),
                                                &asyncRef, UInt32(kOSAsyncRef64Count), nil, 0, nil, &outCnt)
        guard nr == KERN_SUCCESS else { throw DriverError.notify(nr) }
        let st = status()
        if st.open { onOpen(true) }
        q.async { self.drain() }       // anything written before we connected
    }

    private func event(_ v: [UInt64]) {
        guard let e = v.first else { return }
        switch Int(e) {
        case kQMXEventTxData: drain()
        case kQMXEventOpen: onOpen?(true)
        case kQMXEventClose: onOpen?(false)
        case kQMXEventMCR: logD("port: DTR \(v.count > 1 && v[1] & 1 != 0 ? "on" : "off"), RTS \(v.count > 1 && v[1] & 2 != 0 ? "on" : "off")")
        case kQMXEventQueues: logD("port: rings \(v.count > 1 && v[1] != 0 ? "connected" : "disconnected")")
        default: break
        }
    }

    /// Pull everything the program wrote.
    private func drain() {
        guard connect != 0 else { return }
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            var size = buf.count
            let r = IOConnectCallStructMethod(connect, UInt32(kQMXMethodRead), nil, 0, &buf, &size)
            if r != KERN_SUCCESS || size == 0 { break }
            onData?(Data(buf[0..<size]))
        }
    }

    func write(_ data: Data) {
        guard connect != 0 else { return }
        var off = 0
        while off < data.count {
            let chunk = data.subdata(in: off..<min(off + 4096, data.count))
            var accepted: UInt64 = 0
            var outCnt: UInt32 = 1
            let r = chunk.withUnsafeBytes { p in
                IOConnectCallMethod(connect, UInt32(kQMXMethodWrite), nil, 0, p.baseAddress, chunk.count,
                                    &accepted, &outCnt, nil, nil)
            }
            if r != KERN_SUCCESS {
                logW("serial driver write failed (0x\(String(UInt32(bitPattern: r), radix: 16)))")
                return
            }
            if Int(accepted) < chunk.count {
                logW("serial port full or closed (nothing reading it): dropped \(chunk.count - Int(accepted)) bytes")
                return
            }
            off += chunk.count
        }
    }

    func flushStale() {
        guard connect != 0 else { return }
        _ = IOConnectCallScalarMethod(connect, UInt32(kQMXMethodFlushRx), nil, 0, nil, nil)
    }

    func setRingMode(_ mode: Int) {
        guard connect != 0 else { return }
        var v = UInt64(mode)
        _ = IOConnectCallScalarMethod(connect, UInt32(kQMXMethodSetRingMode), &v, 1, nil, nil)
    }

    func status() -> Status {
        var s = Status()
        guard connect != 0 else { return s }
        var out = [UInt64](repeating: 0, count: Int(kQMXStatCount))
        var n = UInt32(kQMXStatCount)
        guard IOConnectCallScalarMethod(connect, UInt32(kQMXMethodStatus), nil, 0, &out, &n) == KERN_SUCCESS else { return s }
        s.portReady = out[Int(kQMXStatPortReady)] != 0
        s.open = out[Int(kQMXStatOpen)] != 0
        s.queues = out[Int(kQMXStatQueues)] != 0
        s.rxSize = Int(out[Int(kQMXStatRxSize)])
        s.txSize = Int(out[Int(kQMXStatTxSize)])
        s.rxDropped = Int(out[Int(kQMXStatRxDropped)])
        s.baud = Int(out[Int(kQMXStatBaud)])
        s.ringMode = Int(out[Int(kQMXStatRingMode)])
        return s
    }

    func stop() {
        if connect != 0 { IOServiceClose(connect); connect = 0 }
        if let p = notifyPort { IONotificationPortDestroy(p); notifyPort = nil }
        if service != 0 { IOObjectRelease(service); service = 0 }
    }
}

// SerialBridge.swift - the QMX on the NAS as a serial port on this Mac.
//
//   QMX --USB--> NAS relay --TCP 7356 (QMX serial port 3, raw bytes)--> this app
//       --> a serial device on the Mac: the QMX Bridge virtual USB serial port
//           (DriverKit driver), or a pseudo-terminal linked at ~/cu.QMX-NAS.
//
// Same behaviour as qmx_serial_bridge.py: connects to the relay only when a
// program talks to the port, releases it after `idle` seconds of silence, drops
// commands (and retries) while the radio is unreachable, bytes pass unchanged.

import Foundation

/// The Mac side of the bridge: something programs open as a serial port.
protocol SerialEndpoint: AnyObject {
    /// Human-readable path, e.g. /dev/cu.QMX-NAS or ~/cu.QMX-NAS -> /dev/ttys012
    var displayPath: String { get }
    /// Start delivering what programs write (onData) and open/close events.
    func start(onData: @escaping (Data) -> Void, onOpen: @escaping (Bool) -> Void) throws
    /// Bytes from the radio, for the program.
    func write(_ data: Data)
    /// Throw away radio bytes no program has read yet.
    func flushStale()
    func stop()
}

final class SerialBridge {
    static let connectTimeout = 3.0
    static let retryAfter = 3.0
    static let quickClose = 1.5

    let settings: BridgeSettings
    let endpoint: SerialEndpoint
    let locator: RelayLocator
    private let q = DispatchQueue(label: "qmx.serial-bridge")
    private var sock: TCPSocket?
    private var connectedAt = Date.distantPast
    private var gotReply = false
    private var lastTraffic = Date.distantPast
    private var retryAt = Date.distantPast
    private var droppedNote = Date.distantPast
    private var timer: DispatchSourceTimer?
    private(set) var running = false

    /// Called on the main queue when the relay connection changes.
    var onState: ((_ relayConnected: Bool, _ host: String?) -> Void)?

    init(settings: BridgeSettings, endpoint: SerialEndpoint) {
        self.settings = settings
        self.endpoint = endpoint
        self.locator = RelayLocator(settings: settings)
    }

    func start() throws {
        try endpoint.start(onData: { [weak self] d in self?.onPortData(d) },
                           onOpen: { [weak self] open in self?.onPortOpen(open) })
        running = true
        logI("serial port ready: \(endpoint.displayPath)")
        q.async {
            if self.locator.searching { self.locator.find() }
            let mode = self.settings.keepConnected ? "kept connected"
                : self.settings.idle > 0 ? "connects on demand, releases after \(self.settings.idle)s idle"
                : "connects on demand, stays connected"
            logI("relay: \(self.locator.host ?? "(not found yet)"):\(self.settings.port)   \(mode)")
            self.notify()
        }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        running = false
        timer?.cancel()
        timer = nil
        q.sync { disconnect("stopping") }
        endpoint.stop()
    }

    private func notify() {
        let c = sock != nil, h = locator.host
        DispatchQueue.main.async { self.onState?(c, h) }
    }

    // MARK: - relay

    private func connect() -> Bool {
        if locator.host == nil && !(locator.searching && locator.find()) {
            retryAt = Date().addingTimeInterval(Self.retryAfter)
            return false
        }
        guard let host = locator.host else { return false }
        do {
            let s = try TCPSocket.connect(host: host, port: settings.port, timeout: Self.connectTimeout)
            sock = s
            connectedAt = Date(); lastTraffic = connectedAt
            gotReply = false
            endpoint.flushStale()
            logI("connected to the relay \(host):\(settings.port) (QMX serial port 3)")
            let th = Thread { [weak self] in self?.reader(s) }
            th.name = "relay-rx"
            th.start()
            notify()
            return true
        } catch {
            logW("can't reach the relay at \(host):\(settings.port): \(error)")
            if let e = (error as? NetError)?.errno, e == EHOSTUNREACH || e == ENETUNREACH || e == EPERM {
                logW("if this Mac is on the NAS's network, check System Settings -> Privacy & Security -> Local Network allows QMX Bridge")
            }
            let old = locator.host
            if locator.searching && locator.find() && locator.host != old {
                return connect()      // the NAS moved: try its new address once
            }
            retryAt = Date().addingTimeInterval(Self.retryAfter)
            return false
        }
    }

    private func disconnect(_ why: String) {
        if let s = sock {
            s.close()
            sock = nil
            logI("released the relay: \(why)")
            notify()
        }
    }

    private func reader(_ s: TCPSocket) {
        var why = "relay closed the connection (QMX off or relay restarted)"
        while true {
            do {
                let d = try s.recv(max: 4096)
                if d.isEmpty { break }
                q.async { if self.sock === s { self.gotReply = true; self.lastTraffic = Date() } }
                logD("radio -> port: \(d.logText())")
                endpoint.write(d)
            } catch {
                why = "connection lost: \(error)"
                break
            }
        }
        q.async {
            guard self.sock === s else { return }
            if !self.quickCloseCheck() { self.disconnect(why) }
        }
    }

    /// The relay drops port 3 at once when the radio can't serve it.
    private func quickCloseCheck() -> Bool {
        if !gotReply && Date().timeIntervalSince(connectedAt) < Self.quickClose {
            logW("the relay closed port 3 straight away. Is the QMX on, and is 'USB serial ports' set to 3 on the radio? (see the relay's log)")
            retryAt = Date().addingTimeInterval(Self.retryAfter)
            disconnect("port 3 refused")
            return true
        }
        return false
    }

    // MARK: - port side

    private func onPortData(_ d: Data) {
        q.async {
            logD("port -> radio: \(d.logText())")
            let now = Date()
            if self.sock == nil {
                if now < self.retryAt || !self.connect() {
                    if now.timeIntervalSince(self.droppedNote) > 30 {
                        logI("radio not reachable: dropping commands (retrying)")
                        self.droppedNote = now
                    }
                    return
                }
            }
            self.lastTraffic = now
            do { try self.sock?.sendAll(d) } catch { self.disconnect("send failed: \(error)") }
        }
    }

    private func onPortOpen(_ open: Bool) {
        logI(open ? "a program opened the serial port" : "the program closed the serial port")
    }

    private func tick() {
        let now = Date()
        if settings.keepConnected && sock == nil && now >= retryAt { _ = connect() }
        if sock != nil && settings.idle > 0 && !settings.keepConnected &&
            now.timeIntervalSince(lastTraffic) > Double(settings.idle) {
            disconnect("idle for \(settings.idle)s")
            endpoint.flushStale()
        }
    }
}

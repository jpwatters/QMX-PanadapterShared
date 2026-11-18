// Discovery.swift - find the NAS relay the same way the Tab5's Find NAS does:
// broadcast "QMXR?" on UDP 7355 and collect "QMXR! <ip> <tcp port>" answers.

import Foundation
import Darwin

struct Relay: Hashable, CustomStringConvertible {
    let ip: String
    let port: Int
    var description: String { "QMXR! \(ip) \(port)" }
}

struct BridgeSettings: Codable, Equatable {
    var host: String = ""            // empty = find it with QMXR?
    var fallbackHost: String = ""
    var discoveryPort: Int = 7355
    var port: Int = 7356             // relay: QMX serial port 3, raw bytes
    var iqPort: Int = 7357           // relay: listen-only copy of the I/Q
    var idle: Int = 120              // seconds; 0 = never release
    var keepConnected: Bool = false
    var linkPath: String = "~/cu.QMX-NAS"
    var tciListen: String = "127.0.0.1"
    var tciPort: Int = 40001
    var verbose: Bool = false

    var fixedHost: String? { host.trimmingCharacters(in: .whitespaces).isEmpty ? nil : host.trimmingCharacters(in: .whitespaces) }
    var fallback: String? { fallbackHost.trimmingCharacters(in: .whitespaces).isEmpty ? nil : fallbackHost.trimmingCharacters(in: .whitespaces) }

    static let key = "BridgeSettings"
    static func load() -> BridgeSettings {
        if let d = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode(BridgeSettings.self, from: d) { return s }
        return BridgeSettings()
    }
    func save() { if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) } }
}

enum Discovery {
    static let time = 1.5            // "QMXR?" is sent 3 times in this window, like the Tab5
    static let query = "QMXR?"
    static let reply = "QMXR!"

    /// 255.255.255.255 plus each up interface's own broadcast address. A Mac sends
    /// 255.255.255.255 out of one interface only, so with Wi-Fi and Ethernet both up
    /// the directed addresses make sure the NAS's network is asked too.
    static func broadcastAddresses() -> [String] {
        var out = ["255.255.255.255"]
        var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0 else { return out }
        defer { freeifaddrs(ifa) }
        var p = ifa
        while let i = p {
            let f = Int32(i.pointee.ifa_flags)
            if let a = i.pointee.ifa_addr, a.pointee.sa_family == sa_family_t(AF_INET),
               f & IFF_UP != 0, f & IFF_BROADCAST != 0, f & IFF_LOOPBACK == 0,
               let b = i.pointee.ifa_dstaddr {     // ifa_broadaddr == ifa_dstaddr on BSD
                var sin = sockaddr_in()
                memcpy(&sin, b, MemoryLayout<sockaddr_in>.size)
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
                let s = String(cString: buf)
                if !s.isEmpty, s != "0.0.0.0", !out.contains(s) { out.append(s) }
            }
            p = i.pointee.ifa_next
        }
        return out
    }

    /// Ask the network for QMX relays; distinct answers in arrival order.
    static func discover(udpPort: Int = 7355, timeout: Double = time) -> [Relay] {
        let targets = broadcastAddresses()
        var found: [Relay] = []
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if fd < 0 { logW("discovery: socket failed: \(String(cString: strerror(errno)))"); return found }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let start = Date()
        var sent = 0
        let q = Array(query.utf8)
        while Date().timeIntervalSince(start) < timeout {
            let el = Date().timeIntervalSince(start)
            if sent < 3 && el >= Double(sent) * timeout / 3 {
                for t in targets {
                    var to = sockaddr_in()
                    to.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    to.sin_family = sa_family_t(AF_INET)
                    to.sin_port = in_port_t(UInt16(udpPort).bigEndian)
                    inet_pton(AF_INET, t, &to.sin_addr)
                    let r = withUnsafePointer(to: &to) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, q, q.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                    if r < 0 { logD("discovery: send to \(t) failed: \(String(cString: strerror(errno)))") }
                }
                sent += 1
            }
            var buf = [UInt8](repeating: 0, count: 256)
            var peer = sockaddr_in()
            var plen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, 256, 0, $0, &plen) }
            }
            if n <= 0 { continue }
            let parts = String(decoding: buf[0..<n], as: UTF8.self).split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }).map(String.init)
            guard parts.first == reply else { continue }
            var ip = parts.count > 1 ? parts[1] : ""
            var tmp = in_addr()
            if ip.split(separator: ".").count != 4 || inet_pton(AF_INET, ip, &tmp) != 1 {
                var pb = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &peer.sin_addr, &pb, socklen_t(INET_ADDRSTRLEN))
                ip = String(cString: pb)
            }
            var port = parts.count > 2 ? Int(parts[2]) ?? 7355 : 7355
            if !(1..<65536).contains(port) { port = 7355 }
            let r = Relay(ip: ip, port: port)
            if !found.contains(r) { found.append(r) }
        }
        return found
    }
}

/// Where the relay is: a fixed address, or found by QMXR? (with a fallback),
/// asked again at most every 3 s.
final class RelayLocator {
    private let settings: BridgeSettings
    private(set) var host: String?
    private var searchedAt = Date.distantPast
    private let lock = NSLock()

    init(settings: BridgeSettings) {
        self.settings = settings
        host = settings.fixedHost
    }

    var searching: Bool { settings.fixedHost == nil }

    /// Search (if allowed now); true if a host is known afterwards.
    @discardableResult
    func find() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !searching { return host != nil }
        if Date().timeIntervalSince(searchedAt) < 3 { return host != nil }
        searchedAt = Date()
        let found = Discovery.discover(udpPort: settings.discoveryPort)
        if let f = found.first {
            if f.ip != host { logI("found the NAS relay: \(f) - using \(f.ip):\(settings.port) for QMX port 3") }
            if found.count > 1 { logI("other relays answered too (using the first): \(found.dropFirst().map { "\($0.ip):\($0.port)" }.joined(separator: ", "))") }
            host = f.ip
            return true
        }
        if let fb = settings.fallback {
            if host != fb { logW("no relay answered QMXR? on UDP \(settings.discoveryPort); using the fallback \(fb)") }
            host = fb
            return true
        }
        logW("no relay answered QMXR? on UDP \(settings.discoveryPort) (is the relay running, and the Mac on the same network as the NAS?)")
        return host != nil
    }

    /// The host, searching first if none is known yet.
    func current() -> String? {
        if host == nil { find() }
        return host
    }
}

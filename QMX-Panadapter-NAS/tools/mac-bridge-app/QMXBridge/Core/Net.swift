// Net.swift - small blocking BSD-socket helpers (the bridge runs on its own
// threads, like the Python version, so plain sockets keep the port simple).

import Foundation
import Darwin

enum NetError: Error, CustomStringConvertible {
    case resolve(String)
    case sys(String, Int32)
    case timeout(String)
    case closed

    var description: String {
        switch self {
        case .resolve(let h): return "can't resolve \(h)"
        case .sys(let what, let e): return "\(what): \(String(cString: strerror(e)))"
        case .timeout(let what): return "\(what): timed out"
        case .closed: return "connection closed"
        }
    }

    var errno: Int32? { if case .sys(_, let e) = self { return e }; return nil }
}

/// A connected TCP socket.
final class TCPSocket {
    let fd: Int32
    private var closedFlag = false
    private let lock = NSLock()

    init(fd: Int32) { self.fd = fd }
    deinit { close() }

    /// Connect to host:port with a timeout (seconds).
    static func connect(host: String, port: Int, timeout: Double) throws -> TCPSocket {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        if inet_pton(AF_INET, host, &addr.sin_addr) != 1 {
            // not a dotted quad: resolve
            var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                                 ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var res: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &res) == 0, let r = res, let sa = r.pointee.ai_addr else {
                throw NetError.resolve(host)
            }
            sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { addr.sin_addr = $0.pointee.sin_addr }
            freeaddrinfo(res)
        }
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        if fd < 0 { throw NetError.sys("socket", Darwin.errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            let e = Darwin.errno
            if e != EINPROGRESS { Darwin.close(fd); throw NetError.sys("connect \(host):\(port)", e) }
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let n = poll(&p, 1, Int32(timeout * 1000))
            if n <= 0 { Darwin.close(fd); throw NetError.timeout("connect \(host):\(port)") }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            if err != 0 { Darwin.close(fd); throw NetError.sys("connect \(host):\(port)", err) }
        }
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, socklen_t(MemoryLayout<Int32>.size))
        return TCPSocket(fd: fd)
    }

    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closedFlag }

    func close() {
        lock.lock()
        if !closedFlag {
            closedFlag = true
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        lock.unlock()
    }

    /// Receive timeout for blocking reads; 0 = none.
    func setReadTimeout(_ seconds: Double) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1e6))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func sendAll(_ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var p = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let n = Darwin.send(fd, p, left, 0)
                if n < 0 {
                    if Darwin.errno == EINTR { continue }
                    throw NetError.sys("send", Darwin.errno)
                }
                p += n
                left -= n
            }
        }
    }

    func sendAll(_ s: String) throws { try sendAll(Data(s.utf8)) }

    /// Up to `max` bytes; empty Data = peer closed. Throws on error or timeout.
    func recv(max: Int = 4096) throws -> Data {
        var buf = [UInt8](repeating: 0, count: max)
        while true {
            let n = Darwin.recv(fd, &buf, max, 0)
            if n >= 0 { return Data(buf[0..<n]) }
            let e = Darwin.errno
            if e == EINTR { continue }
            if e == EAGAIN || e == EWOULDBLOCK { throw NetError.timeout("recv") }
            throw NetError.sys("recv", e)
        }
    }

    func recvExact(_ n: Int) throws -> Data {
        var out = Data()
        out.reserveCapacity(n)
        while out.count < n {
            let c = try recv(max: n - out.count)
            if c.isEmpty { throw NetError.closed }
            out.append(c)
        }
        return out
    }
}

/// A listening TCP socket.
final class TCPListener {
    let fd: Int32

    init(address: String, port: Int) throws {
        fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        if fd < 0 { throw NetError.sys("socket", Darwin.errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        if inet_pton(AF_INET, address, &addr.sin_addr) != 1 { addr.sin_addr.s_addr = INADDR_ANY }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 { let e = Darwin.errno; Darwin.close(fd); throw NetError.sys("bind \(address):\(port)", e) }
        if listen(fd, 4) != 0 { let e = Darwin.errno; Darwin.close(fd); throw NetError.sys("listen", e) }
    }

    /// Blocks; returns nil once the listener is closed.
    func accept() -> (TCPSocket, String)? {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let c = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(fd, $0, &len) }
        }
        if c < 0 { return nil }
        var one: Int32 = 1
        setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr.sin_addr, &ip, socklen_t(INET_ADDRSTRLEN))
        return (TCPSocket(fd: c), "\(String(cString: ip)):\(UInt16(bigEndian: addr.sin_port))")
    }

    func close() {
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}

/// QMXR/1 frame header: type, flags, little-endian length.
enum QMXR {
    static let hello: UInt8 = 1, iq: UInt8 = 2, cat: UInt8 = 3, ping: UInt8 = 4

    static func frame(_ type: UInt8, _ payload: Data) -> Data {
        var d = Data([type, 0, UInt8(payload.count & 0xFF), UInt8((payload.count >> 8) & 0xFF)])
        d.append(payload)
        return d
    }

    static func readFrame(_ s: TCPSocket) throws -> (UInt8, Data) {
        let h = try s.recvExact(4)
        let n = Int(h[h.startIndex + 2]) | (Int(h[h.startIndex + 3]) << 8)
        return (h[h.startIndex], n > 0 ? try s.recvExact(n) : Data())
    }
}

extension Data {
    /// ASCII view for logs, shortened.
    func logText(_ n: Int = 60) -> String {
        let s = String(decoding: self, as: UTF8.self)
        return s.count <= n ? s : String(s.prefix(n)) + "..."
    }
}

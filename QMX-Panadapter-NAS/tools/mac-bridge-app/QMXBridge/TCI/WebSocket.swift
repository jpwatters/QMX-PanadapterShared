// WebSocket.swift - minimal server side of RFC 6455: text, binary, ping/pong, close.

import Foundation
import CommonCrypto

final class WebSocket {
    enum Message { case text(String), binary(Data) }
    struct Closed: Error { let why: String }

    private let sock: TCPSocket
    private let sendLock = NSLock()
    private(set) var alive = true
    private var fragOp: UInt8?
    private var frag = Data()
    private var pending = Data()      // bytes read past the handshake

    init(sock: TCPSocket) { self.sock = sock }

    static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// Read the HTTP upgrade request and answer it.
    func handshake() -> Bool {
        sock.setReadTimeout(5)
        var req = Data()
        let end = Data("\r\n\r\n".utf8)
        while req.range(of: end) == nil {
            guard let c = try? sock.recv(max: 4096), !c.isEmpty else { return false }
            req.append(c)
            if req.count > 16384 { return false }
        }
        let r = req.range(of: end)!
        pending = req.subdata(in: r.upperBound..<req.endIndex)
        let head = String(decoding: req[..<r.lowerBound], as: UTF8.self)
        var key: String?
        for line in head.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "sec-websocket-key" {
                key = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        guard let k = key else {
            try? sock.sendAll("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
            return false
        }
        let accept = Self.sha1Base64(k + Self.guid)
        do {
            try sock.sendAll("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n")
        } catch { return false }
        sock.setReadTimeout(0)
        return true
    }

    static func sha1Base64(_ s: String) -> String {
        let d = Data(s.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        d.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(d.count), &digest) }
        return Data(digest).base64EncodedString()
    }

    private func recvExact(_ n: Int) throws -> Data {
        var out = Data()
        if !pending.isEmpty {
            let take = min(n, pending.count)
            out.append(pending.prefix(take))
            pending = pending.dropFirst(take).subdataCopy()
        }
        do {
            if out.count < n { out.append(try sock.recvExact(n - out.count)) }
        } catch {
            throw Closed(why: "\(error)")
        }
        return out
    }

    /// Next complete message.
    func recv() throws -> Message {
        while true {
            let h = try recvExact(2)
            let b0 = h[h.startIndex], b1 = h[h.startIndex + 1]
            let fin = b0 & 0x80 != 0, op = b0 & 0x0F
            var n = Int(b1 & 0x7F)
            if n == 126 {
                let e = try recvExact(2)
                n = Int(e[e.startIndex]) << 8 | Int(e[e.startIndex + 1])
            } else if n == 127 {
                let e = try recvExact(8)
                n = e.reduce(0) { $0 << 8 | Int($1) }
            }
            let mask: [UInt8]? = b1 & 0x80 != 0 ? Array(try recvExact(4)) : nil
            var data = n > 0 ? try recvExact(n) : Data()
            if let m = mask {
                data.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) in
                    for i in 0..<p.count { p[i] ^= m[i & 3] }
                }
            }
            switch op {
            case 0x8:
                close(1000)
                throw Closed(why: "close frame")
            case 0x9:
                try send(0xA, data)
            case 0xA:
                continue
            case 0x1, 0x2:
                if fin { return op == 1 ? .text(String(decoding: data, as: UTF8.self)) : .binary(data) }
                fragOp = op
                frag = data
            case 0x0:
                guard let fo = fragOp else { continue }
                frag.append(data)
                if fin {
                    fragOp = nil
                    let d = frag
                    frag = Data()
                    return fo == 1 ? .text(String(decoding: d, as: UTF8.self)) : .binary(d)
                }
            default:
                continue
            }
        }
    }

    private func send(_ op: UInt8, _ data: Data) throws {
        var h = Data([0x80 | op])
        let n = data.count
        if n < 126 {
            h.append(UInt8(n))
        } else if n < 65536 {
            h.append(contentsOf: [126, UInt8(n >> 8), UInt8(n & 0xFF)])
        } else {
            h.append(127)
            for i in (0..<8).reversed() { h.append(UInt8((n >> (8 * i)) & 0xFF)) }
        }
        h.append(data)
        sendLock.lock(); defer { sendLock.unlock() }
        guard alive else { throw Closed(why: "closed") }
        do { try sock.sendAll(h) } catch {
            alive = false
            throw Closed(why: "\(error)")
        }
    }

    func sendText(_ s: String) throws { try send(0x1, Data(s.utf8)) }
    func sendBinary(_ d: Data) throws { try send(0x2, d) }

    func close(_ code: UInt16 = 1000) {
        try? send(0x8, Data([UInt8(code >> 8), UInt8(code & 0xFF)]))
        sendLock.lock(); alive = false; sendLock.unlock()
        sock.close()
    }

    func markDead() { sendLock.lock(); alive = false; sendLock.unlock() }
}

private extension Data {
    func subdataCopy() -> Data { Data(self) }
}

// Probe.swift - one-off check through the relay: read-only CAT queries
// (ID; FA; MD;) on port 3 and the I/Q copy's hello. Never transmits.

import Foundation

enum Probe {
    struct Result {
        var lines: [String] = []
        var passed = false
    }

    static func run(settings: BridgeSettings, requireIQ: Bool = false) -> Result {
        var r = Result()
        func say(_ s: String) { r.lines.append(s); logI("probe: " + s) }
        var host = settings.fixedHost
        if host == nil {
            let found = Discovery.discover(udpPort: settings.discoveryPort)
            if let f = found.first {
                say("ok  : QMXR? -> " + found.map(\.description).joined(separator: ", "))
                host = f.ip
            } else if let fb = settings.fallback {
                say("note: no relay answered QMXR?; using the fallback \(fb)")
                host = fb
            } else {
                say("FAIL: no relay answered QMXR? on UDP \(settings.discoveryPort)")
                return r
            }
        }
        guard let h = host else { return r }
        let s: TCPSocket
        do {
            s = try TCPSocket.connect(host: h, port: settings.port, timeout: 3)
        } catch {
            say("FAIL: can't reach the relay at \(h):\(settings.port): \(error)")
            return r
        }
        say("ok  : connected to \(h):\(settings.port) (QMX port 3)")
        s.setReadTimeout(3)
        var ok = true
        for q in ["ID;", "FA;", "MD;"] {
            do { try s.sendAll(q) } catch { say("FAIL: send \(q): \(error)"); s.close(); return r }
            var reply = Data()
            let end = Date().addingTimeInterval(3)
            while Date() < end && reply.last != UInt8(ascii: ";") {
                do {
                    let c = try s.recv(max: 256)
                    if c.isEmpty {
                        say("FAIL: the relay closed port 3 - is the QMX on, with 'USB serial ports' = 3?")
                        s.close()
                        return r
                    }
                    reply.append(c)
                } catch { break }
            }
            let good = reply.last == UInt8(ascii: ";")
            ok = ok && good
            say("\(good ? "ok  " : "FAIL"): \(q) -> \(reply.isEmpty ? "(no reply)" : reply.logText())")
        }
        s.close()
        // the listen-only I/Q copy the TCI server uses (relay port 7357)
        do {
            let q = try TCPSocket.connect(host: h, port: settings.iqPort, timeout: 3)
            q.setReadTimeout(3)
            try q.sendAll(QMXR.frame(QMXR.hello, Data("QMXR/1 probe".utf8)))
            let (t, hello) = try QMXR.readFrame(q)
            let txt = String(decoding: hello, as: UTF8.self)
            let good = t == QMXR.hello && txt.contains("role=listen")
            say("\(good ? "ok  " : "FAIL"): I/Q copy on \(h):\(settings.iqPort) -> \(txt.isEmpty ? "(no answer)" : hello.logText())")
            if requireIQ { ok = ok && good }
            q.close()
        } catch {
            say("\(requireIQ ? "FAIL" : "note"): I/Q copy on \(h):\(settings.iqPort): \(error) (the relay needs updating for TCI)")
            if requireIQ { ok = false }
        }
        r.passed = ok
        say("PROBE \(ok ? "PASSED" : "FAILED")")
        return r
    }
}

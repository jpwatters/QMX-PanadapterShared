// PtyEndpoint.swift - a pseudo-terminal linked at a fixed path (default
// ~/cu.QMX-NAS). Works without the driver; programs that only list /dev/cu.*
// ports won't show it, but anything that accepts a typed path will.

import Foundation
import Darwin

final class PtyEndpoint: SerialEndpoint {
    private var master: Int32 = -1
    private var slave: Int32 = -1
    private let link: String
    private var deviceName = ""
    private var source: DispatchSourceRead?
    private let q = DispatchQueue(label: "qmx.pty")

    init(linkPath: String) {
        link = (linkPath as NSString).expandingTildeInPath
    }

    var displayPath: String { deviceName.isEmpty ? link : "\(link)  (device \(deviceName))" }

    func start(onData: @escaping (Data) -> Void, onOpen: @escaping (Bool) -> Void) throws {
        var m: Int32 = -1, s: Int32 = -1
        guard openpty(&m, &s, nil, nil, nil) == 0 else { throw NetError.sys("openpty", errno) }
        master = m; slave = s
        // Raw 8-bit, no echo: an echo would send the radio's replies back to it.
        var t = termios()
        tcgetattr(slave, &t)
        cfmakeraw(&t)
        t.c_lflag &= ~tcflag_t(ECHO | ECHONL)
        tcsetattr(slave, TCSANOW, &t)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        deviceName = String(cString: ttyname(slave))
        // We keep our own handle on the device open (and never read it), so the
        // device stays put while programs open and close it.
        let dir = (link as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let tmp = "\(link).\(getpid()).tmp"
        unlink(tmp)
        guard symlink(deviceName, tmp) == 0 else { throw NetError.sys("symlink \(tmp)", errno) }
        guard rename(tmp, link) == 0 else { let e = errno; unlink(tmp); throw NetError.sys("rename to \(link)", e) }

        let src = DispatchSource.makeReadSource(fileDescriptor: master, queue: q)
        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(self.master, &buf, buf.count)
            if n > 0 {
                onData(Data(buf[0..<n]))
            } else if n < 0 && errno == EIO {
                usleep(50_000)          // no program has the port open
            }
        }
        src.resume()
        source = src
    }

    /// Programs may change the port settings; never allow echo, which would
    /// loop the radio's replies straight back into the radio.
    private func noEcho() {
        var t = termios()
        guard tcgetattr(slave, &t) == 0 else { return }
        let bad = tcflag_t(ECHO | ECHONL)
        if t.c_lflag & bad != 0 {
            t.c_lflag &= ~bad
            tcsetattr(slave, TCSANOW, &t)
            logI("turned echo off on the serial port")
        }
    }

    func write(_ data: Data) {
        noEcho()
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var p = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let n = Darwin.write(master, p, left)
                if n < 0 {
                    if errno == EAGAIN { logW("serial port full (nothing reading it): dropped \(left) bytes") }
                    else { logW("serial port write failed: \(String(cString: strerror(errno)))") }
                    return
                }
                p += n; left -= n
            }
        }
    }

    func flushStale() { tcflush(slave, TCIFLUSH) }

    func stop() {
        source?.cancel()
        source = nil
        var target = [CChar](repeating: 0, count: 1024)
        let n = readlink(link, &target, 1023)
        if n > 0 && String(cString: target) == deviceName { unlink(link) }
        if slave >= 0 { close(slave); slave = -1 }
        if master >= 0 { close(master); master = -1 }
    }
}

// TciServer.swift - a TCI server on the Mac for the QMX on the NAS, so WS,
// WSJT-X 3, JTDX and other TCI programs get receive and transmit audio with no
// serial port or virtual audio device. Port of qmx_tci.py.
//
//   QMX --USB--> NAS relay --TCP 7357 (copy of the I/Q, listen only)--> \
//                          --TCP 7356 (QMX serial port 3, CAT)-------->  this app
//                                                                       | TCI, ws://127.0.0.1:40001
//                                                                       v
//                                                                 WS / WSJT-X / JTDX
//
// Receive: the 48 kHz I/Q (dial at +12 kHz) becomes USB audio here.
// Control: frequency, mode, TX on/off become the QMX's CAT (FA, MD, TX;/RX;).
// Transmit: one tone at a time (FT8/FT4/JS8/WSPR/tune), measured from the
//           program's audio and sent as TA<Hz>; - the same way the Tab5 does.

import Foundation

private let tciHeaderSize = 64              // 16 x u32: receiver, rate, format, codec, crc, length, type, reserved[9]
private let tRxAudio: UInt32 = 1, tTxAudio: UInt32 = 2, tTxChrono: UInt32 = 3
private let fmtFloat32: UInt32 = 3
private let chronoMs = 10                   // ask the program for this much transmit audio at a time
private let txDelay = 0.05                  // fixed delay on the chrono clock for tone changes

private let modToMd = ["lsb": "1", "usb": "2", "cw": "3", "digu": "6", "digl": "6"]
private let mdToMod = ["1": "lsb", "2": "usb", "3": "cw", "6": "digu", "7": "cw"]

private func tciHeader(rate: Int, format: UInt32, length: Int, type: UInt32) -> Data {
    var words = [UInt32](repeating: 0, count: 16)
    words[0] = 0; words[1] = UInt32(rate); words[2] = format
    words[5] = UInt32(length); words[6] = type
    var d = Data(capacity: tciHeaderSize)
    for w in words { withUnsafeBytes(of: w.littleEndian) { d.append(contentsOf: $0) } }
    return d
}

private func monotonic() -> Double { ProcessInfo.processInfo.systemUptime }

// MARK: - CAT on the relay's port 3

final class RadioCat {
    unowned let srv: TciServer
    private var sock: TCPSocket?
    private let lock = NSRecursiveLock()
    private var buf = Data()
    var freq = 14_074_000
    var md = "6"
    var iqMode: Bool?

    init(_ s: TciServer) { srv = s }

    var connected: Bool { lock.lock(); defer { lock.unlock() }; return sock != nil }

    private func connect() -> Bool {
        guard let host = srv.host() else { return false }
        do {
            let s = try TCPSocket.connect(host: host, port: srv.settings.port, timeout: 3)
            sock = s
            logI("CAT: connected to QMX serial port 3 at \(host):\(srv.settings.port)")
            let t = Thread { [weak self] in self?.reader(s) }
            t.name = "cat-rx"
            t.start()
            // The I/Q has to be I/Q: Q9 is session state on the radio; turning it on again is harmless.
            _ = sendLocked("Q9;FA;MD;")
            return true
        } catch {
            logW("CAT: can't reach the relay's port 3 at \(host):\(srv.settings.port): \(error)")
            return false
        }
    }

    func close() {
        lock.lock()
        let s = sock
        sock = nil
        lock.unlock()
        s?.close()
    }

    private func sendLocked(_ cmd: String) -> Bool {
        guard let s = sock else { return false }
        do {
            try s.sendAll(cmd)
            logD("CAT -> \(cmd)")
            return true
        } catch {
            logW("CAT: send failed: \(error)")
            sock = nil
            s.close()
            return false
        }
    }

    @discardableResult
    func send(_ cmd: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if sock == nil && !connect() { return false }
        return sendLocked(cmd)
    }

    private func reader(_ s: TCPSocket) {
        var local = Data()
        while true {
            guard let c = try? s.recv(max: 4096), !c.isEmpty else { break }
            local.append(c)
            while let i = local.firstIndex(of: UInt8(ascii: ";")) {
                let r = String(decoding: local[local.startIndex..<i], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                local = Data(local[(i + 1)...])
                reply(r)
            }
        }
        lock.lock()
        let mine = sock === s
        lock.unlock()
        if mine {
            logI("CAT: the relay closed port 3 (QMX off, or 'USB serial ports' not 3?)")
            close()
        }
    }

    private func reply(_ r: String) {
        logD("CAT <- \(r);")
        if r.hasPrefix("FA"), let f = Int(r.dropFirst(2)), r.dropFirst(2).allSatisfy(\.isNumber) {
            if f != freq { freq = f; srv.radioChanged() }
        } else if r.hasPrefix("MD") && r.count == 3 {
            let m = String(r.suffix(1))
            if m != md { md = m; srv.radioChanged() }
        } else if r.hasPrefix("Q9") {
            let v = r.dropFirst(2).trimmingCharacters(in: .whitespaces).prefix(1)
            if v == "0" || v == "1" {
                let on = v == "1"
                if !on {
                    logI("CAT: the QMX is not in I/Q mode - turning it on (Q9 1;)")
                    send("Q9 1;")
                }
                iqMode = on
            }
        }
    }
}

// MARK: - the relay's listen-only I/Q copy (port 7357)

final class IqClient {
    unowned let srv: TciServer
    private var sock: TCPSocket?
    private var running = true
    let demod = UsbDemod()

    init(_ s: TciServer) {
        srv = s
        let t = Thread { [weak self] in self?.loop() }
        t.name = "iq"
        t.start()
    }

    func stop() { running = false; sock?.close() }

    private func loop() {
        while running {
            if !srv.wantIQ() { Thread.sleep(forTimeInterval: 0.2); continue }
            guard let host = srv.host() else { Thread.sleep(forTimeInterval: 3); continue }
            do {
                let s = try TCPSocket.connect(host: host, port: srv.settings.iqPort, timeout: 3)
                defer { s.close(); sock = nil }
                // tx=1: the relay keeps the Tab5 off the transmitter
                try s.sendAll(QMXR.frame(QMXR.hello, Data("QMXR/1 tci-mac tx=1".utf8)))
                s.setReadTimeout(5)
                let (_, hello) = try QMXR.readFrame(s)
                logI("I/Q: connected to \(host):\(srv.settings.iqPort) (\(String(decoding: hello, as: UTF8.self)))")
                sock = s
                while running && srv.wantIQ() {
                    let (t, payload) = try QMXR.readFrame(s)
                    if t == QMXR.iq && !payload.isEmpty { srv.rxAudio(demod.process(payload)) }
                }
                logI("I/Q: released (no TCI program is listening)")
            } catch {
                if running {
                    logW("I/Q: \(host):\(srv.settings.iqPort): \(error) - retrying in 3 s")
                    Thread.sleep(forTimeInterval: 3)
                }
            }
        }
    }
}

// MARK: - the TCI server

final class TciServer {
    let settings: BridgeSettings
    let locator: RelayLocator
    private var listener: TCPListener?
    private let wsLock = NSLock()
    private var _ws: WebSocket?
    var ws: WebSocket? { wsLock.lock(); defer { wsLock.unlock() }; return _ws }
    private var audioOn = false
    private(set) var keyed = false
    private var tune = false
    private var vfoB: Int?
    private(set) lazy var cat = RadioCat(self)
    private let tracker = ToneTracker()
    private var txLastAudio = 0.0
    private var chronoRunning = false
    private var txT0 = 0.0
    private var txQ: [(due: Double, cmd: String)] = []
    private let txCond = NSCondition()
    private var iq: IqClient!
    private var sentFreq: Int?
    private var sentMod: String?
    private var running = true
    private let keyLock = NSRecursiveLock()

    /// Called on the main queue: (client connected, keyed).
    var onState: ((Bool, Bool) -> Void)?

    init(settings: BridgeSettings) {
        self.settings = settings
        locator = RelayLocator(settings: settings)
    }

    func host() -> String? { locator.current() }
    func wantIQ() -> Bool { ws?.alive ?? false }
    private func mod() -> String { mdToMod[cat.md] ?? "usb" }

    private func notify() {
        let c = ws != nil, k = keyed
        DispatchQueue.main.async { self.onState?(c, k) }
    }

    func start() throws {
        let l = try TCPListener(address: settings.tciListen, port: settings.tciPort)
        listener = l
        iq = IqClient(self)
        logI("TCI server on ws://\(settings.tciListen):\(settings.tciPort) - in WS/WSJT-X choose Rig 'TCI Client RX1', server \(settings.tciListen):\(settings.tciPort)")
        spawn("tx-sender") { [weak self] in self?.txSender() }
        spawn("poll") { [weak self] in
            while let s = self, s.running {
                Thread.sleep(forTimeInterval: 1)
                if s.ws != nil && !s.keyed { s.cat.send("FA;MD;") }
            }
        }
        spawn("tci-accept") { [weak self] in
            while let s = self, s.running, let (c, peer) = l.accept() {
                s.spawn("tci-client") { s.serve(c, peer) }
            }
        }
    }

    func stop() {
        running = false
        if keyed { key(false) }
        listener?.close()
        listener = nil
        ws?.close()
        iq?.stop()
        cat.close()
        txCond.lock(); txCond.broadcast(); txCond.unlock()
    }

    private func spawn(_ name: String, _ f: @escaping () -> Void) {
        let t = Thread(block: f)
        t.name = name
        t.start()
    }

    private func send(_ cmds: String...) {
        guard let w = ws else { return }
        for c in cmds {
            do { try w.sendText(c); logD("TCI -> \(c)") } catch { return }
        }
    }

    /// The QMX's frequency or mode changed (from the Tab5, the knob, or us).
    func radioChanged() {
        if cat.freq != sentFreq {
            sentFreq = cat.freq
            send("vfo:0,0,\(cat.freq);", "dds:0,\(cat.freq);")
        }
        if mod() != sentMod {
            sentMod = mod()
            send("modulation:0,\(sentMod!);")
        }
    }

    // MARK: receive audio

    func rxAudio(_ mono: [Float]) {
        guard let w = ws, audioOn else { return }
        var st = [Float](repeating: 0, count: 2 * mono.count)
        for (i, v) in mono.enumerated() { st[2 * i] = v; st[2 * i + 1] = v }
        var d = tciHeader(rate: tciSampleRate, format: fmtFloat32, length: st.count, type: tRxAudio)
        st.withUnsafeBytes { d.append(contentsOf: $0) }     // little-endian on Apple silicon and Intel
        try? w.sendBinary(d)
    }

    // MARK: transmit

    private func key(_ on: Bool) {
        keyLock.lock(); defer { keyLock.unlock() }
        if on == keyed { return }
        keyed = on
        if on {
            tracker.reset()
            txLastAudio = monotonic()
            cat.send("TA0;TX;")
            logI("TX: keyed (tones follow the program's transmit audio)")
            txCond.lock(); txQ.removeAll(); txCond.unlock()
            txT0 = monotonic()
            chronoRunning = true
            spawn("tx-chrono") { [weak self] in self?.chrono() }
        } else {
            chronoRunning = false
            txCond.lock(); txQ.removeAll(); txCond.unlock()
            cat.send("TA0;RX;")
            logI("TX: unkeyed - QMX back in receive")
            cat.send("FA;MD;")
        }
        notify()
    }

    /// Ask the program for transmit audio in real time, chronoMs at a time.
    private func chrono() {
        let n = tciSampleRate * chronoMs / 1000
        let hdr = tciHeader(rate: tciSampleRate, format: fmtFloat32, length: 2 * n, type: tTxChrono)
        var next = txT0
        while chronoRunning {
            guard let w = ws else { break }
            do { try w.sendBinary(hdr) } catch { break }
            // watchdog: keyed but no audio for 3 s -> key up, never leave the radio transmitting
            if monotonic() - txLastAudio > 3 {
                logW("TX: no transmit audio for 3 s - keying up")
                keyLock.lock()
                chronoRunning = false
                keyed = false
                keyLock.unlock()
                cat.send("TA0;RX;")
                send("trx:0,false;")
                notify()
                break
            }
            next += Double(chronoMs) / 1000
            let wait = next - monotonic()
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        }
    }

    private func txAudio(_ payload: Data) {
        guard payload.count >= tciHeaderSize, keyed else { return }
        func word(_ i: Int) -> UInt32 {
            payload.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4 * i, as: UInt32.self)) }
        }
        guard word(6) == tTxAudio else { return }
        let n = Int(word(5)), fmt = word(2)
        let bytesPer: Int
        switch fmt { case 3: bytesPer = 4; case 0: bytesPer = 2; case 2: bytesPer = 4; default: return }
        let avail = (payload.count - tciHeaderSize) / bytesPer
        let count = min(n, avail)
        var mono = [Double]()
        mono.reserveCapacity(count / 2 + 1)
        payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var i = 0
            while i < count {             // left channel of interleaved stereo
                let off = tciHeaderSize + i * bytesPer
                switch fmt {
                case 3: mono.append(Double(Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt32.self)))))
                case 0: mono.append(Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: off, as: Int16.self))) / 32768)
                default: mono.append(Double(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: off, as: Int32.self))) / 2147483648)
                }
                i += 2
            }
        }
        txLastAudio = monotonic()
        for (idx, f) in tracker.feed(mono) {
            let due = txT0 + idx / Double(tciSampleRate) + txDelay
            txCond.lock()
            txQ.append((due, f != 0 ? String(format: "TA%.2f;", f) : "TA0;"))
            txCond.signal()
            txCond.unlock()
        }
    }

    /// Send each tone change at its due time, in order.
    private func txSender() {
        while running {
            txCond.lock()
            while txQ.isEmpty && running { txCond.wait() }
            if !running { txCond.unlock(); return }
            let (due, cmd) = txQ[0]
            let wait = due - monotonic()
            if wait > 0 {
                _ = txCond.wait(until: Date().addingTimeInterval(wait))
                txCond.unlock()
                continue
            }
            txQ.removeFirst()
            txCond.unlock()
            if keyed { cat.send(cmd) }
        }
    }

    // MARK: TCI commands

    private func hello() {
        let f = cat.freq
        sentFreq = f
        sentMod = mod()
        send("protocol:QMX-NAS,1.9;", "device:QMX;", "receive_only:false;", "trx_count:1;",
             "channels_count:1;", "vfo_limits:500000,60000000;", "if_limits:-24000,24000;",
             "modulations_list:LSB,USB,CW,DIGL,DIGU;", "audio_samplerate:\(tciSampleRate);",
             "iq_samplerate:\(tciSampleRate);", "dds:0,\(f);", "if:0,0,0;",
             "vfo:0,0,\(f);", "vfo:0,1,\(vfoB ?? f);",
             "modulation:0,\(sentMod!);", "rx_enable:0,true;", "tx_enable:0,true;",
             "trx:0,false;", "tune:0,false;", "split_enable:0,false;", "rit_enable:0,false;",
             "xit_enable:0,false;", "drive:0,100;", "tune_drive:0,10;", "start;", "ready;")
    }

    private func command(_ text: String) {
        for rawSub in text.split(separator: ";") {
            let raw = rawSub.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty { continue }
            logD("TCI <- \(raw);")
            let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let name = parts[0].lowercased()
            let a = parts.count > 1 && !parts[1].isEmpty
                ? parts[1].split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                : []
            if !handle(name, a) { logI("TCI: ignored '\(raw);'") }
        }
    }

    /// false = bad arguments.
    private func handle(_ name: String, _ a: [String]) -> Bool {
        func num(_ s: String) -> Int? { Int(s) ?? Double(s).map { Int($0) } }
        switch name {
        case "vfo":
            let ch = a.count > 1 ? (Int(a[1]) ?? -1) : 0
            if ch < 0 { return false }
            if a.count > 2 {
                guard let f = num(a[2]) else { return false }
                if ch == 0 { cat.freq = f; cat.send(String(format: "FA%011ld;", f)) } else { vfoB = f }
            }
            let f = ch == 0 ? cat.freq : (vfoB ?? cat.freq)
            if ch == 0 { sentFreq = f }
            send("vfo:0,\(ch),\(f);")
        case "dds":
            if a.count > 1 {
                guard let f = num(a[1]) else { return false }
                cat.freq = f
                cat.send(String(format: "FA%011ld;", f))
            }
            sentFreq = cat.freq
            send("dds:0,\(cat.freq);")
        case "modulation":
            if a.count > 1 {
                let m = a[1].lowercased()
                if let md = modToMd[m] {
                    cat.md = md
                    cat.send("MD\(md);")
                    sentMod = m
                    send("modulation:0,\(m);")
                    return true
                }
            }
            send("modulation:0,\(mod());")
        case "trx":
            if a.count > 1 { key(a[1].lowercased() == "true") }
            send("trx:0,\(keyed ? "true" : "false");")
        case "tune":
            if a.count > 1 {
                tune = a[1].lowercased() == "true"
                key(tune)
            }
            send("tune:0,\(tune ? "true" : "false");")
        case "split_enable":
            send("split_enable:0,false;")
        case "audio_start":
            audioOn = true
            send("audio_start:0;")
            logI("TCI: receive audio started")
        case "audio_stop":
            audioOn = false
            send("audio_stop:0;")
        case "audio_samplerate":
            send("audio_samplerate:\(tciSampleRate);")
        case "audio_stream_sample_type", "audio_stream_channels", "audio_stream_samples":
            send("\(name):\(a.joined(separator: ","));")
        case "rx_smeter":
            send("rx_smeter:0,0,\(Int((iq.demod.levelDb - 50).rounded()));")
        case "rx_enable":
            let rx = a.first ?? "0"
            send("rx_enable:\(rx),\(rx == "0" ? "true" : "false");")
        case "start", "stop":
            send("start;")            // the QMX is never powered off from here
        case "drive", "tune_drive", "volume", "mute", "rx_mute", "rit_enable", "xit_enable",
             "rit_offset", "xit_offset", "agc_mode", "agc_gain", "lock", "sql_enable", "sql_level",
             "rx_sensors_enable", "tx_sensors_enable", "app_focus":
            if !a.isEmpty { send("\(name):\(a.joined(separator: ","));") }
        default:
            break                     // iq_start, spot, cw_macros ... not supported
        }
        return true
    }

    // MARK: connections

    private func serve(_ conn: TCPSocket, _ peer: String) {
        let w = WebSocket(sock: conn)
        guard w.handshake() else { conn.close(); return }
        wsLock.lock()
        let old = _ws
        _ws = w
        wsLock.unlock()
        if let o = old {
            logI("TCI: a new program connected - closing the previous one")
            o.close()
        }
        logI("TCI: \(peer) connected")
        notify()
        cat.send("FA;MD;")
        Thread.sleep(forTimeInterval: 0.15)     // let the radio's frequency and mode arrive first
        hello()
        do {
            while w.alive {
                switch try w.recv() {
                case .text(let t): command(t)
                case .binary(let d): txAudio(d)
                }
            }
        } catch {
            logI("TCI: \(peer) disconnected (\(error))")
        }
        wsLock.lock()
        let mine = _ws === w
        if mine { _ws = nil }
        wsLock.unlock()
        if mine {
            audioOn = false
            if keyed { key(false) }
            cat.close()                // release port 3 while no program uses it
            notify()
        }
        w.markDead()
        conn.close()
    }
}

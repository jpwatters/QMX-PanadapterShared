#!/usr/bin/env python3
"""
qmx_tci.py - a TCI server on the Mac for the QMX on the NAS, so WS (formerly
WSJT-X Improved), WSJT-X 3, JTDX and other TCI programs can use it with receive
and transmit audio and no serial port or virtual audio device.

    QMX --USB--> NAS relay --TCP 7357 (copy of the I/Q, listen only)--> \
                           --TCP 7356 (QMX serial port 3, CAT)-------->  this program
                                                                           |  TCI, ws://127.0.0.1:40001
                                                                           v
                                                                     WS / WSJT-X / JTDX

  Receive: the 48 kHz I/Q (the radio's dial is at +12 kHz in it) is turned into
           upper-sideband audio here and streamed to the program over TCI.
  Control: frequency, mode and transmit on/off become the QMX's own CAT
           commands (FA, MD, TX;/RX;) on serial port 3, which the Tab5 never uses.
  Transmit: FT8, FT4, JS8, WSPR and tune are one tone at a time. The program's
           transmit audio is measured here and each tone is sent to the QMX as
           TA<Hz>; - the same way the Tab5 transmits. Voice (SSB) is not
           supported: the QMX has no transmit-audio path over the network.

The Tab5 keeps its own connection (port 7355) and is not affected.

TCI is Expert Electronics' Transceiver Control Interface: text commands and
binary audio frames over a WebSocket. Only what TCI clients for digital modes
use is implemented. Needs numpy (installed by install-mac.sh).
"""

from __future__ import annotations

import base64
import collections
import hashlib
import logging
import math
import os
import re
import select
import socket
import struct
import threading
import time

import numpy as np

log = logging.getLogger("qmx-tci")

SAMPLE_RATE = 48000
DIAL_OFFSET_HZ = 12000          # the QMX's dial is +12 kHz in its I/Q stream
HDR = struct.Struct("<BBH")     # QMXR/1 frame header: type, flags, length
PROTO_HELLO, PROTO_IQ, PROTO_PING = 1, 2, 4
TCI_HDR = struct.Struct("<16I") # receiver, rate, format, codec, crc, length, type, reserved[9]
T_IQ, T_RX_AUDIO, T_TX_AUDIO, T_TX_CHRONO = 0, 1, 2, 3
FMT_FLOAT32 = 3
CHRONO_MS = 10                  # ask the program for this much transmit audio at a time
TX_DELAY = 0.05                 # tone changes go to the radio this long after the audio sample
                                # they were measured at, on the chrono clock: a fixed delay
                                # instead of 0-20 ms of jitter from block and measuring times
WS_GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

# TCI modulation <-> QMX MD number (QMX: 1 LSB, 2 USB, 3 CW, 6 DIGI)
MOD_TO_MD = {"lsb": "1", "usb": "2", "cw": "3", "digu": "6", "digl": "6"}
MD_TO_MOD = {"1": "lsb", "2": "usb", "3": "cw", "6": "digu", "7": "cw"}


# ---------------------------------------------------------------------------
# Minimal WebSocket server side (RFC 6455): text, binary, ping/pong, close
# ---------------------------------------------------------------------------

class WsClosed(Exception):
    pass


class WebSocket:
    def __init__(self, sock: socket.socket):
        self.sock = sock
        self.send_lock = threading.Lock()
        self.alive = True
        self._frag_op = None
        self._frag = bytearray()

    @staticmethod
    def handshake(sock: socket.socket) -> bool:
        sock.settimeout(5)
        req = b""
        while b"\r\n\r\n" not in req:
            c = sock.recv(4096)
            if not c:
                return False
            req += c
            if len(req) > 16384:
                return False
        m = re.search(rb"(?im)^sec-websocket-key:\s*(\S+)", req)
        if not m:
            sock.sendall(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
            return False
        accept = base64.b64encode(hashlib.sha1(m.group(1) + WS_GUID).digest())
        sock.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                     b"Connection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
        sock.settimeout(None)
        return True

    def _recv_exact(self, n: int) -> bytes:
        b = bytearray()
        while len(b) < n:
            c = self.sock.recv(n - len(b))
            if not c:
                raise WsClosed("peer closed")
            b += c
        return bytes(b)

    def recv(self):
        """Next complete message: ('text', str) or ('binary', bytes)."""
        while True:
            b0, b1 = self._recv_exact(2)
            fin, op = b0 & 0x80, b0 & 0x0F
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._recv_exact(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._recv_exact(8))[0]
            mask = self._recv_exact(4) if b1 & 0x80 else None
            data = self._recv_exact(n) if n else b""
            if mask:
                a = np.frombuffer(data, np.uint8)
                m = np.frombuffer((mask * (n // 4 + 1))[:n], np.uint8)
                data = (a ^ m).tobytes()
            if op == 0x8:
                self.close(1000)
                raise WsClosed("close frame")
            if op == 0x9:
                self._send(0xA, data)
                continue
            if op == 0xA:
                continue
            if op in (0x1, 0x2):
                if fin:
                    return ("text", data.decode("utf-8", "replace")) if op == 1 else ("binary", data)
                self._frag_op, self._frag = op, bytearray(data)
                continue
            if op == 0x0 and self._frag_op:
                self._frag += data
                if fin:
                    op, data, self._frag_op = self._frag_op, bytes(self._frag), None
                    return ("text", data.decode("utf-8", "replace")) if op == 1 else ("binary", data)

    def _send(self, op: int, data: bytes):
        n = len(data)
        if n < 126:
            h = struct.pack(">BB", 0x80 | op, n)
        elif n < 65536:
            h = struct.pack(">BBH", 0x80 | op, 126, n)
        else:
            h = struct.pack(">BBQ", 0x80 | op, 127, n)
        with self.send_lock:
            if not self.alive:
                raise WsClosed("closed")
            try:
                self.sock.sendall(h + data)
            except OSError as e:
                self.alive = False
                raise WsClosed(str(e))

    def send_text(self, s: str):
        self._send(0x1, s.encode())

    def send_binary(self, b: bytes):
        self._send(0x2, b)

    def close(self, code: int = 1000):
        try:
            self._send(0x8, struct.pack(">H", code))
        except WsClosed:
            pass
        self.alive = False
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Receive: I/Q -> upper-sideband audio
# ---------------------------------------------------------------------------

class UsbDemod:
    """48 kHz complex I/Q -> 48 kHz USB audio (0.1-3.2 kHz above the dial).
    Shift dial+1650 Hz to 0, low-pass +-1550 Hz (complex), shift back up by
    1650 Hz and keep the real part: everything between the dial and dial+3.2
    kHz, nothing below the dial. A slow AGC keeps the level steady for the decoder."""

    def __init__(self, fs: int = SAMPLE_RATE, taps: int = 255):
        self.fs = fs
        self.center = 1650.0
        cut = 1550.0
        n = np.arange(taps) - (taps - 1) / 2
        h = np.sinc(2 * cut / fs * n) * (2 * cut / fs) * np.blackman(taps)
        self.h = (h / h.sum()).astype(np.float64)
        self.tail = np.zeros(taps - 1, np.complex128)
        self.ph1 = 0.0
        self.ph2 = 0.0
        self.w1 = -2 * math.pi * (DIAL_OFFSET_HZ + self.center) / fs
        self.w2 = 2 * math.pi * self.center / fs
        self.gain = 1.0
        self.level_db = -120.0

    def process(self, s16: bytes) -> np.ndarray:
        a = np.frombuffer(s16, "<i2").astype(np.float64) / 32768.0
        z = a[0::2] + 1j * a[1::2]
        n = len(z)
        k = np.arange(n)
        z = z * np.exp(1j * (self.ph1 + self.w1 * k))
        self.ph1 = (self.ph1 + self.w1 * n) % (2 * math.pi)
        x = np.concatenate((self.tail, z))
        y = np.convolve(x, self.h, mode="valid")
        self.tail = x[-(len(self.h) - 1):]
        y = y * np.exp(1j * (self.ph2 + self.w2 * k))
        self.ph2 = (self.ph2 + self.w2 * n) % (2 * math.pi)
        audio = y.real * 2.0
        rms = float(np.sqrt(np.mean(audio * audio))) + 1e-12
        self.level_db = 20 * math.log10(rms)
        # slow AGC towards an RMS of 0.05 (about -26 dBFS); gain limited to +60 dB
        target = 0.05 / rms
        self.gain += (min(target, 1000.0) - self.gain) * 0.02
        out = np.clip(audio * self.gain, -1.0, 1.0)
        return out.astype(np.float32)


# ---------------------------------------------------------------------------
# Transmit: the program's audio -> one tone at a time for the QMX
# ---------------------------------------------------------------------------

class ToneTracker:
    """Measures the frequency of a one-tone signal (FT8/FT4/JS8/WSPR/tune) from
    its rising zero crossings and reports a new tone each time the frequency
    settles somewhere new. FT8 and FT4 audio from WSJT-X/WS is smoothed (GFSK),
    so a tone is reported once the frequency has stopped moving: it is
    within PLATEAU_HZ for PLATEAU_MS. Silence is reported as tone 0."""

    PLATEAU_HZ = 0.25
    PLATEAU_MS = 8.0
    CHANGE_HZ = 0.5
    SILENCE = 0.01

    def __init__(self, fs: int = SAMPLE_RATE):
        self.fs = fs
        self.reset()

    def reset(self):
        self.n = 0                 # samples seen
        self.prev = 0.0
        self.last_cross = None     # time (samples) of the last rising crossing
        self.periods = collections.deque()   # (time, freq) of recent single periods
        self.tone = 0.0            # last tone reported
        self.quiet = 0             # samples below SILENCE in a row

    def feed(self, x: np.ndarray):
        """Process mono samples; returns a list of (sample_index, tone_hz) changes."""
        out = []
        if len(x) == 0:
            return out
        loud = np.abs(x) > self.SILENCE
        prev = self.prev
        base = self.n
        xs = np.concatenate(([prev], x))
        idx = np.nonzero((xs[:-1] <= 0) & (xs[1:] > 0))[0]      # rising crossings between i-1 and i
        for i in idx:
            a, b = xs[i], xs[i + 1]
            t = base + i - 1 + (-a / (b - a) if b != a else 0.0)
            if self.last_cross is not None:
                p = t - self.last_cross
                if p > 0:
                    f = self.fs / p
                    self.periods.append((t, f))
            self.last_cross = t
        # silence
        if loud.any():
            last_loud = int(np.nonzero(loud)[0][-1])
            self.quiet = len(x) - 1 - last_loud
        else:
            self.quiet += len(x)
        self.prev = float(x[-1])
        self.n += len(x)
        if self.quiet > self.fs * 0.004:            # 4 ms of silence
            self.periods.clear()
            self.last_cross = None
            if self.tone != 0.0:
                self.tone = 0.0
                out.append((self.n - self.quiet, 0.0))
            return out
        # plateau: the last PLATEAU_MS of periods agree within PLATEAU_HZ
        span = self.fs * self.PLATEAU_MS / 1000.0
        while self.periods and self.periods[0][0] < self.n - 8 * span:     # keep ~64 ms
            self.periods.popleft()
        recent = [f for (t, f) in self.periods if t >= self.n - span]
        if len(recent) >= 4 and (self.periods[0][0] <= self.n - span):
            lo, hi = min(recent), max(recent)
            if hi - lo <= 2 * self.PLATEAU_HZ:
                f = sum(recent) / len(recent)
                if abs(f - self.tone) >= self.CHANGE_HZ and 50.0 <= f <= 4000.0:
                    # Report the change where the frequency crossed half way from
                    # the old tone to the new one - the symbol boundary, for smoothed
                    # (GFSK) and plain FSK alike. After silence: where the tone began.
                    at = self.periods[0][0]
                    if self.tone:
                        mid = (self.tone + f) / 2.0
                        old_side = self.tone > mid
                        for (t, pf) in reversed(self.periods):
                            if (pf > mid) == old_side:
                                at = t
                                break
                    self.tone = f
                    out.append((at, f))
        return out


# ---------------------------------------------------------------------------
# The radio: CAT on QMX serial port 3 and the I/Q copy
# ---------------------------------------------------------------------------

class RadioCat:
    """CAT on the relay's port 3 service (raw serial over TCP)."""

    def __init__(self, server: "TciServer"):
        self.srv = server
        self.sock: socket.socket | None = None
        self.lock = threading.RLock()
        self.buf = b""
        self.freq = 14074000
        self.md = "6"
        self.iq_mode = None

    def connected(self) -> bool:
        return self.sock is not None

    def connect(self) -> bool:
        host = self.srv.host()
        if not host:
            return False
        try:
            s = socket.create_connection((host, self.srv.args.port), 3)
        except OSError as e:
            log.warning("CAT: can't reach the relay's port 3 at %s:%d: %s", host, self.srv.args.port, e)
            return False
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        s.settimeout(None)
        self.sock = s
        log.info("CAT: connected to QMX serial port 3 at %s:%d", host, self.srv.args.port)
        threading.Thread(target=self._reader, args=(s,), daemon=True, name="cat-rx").start()
        # The I/Q has to be I/Q: Q9 is session state on the radio, the Tab5 sets
        # it too, and turning it on again is harmless.
        self.send("Q9;FA;MD;")
        return True

    def close(self):
        s, self.sock = self.sock, None
        if s:
            try:
                s.close()
            except OSError:
                pass

    def send(self, cmd: str) -> bool:
        with self.lock:
            if not self.sock and not self.connect():
                return False
            try:
                self.sock.sendall(cmd.encode())
                log.debug("CAT -> %s", cmd)
                return True
            except OSError as e:
                log.warning("CAT: send failed: %s", e)
                self.close()
                return False

    def _reader(self, s: socket.socket):
        try:
            while True:
                c = s.recv(4096)
                if not c:
                    break
                self.buf += c
                while b";" in self.buf:
                    r, self.buf = self.buf.split(b";", 1)
                    self._reply(r.decode("ascii", "replace").strip())
        except OSError:
            pass
        if self.sock is s:
            log.info("CAT: the relay closed port 3 (QMX off, or 'USB serial ports' not 3?)")
            self.close()

    def _reply(self, r: str):
        log.debug("CAT <- %s;", r)
        if r.startswith("FA") and r[2:].isdigit():
            f = int(r[2:])
            if f != self.freq:
                self.freq = f
                self.srv.radio_changed()
        elif r.startswith("MD") and len(r) == 3:
            if r[2] != self.md:
                self.md = r[2]
                self.srv.radio_changed()
        elif r.startswith("Q9") and r[2:].strip()[:1] in ("0", "1"):
            on = r[2:].strip()[:1] == "1"
            if not on:
                log.info("CAT: the QMX is not in I/Q mode - turning it on (Q9 1;)")
                self.send("Q9 1;")
            self.iq_mode = on


class IqClient:
    """The relay's listen-only I/Q copy (port 7357)."""

    def __init__(self, server: "TciServer"):
        self.srv = server
        self.sock: socket.socket | None = None
        self.running = True
        self.demod = UsbDemod()
        threading.Thread(target=self._loop, daemon=True, name="iq").start()

    def _recv_exact(self, s, n):
        b = bytearray()
        while len(b) < n:
            c = s.recv(n - len(b))
            if not c:
                raise ConnectionError("relay closed the I/Q connection")
            b += c
        return bytes(b)

    def _loop(self):
        while self.running:
            if not self.srv.want_iq():
                time.sleep(0.2)
                continue
            host = self.srv.host()
            if not host:
                time.sleep(3)
                continue
            try:
                s = socket.create_connection((host, self.srv.args.iq_port), 3)
                s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                hello = b"QMXR/1 tci-mac tx=1"      # tx=1: the relay keeps the Tab5 off the transmitter
                s.sendall(HDR.pack(PROTO_HELLO, 0, len(hello)) + hello)
                s.settimeout(5)
                t, _, n = HDR.unpack(self._recv_exact(s, 4))
                hello = self._recv_exact(s, n)
                log.info("I/Q: connected to %s:%d (%s)", host, self.srv.args.iq_port,
                         hello.decode(errors="replace"))
                self.sock = s
                while self.running and self.srv.want_iq():
                    t, _, n = HDR.unpack(self._recv_exact(s, 4))
                    payload = self._recv_exact(s, n) if n else b""
                    if t == PROTO_IQ and payload:
                        self.srv.rx_audio(self.demod.process(payload))
                log.info("I/Q: released (no TCI program is listening)")
            except (OSError, ConnectionError, struct.error) as e:
                log.warning("I/Q: %s:%d: %s - retrying in 3 s", host, self.srv.args.iq_port, e)
                time.sleep(3)
            finally:
                if self.sock:
                    try:
                        self.sock.close()
                    except OSError:
                        pass
                    self.sock = None


# ---------------------------------------------------------------------------
# The TCI server
# ---------------------------------------------------------------------------

class TciServer:
    def __init__(self, args, find_nas):
        self.args = args
        self._find_nas = find_nas       # () -> host or None (discovery / fallback / --host)
        self._host = args.host
        self.ws: WebSocket | None = None
        self.audio_on = False
        self.keyed = False
        self.tune = False
        self.split = False
        self.vfo_b = None
        self.cat = RadioCat(self)
        self.tracker = ToneTracker()
        self.tx_last_audio = 0.0
        self.chrono_stop = threading.Event()
        self.tx_t0 = 0.0                # monotonic time of transmit-audio sample 0
        self.tx_q = collections.deque()  # (due, CAT command) waiting to be sent on time
        self.tx_wake = threading.Condition()
        threading.Thread(target=self._tx_sender, daemon=True, name="tx-sender").start()
        self.iq = IqClient(self)
        self.sent_freq = None
        self.sent_mod = None

    # -- helpers -------------------------------------------------------------

    def host(self):
        if self._host is None:
            self._host = self._find_nas()
        return self._host

    def want_iq(self) -> bool:
        return self.ws is not None and self.ws.alive

    def mod(self) -> str:
        return MD_TO_MOD.get(self.cat.md, "usb")

    def send(self, *cmds: str):
        ws = self.ws
        if not ws:
            return
        for c in cmds:
            try:
                ws.send_text(c)
                log.debug("TCI -> %s", c)
            except WsClosed:
                return

    def radio_changed(self):
        """The QMX's frequency or mode changed (from the Tab5, the knob, or us)."""
        if self.cat.freq != self.sent_freq:
            self.sent_freq = self.cat.freq
            self.send("vfo:0,0,%d;" % self.cat.freq, "dds:0,%d;" % self.cat.freq)
        if self.mod() != self.sent_mod:
            self.sent_mod = self.mod()
            self.send("modulation:0,%s;" % self.sent_mod)

    # -- receive audio -------------------------------------------------------

    def rx_audio(self, mono: np.ndarray):
        ws = self.ws
        if not ws or not self.audio_on:
            return
        st = np.empty(2 * len(mono), np.float32)
        st[0::2] = mono
        st[1::2] = mono
        hdr = TCI_HDR.pack(0, SAMPLE_RATE, FMT_FLOAT32, 0, 0, len(st), T_RX_AUDIO, *([0] * 9))
        try:
            ws.send_binary(hdr + st.tobytes())
        except WsClosed:
            pass

    # -- transmit ------------------------------------------------------------

    def key(self, on: bool):
        if on == self.keyed:
            return
        self.keyed = on
        if on:
            self.tracker.reset()
            self.tx_last_audio = time.monotonic()
            self.cat.send("TA0;TX;")
            log.info("TX: keyed (tones follow the program's transmit audio)")
            self.chrono_stop.clear()
            with self.tx_wake:
                self.tx_q.clear()
            self.tx_t0 = time.monotonic()
            threading.Thread(target=self._chrono, daemon=True, name="tx-chrono").start()
        else:
            self.chrono_stop.set()
            with self.tx_wake:
                self.tx_q.clear()
            self.cat.send("TA0;RX;")
            log.info("TX: unkeyed - QMX back in receive")
            self.cat.send("FA;MD;")

    def _chrono(self):
        """Ask the program for transmit audio in real time, CHRONO_MS at a time."""
        n = SAMPLE_RATE * CHRONO_MS // 1000
        hdr = TCI_HDR.pack(0, SAMPLE_RATE, FMT_FLOAT32, 0, 0, 2 * n, T_TX_CHRONO, *([0] * 9))
        nxt = self.tx_t0
        while not self.chrono_stop.is_set():
            ws = self.ws
            if not ws:
                break
            try:
                ws.send_binary(hdr)
            except WsClosed:
                break
            # watchdog: keyed but no audio for 3 s -> key up, never leave the radio transmitting
            if time.monotonic() - self.tx_last_audio > 3.0:
                log.warning("TX: no transmit audio for 3 s - keying up")
                self.chrono_stop.set()
                self.keyed = False
                self.cat.send("TA0;RX;")
                self.send("trx:0,false;")
                break
            nxt += CHRONO_MS / 1000.0
            time.sleep(max(0.0, nxt - time.monotonic()))

    def tx_audio(self, payload: bytes):
        if len(payload) < TCI_HDR.size:
            return
        h = TCI_HDR.unpack_from(payload)
        if h[6] != T_TX_AUDIO or not self.keyed:
            return
        n = h[5]
        fmt = h[2]
        dtype = {3: "<f4", 0: "<i2", 2: "<i4"}.get(fmt)
        if dtype is None:
            return
        a = np.frombuffer(payload, dtype, count=n, offset=TCI_HDR.size).astype(np.float64)
        if fmt == 0:
            a /= 32768.0
        elif fmt == 2:
            a /= 2147483648.0
        mono = a[0::2]
        self.tx_last_audio = time.monotonic()
        for idx, f in self.tracker.feed(mono):
            due = self.tx_t0 + idx / SAMPLE_RATE + TX_DELAY
            with self.tx_wake:
                self.tx_q.append((due, "TA%.2f;" % f if f else "TA0;"))
                self.tx_wake.notify()

    def _tx_sender(self):
        """Send each tone change at its due time, in order."""
        while True:
            with self.tx_wake:
                while not self.tx_q:
                    self.tx_wake.wait()
                due, cmd = self.tx_q[0]
                wait = due - time.monotonic()
                if wait > 0:
                    self.tx_wake.wait(wait)
                    continue
                self.tx_q.popleft()
            if self.keyed:
                self.cat.send(cmd)

    # -- TCI commands ----------------------------------------------------------

    def hello(self):
        f = self.cat.freq
        self.sent_freq, self.sent_mod = f, self.mod()
        self.send("protocol:QMX-NAS,1.9;", "device:QMX;", "receive_only:false;", "trx_count:1;",
                  "channels_count:1;", "vfo_limits:500000,60000000;", "if_limits:-24000,24000;",
                  "modulations_list:LSB,USB,CW,DIGL,DIGU;", "audio_samplerate:%d;" % SAMPLE_RATE,
                  "iq_samplerate:%d;" % SAMPLE_RATE, "dds:0,%d;" % f, "if:0,0,0;",
                  "vfo:0,0,%d;" % f, "vfo:0,1,%d;" % (self.vfo_b or f),
                  "modulation:0,%s;" % self.sent_mod, "rx_enable:0,true;", "tx_enable:0,true;",
                  "trx:0,false;", "tune:0,false;", "split_enable:0,false;", "rit_enable:0,false;",
                  "xit_enable:0,false;", "drive:0,100;", "tune_drive:0,10;", "start;", "ready;")

    def command(self, text: str):
        for raw in text.split(";"):
            raw = raw.strip()
            if not raw:
                continue
            log.debug("TCI <- %s;", raw)
            name, _, rest = raw.partition(":")
            name = name.lower()
            a = [x.strip() for x in rest.split(",")] if rest else []
            try:
                self._command(name, a)
            except (ValueError, IndexError) as e:
                log.info("TCI: ignored '%s;' (%s)", raw, e)

    def _command(self, name: str, a: list):
        if name == "vfo":
            ch = int(a[1]) if len(a) > 1 else 0
            if len(a) > 2:
                f = int(float(a[2]))
                if ch == 0:
                    self.cat.freq = f
                    self.cat.send("FA%011d;" % f)
                else:
                    self.vfo_b = f
            f = self.cat.freq if ch == 0 else (self.vfo_b or self.cat.freq)
            if ch == 0:
                self.sent_freq = f
            self.send("vfo:0,%d,%d;" % (ch, f))
        elif name == "dds":
            if len(a) > 1:
                self.cat.freq = int(float(a[1]))
                self.cat.send("FA%011d;" % self.cat.freq)
            self.sent_freq = self.cat.freq
            self.send("dds:0,%d;" % self.cat.freq)
        elif name == "modulation":
            if len(a) > 1:
                m = a[1].lower()
                md = MOD_TO_MD.get(m)
                if md:
                    self.cat.md = md
                    self.cat.send("MD%s;" % md)
                    self.sent_mod = m
                    self.send("modulation:0,%s;" % m)
                    return
            self.send("modulation:0,%s;" % self.mod())
        elif name == "trx":
            if len(a) > 1:
                self.key(a[1].lower() == "true")
            self.send("trx:0,%s;" % ("true" if self.keyed else "false"))
        elif name == "tune":
            if len(a) > 1:
                self.tune = a[1].lower() == "true"
                self.key(self.tune)
            self.send("tune:0,%s;" % ("true" if self.tune else "false"))
        elif name == "split_enable":
            self.send("split_enable:0,false;")
        elif name == "audio_start":
            self.audio_on = True
            self.send("audio_start:0;")
            log.info("TCI: receive audio started")
        elif name == "audio_stop":
            self.audio_on = False
            self.send("audio_stop:0;")
        elif name == "audio_samplerate":
            self.send("audio_samplerate:%d;" % SAMPLE_RATE)
        elif name in ("audio_stream_sample_type", "audio_stream_channels", "audio_stream_samples"):
            self.send("%s:%s;" % (name, ",".join(a)))
        elif name == "rx_smeter":
            self.send("rx_smeter:0,0,%d;" % round(self.iq.demod.level_db - 50))
        elif name == "rx_enable":
            rx = a[0] if a else "0"
            self.send("rx_enable:%s,%s;" % (rx, "true" if rx == "0" else "false"))
        elif name in ("start", "stop"):
            self.send("start;")          # the QMX is never powered off from here
        elif name in ("drive", "tune_drive", "volume", "mute", "rx_mute", "rit_enable",
                      "xit_enable", "rit_offset", "xit_offset", "agc_mode", "agc_gain",
                      "lock", "sql_enable", "sql_level", "rx_sensors_enable", "tx_sensors_enable",
                      "app_focus"):
            if a:
                self.send("%s:%s;" % (name, ",".join(a)))
        # anything else (iq_start, spot, cw_macros ...) is not supported and ignored

    # -- connection handling -------------------------------------------------

    def serve_client(self, conn: socket.socket, peer):
        if not WebSocket.handshake(conn):
            conn.close()
            return
        ws = WebSocket(conn)
        if self.ws:
            log.info("TCI: a new program connected - closing the previous one")
            self.ws.close()
        self.ws = ws
        log.info("TCI: %s:%d connected", peer[0], peer[1])
        self.cat.send("FA;MD;")
        time.sleep(0.15)                 # let the radio's frequency and mode arrive first
        self.hello()
        try:
            while ws.alive:
                kind, data = ws.recv()
                if kind == "text":
                    self.command(data)
                else:
                    self.tx_audio(data)
        except (WsClosed, OSError) as e:
            log.info("TCI: %s:%d disconnected (%s)", peer[0], peer[1], e)
        finally:
            if self.ws is ws:
                self.ws = None
                self.audio_on = False
                if self.keyed:
                    self.key(False)
                self.cat.close()         # release port 3 while no program uses it
            ws.alive = False
            try:
                conn.close()
            except OSError:
                pass

    def _poll(self):
        while True:
            time.sleep(1.0)
            if self.ws and not self.keyed:
                self.cat.send("FA;MD;")

    def run(self):
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind((self.args.tci_listen, self.args.tci_port))
        srv.listen(2)
        log.info("TCI server on ws://%s:%d - in WS/WSJT-X choose Rig 'TCI Client RX1', "
                 "server %s:%d", self.args.tci_listen, self.args.tci_port,
                 self.args.tci_listen, self.args.tci_port)
        threading.Thread(target=self._poll, daemon=True, name="poll").start()
        while True:
            conn, peer = srv.accept()
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            threading.Thread(target=self.serve_client, args=(conn, peer), daemon=True,
                             name="tci-client").start()

#!/usr/bin/env python3
"""Bench test for the TCI server (qmx_serial_bridge.py --tci) against the relay's
fake radio. Acts like WS/WSJT-X: connects, starts audio, sets frequency and
mode, checks the receive audio has the fake signal at the expected pitch, then
transmits a short FT8-like GFSK sequence and prints what the server measured.

    QMX_FAKE_TONE_HZ=13500 python3 ../nas-relay/qmx_nas_relay.py --fake --catlog-dir /tmp/cl &
    python3 qmx_serial_bridge.py --tci --host 127.0.0.1 &
    python3 test/tci_client_test.py
"""
import base64
import math
import os
import socket
import struct
import sys
import time

import numpy as np

HDR = struct.Struct("<16I")


class Ws:
    def __init__(self, host="127.0.0.1", port=40001):
        self.s = socket.create_connection((host, port), 5)
        key = base64.b64encode(os.urandom(16))
        self.s.sendall(b"GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                       b"Sec-WebSocket-Key: " + key + b"\r\nSec-WebSocket-Version: 13\r\n\r\n")
        r = b""
        while b"\r\n\r\n" not in r:
            r += self.s.recv(1024)
        assert b" 101 " in r.split(b"\r\n")[0], r
        self.rest = r.split(b"\r\n\r\n", 1)[1]

    def _x(self, n):
        while len(self.rest) < n:
            c = self.s.recv(65536)
            if not c:
                raise EOFError
            self.rest += c
        d, self.rest = self.rest[:n], self.rest[n:]
        return d

    def recv(self):
        b0, b1 = self._x(2)
        n = b1 & 0x7F
        if n == 126:
            n = struct.unpack(">H", self._x(2))[0]
        elif n == 127:
            n = struct.unpack(">Q", self._x(8))[0]
        d = self._x(n)
        return (b0 & 0x0F), d

    def send(self, op, data):
        m = os.urandom(4)
        n = len(data)
        h = bytes([0x80 | op]) + (bytes([0x80 | n]) if n < 126 else
                                  bytes([0x80 | 126]) + struct.pack(">H", n) if n < 65536 else
                                  bytes([0x80 | 127]) + struct.pack(">Q", n))
        a = np.frombuffer(data, np.uint8) ^ np.frombuffer((m * (n // 4 + 1))[:n], np.uint8)
        self.s.sendall(h + m + a.tobytes())

    def text(self, t):
        self.send(1, t.encode())


def main():
    ws = Ws()
    t0 = time.monotonic()
    texts = []
    while True:
        op, d = ws.recv()
        if op == 1:
            texts.append(d.decode())
            if d == b"ready;":
                break
    print("init (%d messages): %s" % (len(texts), " ".join(texts)))
    for c in ("split_enable:false;", "audio_start:0;", "vfo:0,0,14074000;", "modulation:0,digu;",
              "rx_smeter:0,0;"):
        ws.text(c)
    audio = []
    replies = []
    end = time.monotonic() + 2.5
    while time.monotonic() < end:
        op, d = ws.recv()
        if op == 1:
            replies.append(d.decode())
        elif op == 2:
            h = HDR.unpack_from(d)
            if h[6] == 1:
                audio.append(np.frombuffer(d, "<f4", count=h[5], offset=64)[0::2])
    print("replies:", " ".join(replies))
    a = np.concatenate(audio) if audio else np.zeros(1)
    print("RX audio: %d frames, %.2f s, rms %.3f" % (len(audio), len(a) / 48000, float(np.sqrt(np.mean(a * a)))))
    if len(a) > 48000:
        seg = a[-48000:] * np.hanning(48000)
        sp = np.abs(np.fft.rfft(seg))
        pk = int(np.argmax(sp))
        print("RX audio peak at %d Hz (expect 1500 with QMX_FAKE_TONE_HZ=13500)" % pk)

    # transmit: 0.3 s silence, then 12 GFSK tones of 160 ms around 1500 Hz, like FT8
    tones = [3, 1, 4, 0, 6, 5, 2, 7, 3, 3, 0, 1]
    base, sp_hz, nsps = 1500.0, 6.25, 7680          # 160 ms at 48 kHz
    fpath = np.repeat(np.array(tones, float), nsps)
    g = np.exp(-0.5 * (np.arange(-1500, 1501) / 600.0) ** 2)     # smooth the steps (GFSK-like)
    fpath = np.convolve(np.pad(fpath, 1500, mode="edge"), g / g.sum(), mode="valid")
    freq = base + sp_hz * fpath
    sig = np.concatenate((np.zeros(14400), 0.5 * np.sin(2 * np.pi * np.cumsum(freq) / 48000), np.zeros(4800)))
    pos = 0
    ws.text("trx:0,true;")
    print("TX: keyed at %.2f s" % (time.monotonic() - t0))
    tx_start = None
    while pos < len(sig):
        op, d = ws.recv()
        if op == 2:
            h = HDR.unpack_from(d)
            if h[6] == 3:
                n = h[5] // 2
                chunk = sig[pos:pos + n]
                if len(chunk) < n:
                    chunk = np.pad(chunk, (0, n - len(chunk)))
                if tx_start is None:
                    tx_start = time.monotonic()
                pos += n
                st = np.empty(2 * n, np.float32)
                st[0::2] = chunk
                st[1::2] = chunk
                ws.send(2, HDR.pack(0, 48000, 3, 0, 0, 2 * n, 2, *([0] * 9)) + st.tobytes())
    took = time.monotonic() - tx_start
    ws.text("trx:0,false;")
    time.sleep(0.5)
    print("TX: sent %.2f s of audio in %.2f s (real-time pacing)" % (len(sig) / 48000, took))
    print("expected tones: %s" % ", ".join("%.2f" % (base + sp_hz * t) for t in tones))
    ws.s.close()


if __name__ == "__main__":
    main()

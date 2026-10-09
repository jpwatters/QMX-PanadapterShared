#!/usr/bin/env python3
"""
qmx_nas_relay.py - serve a QMX/QMX+ plugged into a Synology NAS to the
QMX-Panadapter (M5Stack Tab5) over the network.

    QMX --USB--> Synology NAS (this relay, run natively or in Docker)
                     |  QMXR/1 framed TCP, port 7355
                     v
              Tab5 QMX-Panadapter  (Radio source: NAS)

The relay owns the QMX directly from userspace, so it needs no DSM kernel
drivers (no cdc_acm / snd-usb-audio). It uses libusb-1.0 (python-libusb1)
when that loads, and otherwise talks to Linux usbfs (/dev/bus/usb) itself
through ioctl() - which is what runs on NAS models without libusb-1.0, such
as the DS416j (QMX_BACKEND=libusb|usbfs forces one):

  * CAT:  CDC-ACM data interface, bulk IN/OUT endpoints (38400 8N1 set for
          completeness - it's a virtual COM port).
  * I/Q:  UAC streaming interface, isochronous IN, 48 kHz stereo 24-bit.
          Converted to int16 exactly like the firmware's USB path (s24 >> 8).
  * Terminal: the QMX's optional SECOND serial port (radio set to "USB serial
          ports" = 2 or 3; on USB it is interface 5), opened on request for the
          Tab5's "Radio menus" and carried as its own stream, never mixed
          with CAT - exactly why the firmware uses port 2 on USB.
  * Port 3: with "USB serial ports" = 3 the QMX's THIRD serial port is served
          as a plain TCP serial port (default 7356) for PC software - WSJT-X,
          rigctld, a terminal - so a PC can control the radio at the same
          time as the Tab5, on its own port.

Wire format (QMXR/1): every frame = 4-byte header + payload
     u8  type   1=HELLO 2=IQ 3=CAT 4=PING
                5=TERM_OPEN 6=TERM_STATUS 7=TERM_DATA 8=TERM_CLOSE
     u8  flags  0
     u16 len    payload length, little-endian
  Tab5 -> relay : HELLO "QMXR/1 ...", then CAT bytes
  relay -> Tab5 : HELLO "QMXR/1 rate=48000 ch=2 fmt=s16le term=1", then IQ / CAT / PING
  Terminal (second serial port), Tab5-initiated:
    Tab5 -> relay : TERM_OPEN            relay -> Tab5 : TERM_STATUS u8 ok [+ reason]
    both ways     : TERM_DATA bytes      Tab5 -> relay : TERM_CLOSE
    relay -> Tab5 : TERM_STATUS 0 unsolicited if the port goes away while open

The relay only answers the Tab5's HELLO after it has opened the QMX, and it
closes the connection as soon as the QMX goes away, so for the Tab5 an open
session means "radio present" - exactly like a USB plug/unplug.

One Tab5 at a time and one port-3 client at a time; a new connection replaces
an old one (e.g. after a reboot left a half-dead socket). The QMX is opened when
the first of them connects and released when the last one leaves.

Requirements: Python 3.8+. Nothing else on Linux (usbfs backend); on other
systems libusb-1.0 + `pip install libusb1` (the Dockerfile installs both).
"""

from __future__ import annotations

import argparse
import collections
import ctypes
import errno
import logging
import math
import os
import queue
import select
import socket
import struct
import sys
import threading
import time

log = logging.getLogger("qmx-nas-relay")

PROTO_HELLO, PROTO_IQ, PROTO_CAT, PROTO_PING = 1, 2, 3, 4
PROTO_TERM_OPEN, PROTO_TERM_STATUS, PROTO_TERM_DATA, PROTO_TERM_CLOSE = 5, 6, 7, 8
HDR = struct.Struct("<BBH")
DEFAULT_PORT = 7355
DEFAULT_SERIAL_PORT = 7356     # QMX port 3 as raw TCP serial for PCs
QMX_VID, QMX_PID = 0x0483, 0xA34C
SAMPLE_RATE = 48000
FRAME_PAIRS = 480            # 10 ms of I/Q per IQ frame (1920 bytes)
IQ_QUEUE_MAX = 3             # I/Q frames (30 ms) waiting to be sent; beyond that drop I/Q, never CAT
TAB5_SNDBUF = 8192           # kernel send buffer per Tab5 (Linux doubles it): keeps the
                             # backlog - and so the CAT reply delay - under ~0.2 s
ISO_TRANSFERS = 8            # in flight
ISO_PACKETS = 8              # 1 ms each -> 8 ms per transfer
CAT_BAUD = 38400


def frame(ftype: int, payload: bytes = b"") -> bytes:
    if len(payload) > 0xFFFF:
        raise ValueError("payload too large")
    return HDR.pack(ftype, 0, len(payload)) + payload


def recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("peer closed")
        buf += chunk
    return bytes(buf)


def to_s16(raw: bytes, subframe: int) -> bytes:
    """Interleaved PCM -> interleaved int16 LE, matching the firmware's USB
    path: 24-bit samples keep (s24 >> 8) = the upper two bytes; 32-bit keep
    (s32 >> 16); 16-bit pass through."""
    if subframe == 2:
        return bytes(raw[: len(raw) // 2 * 2])
    n = len(raw) // subframe
    out = bytearray(n * 2)
    out[0::2] = raw[subframe - 2: n * subframe: subframe]
    out[1::2] = raw[subframe - 1: n * subframe: subframe]
    return bytes(out)


# ---------------------------------------------------------------------------
# Radio backends
# ---------------------------------------------------------------------------

class RadioGone(Exception):
    pass


class QmxUsb:
    """The real QMX over libusb. on_iq(bytes s16) / on_cat(bytes) are called
    from the libusb event thread; on_gone() once if the device disappears."""

    def __init__(self, on_iq, on_cat, on_gone, vid=QMX_VID, pid=QMX_PID):
        import usb1  # imported here so --fake works without libusb
        _load_libusb(usb1)
        self.usb1 = usb1
        self.on_iq, self.on_cat, self.on_gone = on_iq, on_cat, on_gone
        self.vid, self.pid = vid, pid
        self.ctx = usb1.USBContext()
        self.h = None
        self.running = False
        self.claimed: list[int] = []
        self.transfers = []
        self.gone_reported = False
        self.evt_thread = None
        self.cdc_ports = []          # [(comm_if, data_if, bulk_in, bulk_out)] in interface order
        # Extra serial ports, by index into cdc_ports: 1 = port 2 (terminal), 2 = port 3 (PC).
        self.extra: dict[int, dict] = {}

    # -- descriptor discovery --------------------------------------------
    def _discover(self, dev):
        return discover_qmx(dev[0])

    # -- open / close ------------------------------------------------------
    def open(self):
        usb1 = self.usb1
        h = self.ctx.openByVendorIDAndProductID(self.vid, self.pid, skip_on_error=True)
        if h is None:
            raise RadioGone("QMX (%04x:%04x) not found on the NAS USB bus" % (self.vid, self.pid))
        self.h = h
        dev = h.getDevice()
        self.cdc_ports, uac2, aud = self._discover(dev)
        if not self.cdc_ports or aud is None:
            self.close()
            raise RadioGone("QMX descriptors not recognised (CAT=%s audio=%s)" % (self.cdc_ports, aud))
        cdc_ctrl, cdc_data, self.bulk_in, self.bulk_out = self.cdc_ports[0]
        as_if, alt, self.iso_ep, self.iso_mps, ch, self.subframe, bits, rates = aud
        log.info("QMX found: CAT if%d (IN 0x%02x OUT 0x%02x), I/Q if%d alt%d EP 0x%02x mps=%d %dch %d-bit/%dB %s%s",
                 cdc_data, self.bulk_in, self.bulk_out, as_if, alt, self.iso_ep, self.iso_mps,
                 ch, bits, self.subframe, rates or "", " UAC2" if uac2 else "")
        n = len(self.cdc_ports)
        log.info("QMX USB serial ports: %d (%s)", n, ", ".join(
            "port %d = if%s/if%d" % (i + 1, c, d) for i, (c, d, _, _) in enumerate(self.cdc_ports)))
        if n < 2:
            log.info("Radio menus need 'USB serial ports' = 2 or 3 on the radio")
        if n < 3:
            log.info("PC serial (port 3) needs 'USB serial ports' = 3 on the radio")
        if ch != 2:
            log.warning("audio stream has %d channels, expected 2 (I/Q)", ch)
        try:
            h.setAutoDetachKernelDriver(True)   # if DSM bound cdc_acm / snd-usb-audio
        except Exception:
            pass
        try:
            for i in [x for x in (cdc_ctrl, cdc_data, as_if) if x is not None]:
                h.claimInterface(i)
                self.claimed.append(i)
        except usb1.USBErrorBusy:
            self.close()
            raise RadioGone("QMX is in use by another program on the NAS - stop it, then reconnect")
        except usb1.USBErrorAccess:
            self.close()
            raise RadioGone("no permission for USB - run the container privileged")

        # CAT: line coding 38400 8N1 + DTR/RTS (same as the firmware's USB path).
        if cdc_ctrl is not None:
            try:
                h.controlWrite(0x21, 0x20, 0, cdc_ctrl, struct.pack("<IBBB", CAT_BAUD, 0, 0, 8), timeout=500)
                h.controlWrite(0x21, 0x22, 0x0003, cdc_ctrl, b"", timeout=500)
            except usb1.USBError as e:
                log.warning("CDC line setup: %s (continuing)", e)

        # I/Q: select the streaming alt setting, ask for 48 kHz (UAC1 endpoint request).
        h.setInterfaceAltSetting(as_if, alt)
        self.as_if = as_if
        if not uac2:
            try:
                h.controlWrite(0x22, 0x01, 0x0100, self.iso_ep, SAMPLE_RATE.to_bytes(3, "little"), timeout=500)
            except usb1.USBError as e:
                log.info("sample-rate SET_CUR not accepted (%s) - device default used", e)

        self.running = True
        self.gone_reported = False
        # Isochronous I/Q transfers.
        for _ in range(ISO_TRANSFERS):
            t = h.getTransfer(iso_packets=ISO_PACKETS)
            t.setIsochronous(self.iso_ep, ISO_PACKETS * self.iso_mps, callback=self._iso_cb)
            t.submit()
            self.transfers.append(t)
        # CAT bulk IN.
        for _ in range(2):
            t = h.getTransfer()
            t.setBulk(self.bulk_in, 64, callback=self._bulk_cb)
            t.submit()
            self.transfers.append(t)
        self.evt_thread = threading.Thread(target=self._events, name="usb-events", daemon=True)
        self.evt_thread.start()

    def _events(self):
        while self.running:
            try:
                self.ctx.handleEventsTimeout(0.1)
            except self.usb1.USBErrorInterrupted:
                continue
            except Exception as e:
                log.warning("libusb event loop: %s", e)
                self._gone()
                return

    def _gone(self):
        if not self.gone_reported:
            self.gone_reported = True
            log.warning("QMX unplugged / powered off")
            self.running = False
            self.on_gone()

    def _resubmit_or_gone(self, t):
        if not self.running:
            return
        try:
            t.submit()
        except self.usb1.USBError as e:
            log.warning("USB resubmit failed: %s", e)
            self._gone()

    def _iso_cb(self, t):
        usb1 = self.usb1
        st = t.getStatus()
        if st == usb1.TRANSFER_COMPLETED:
            raw = bytearray()
            for pst, buf in t.iterISO():
                if pst == usb1.TRANSFER_COMPLETED and buf:
                    raw += buf
            if raw:
                self.on_iq(to_s16(raw, self.subframe))
        elif st == usb1.TRANSFER_NO_DEVICE:
            self._gone()
            return
        elif st == usb1.TRANSFER_CANCELLED:
            return
        self._resubmit_or_gone(t)

    def _bulk_cb(self, t):
        usb1 = self.usb1
        st = t.getStatus()
        if st == usb1.TRANSFER_COMPLETED:
            n = t.getActualLength()
            if n:
                self.on_cat(bytes(t.getBuffer()[:n]))
        elif st == usb1.TRANSFER_NO_DEVICE:
            self._gone()
            return
        elif st == usb1.TRANSFER_CANCELLED:
            return
        self._resubmit_or_gone(t)

    # -- extra serial ports (index 1 = port 2 terminal, index 2 = port 3 PC) --
    def serial_count(self) -> int:
        return len(self.cdc_ports)

    def serial_open(self, idx, on_data):
        """Claim the QMX's serial port number idx+1 and start reading it.
        Returns (ok, reason)."""
        usb1 = self.usb1
        name = "port %d" % (idx + 1)
        st = self.extra.get(idx)
        if st and st["cb"]:
            st["cb"] = on_data
            return True, ""
        if len(self.cdc_ports) <= idx:
            return False, ("the radio has %d USB serial port%s - set 'USB serial ports' to %d"
                           % (len(self.cdc_ports), "" if len(self.cdc_ports) == 1 else "s", idx + 1))
        comm, data, bin_, bout = self.cdc_ports[idx]
        st = {"ifs": [], "transfers": [], "out": bout, "cb": None}
        self.extra[idx] = st
        try:
            for i in [x for x in (comm, data) if x is not None]:
                self.h.claimInterface(i)
                st["ifs"].append(i)
        except usb1.USBErrorBusy:
            self._serial_release(idx)
            return False, "%s is in use by another program on the NAS" % name
        except usb1.USBError as e:
            self._serial_release(idx)
            return False, "%s claim failed: %s" % (name, e)
        if comm is not None:
            try:
                self.h.controlWrite(0x21, 0x20, 0, comm, struct.pack("<IBBB", CAT_BAUD, 0, 0, 8), timeout=500)
                self.h.controlWrite(0x21, 0x22, 0x0003, comm, b"", timeout=500)
            except usb1.USBError as e:
                log.warning("%s line setup: %s (continuing)", name, e)
        st["cb"] = on_data
        for _ in range(2):
            t = self.h.getTransfer()
            t.setBulk(bin_, 512, callback=self._serial_cb, user_data=idx)
            t.submit()
            st["transfers"].append(t)
        log.info("QMX %s open (if%s/if%d)", name, comm, data)
        return True, ""

    def _serial_cb(self, t):
        usb1 = self.usb1
        idx = t.getUserData()
        st = self.extra.get(idx)
        status = t.getStatus()
        if status == usb1.TRANSFER_COMPLETED:
            n = t.getActualLength()
            cb = st["cb"] if st else None
            if n and cb:
                cb(bytes(t.getBuffer()[:n]))
        elif status == usb1.TRANSFER_NO_DEVICE:
            self._gone()
            return
        elif status == usb1.TRANSFER_CANCELLED:
            return
        if st and st["cb"]:
            self._resubmit_or_gone(t)

    def serial_send(self, idx, data: bytes):
        st = self.extra.get(idx)
        if not self.h or not st or not st["cb"]:
            return
        try:
            self.h.bulkWrite(st["out"], data, timeout=500)
        except self.usb1.USBErrorNoDevice:
            self._gone()
            raise RadioGone("QMX gone")
        except self.usb1.USBError as e:
            log.warning("port %d write: %s", idx + 1, e)

    def serial_close(self, idx):
        st = self.extra.get(idx)
        if not st:
            return
        st["cb"] = None
        for t in st["transfers"]:
            try:
                if t.isSubmitted():
                    t.cancel()
            except Exception:
                pass
        deadline = time.time() + 1.0
        while time.time() < deadline and any(_submitted(t) for t in st["transfers"]):
            time.sleep(0.02)          # the event thread completes the cancellations
        st["transfers"] = []
        self._serial_release(idx)
        log.info("QMX port %d closed", idx + 1)

    def _serial_release(self, idx):
        st = self.extra.pop(idx, None)
        if not st:
            return
        for i in st["ifs"]:
            try:
                self.h.releaseInterface(i)
            except Exception:
                pass

    # Terminal = port 2 (kept as names the Tab5 session uses).
    def term_open(self, on_data):
        return self.serial_open(1, on_data)

    def term_send(self, data: bytes):
        self.serial_send(1, data)

    def term_close(self):
        self.serial_close(1)

    def send_cat(self, data: bytes):
        if not self.h:
            raise RadioGone("closed")
        try:
            self.h.bulkWrite(self.bulk_out, data, timeout=500)
        except self.usb1.USBErrorNoDevice:
            self._gone()
            raise RadioGone("QMX gone")

    def close(self):
        self.running = False
        for st in self.extra.values():
            st["cb"] = None
            self.transfers += st["transfers"]
            self.claimed += st["ifs"]
        self.extra = {}
        for t in self.transfers:
            try:
                if t.isSubmitted():
                    t.cancel()
            except Exception:
                pass
        # Let cancellations complete before freeing.
        deadline = time.time() + 1.0
        while time.time() < deadline and any(_submitted(t) for t in self.transfers):
            try:
                self.ctx.handleEventsTimeout(0.05)
            except Exception:
                break
        if self.evt_thread and self.evt_thread is not threading.current_thread():
            self.evt_thread.join(timeout=1.0)
        self.transfers = []
        if self.h:
            try:
                if getattr(self, "as_if", None) is not None:
                    self.h.setInterfaceAltSetting(self.as_if, 0)
            except Exception:
                pass
            for i in self.claimed:
                try:
                    self.h.releaseInterface(i)
                except Exception:
                    pass
            self.claimed = []
            try:
                self.h.close()
            except Exception:
                pass
            self.h = None


def _load_libusb(usb1):
    """Use QMX_LIBUSB=/path/libusb-1.0.so.0 if set (e.g. a NAS whose libusb is
    not on the default search path); otherwise python-libusb1's own lookup."""
    path = os.environ.get("QMX_LIBUSB")
    if path and not getattr(usb1, "_qmx_loaded", False):
        usb1.loadLibrary(path)
        usb1._qmx_loaded = True


def _submitted(t) -> bool:
    try:
        return t.isSubmitted()
    except Exception:
        return False


def _split_descs(extra) -> list[bytes]:
    """getExtra() may return one blob or a list of descriptor blobs."""
    blobs = extra if isinstance(extra, (list, tuple)) else [extra]
    out = []
    for b in blobs:
        b = bytes(b)
        i = 0
        while i + 2 <= len(b) and b[i] >= 2:
            out.append(b[i:i + b[i]])
            i += b[i]
    return out


def discover_qmx(config):
    """config = list of interfaces, each a list of alt settings (python-libusb1 or
    usbfs shim objects). Returns (cdc_ports, uac2, best audio-in candidate)."""
    comms, datas = [], []
    uac2 = False
    best = None   # (iface, alt, ep, mps, channels, subframe, bits, rates)
    for iface in config:
        for s in iface:
            cls, sub, num, alt = s.getClass(), s.getSubClass(), s.getNumber(), s.getAlternateSetting()
            if cls == 0x02 and sub == 0x02 and alt == 0:
                comms.append(num)
            elif cls == 0x0A and alt == 0:
                bin_ = bout = None
                for ep in s:
                    a, attr = ep.getAddress(), ep.getAttributes() & 3
                    if attr == 2:
                        if a & 0x80:
                            bin_ = a
                        else:
                            bout = a
                if bin_ and bout:
                    datas.append((num, bin_, bout))
            elif cls == 0x01 and sub == 0x01 and s.getProtocol() == 0x20:
                uac2 = True
            elif cls == 0x01 and sub == 0x02 and alt > 0:
                iso_in = [ep for ep in s
                          if (ep.getAddress() & 0x80) and (ep.getAttributes() & 3) == 1]
                if not iso_in:
                    continue
                ch, subframe, bits, rates = 2, 3, 24, []
                for d in _split_descs(s.getExtra()):
                    # UAC1 Format Type I: len, 0x24, 0x02, 0x01, nCh, subframe, bits, nFreq, freqs...
                    if len(d) >= 8 and d[1] == 0x24 and d[2] == 0x02 and d[3] == 0x01:
                        ch, subframe, bits, nf = d[4], d[5], d[6], d[7]
                        rates = [d[8 + 3 * i] | d[9 + 3 * i] << 8 | d[10 + 3 * i] << 16
                                 for i in range(nf) if 10 + 3 * i < len(d)]
                    # UAC2 Format Type I: len, 0x24, 0x02, 0x01, subslot, bits
                    elif len(d) == 6 and d[1] == 0x24 and d[2] == 0x02 and d[3] == 0x01:
                        subframe, bits = d[4], d[5]
                    # UAC2 AS_GENERAL carries bNrChannels at offset 10
                    elif len(d) >= 11 and d[1] == 0x24 and d[2] == 0x01 and d[0] == 16:
                        ch = d[10]
                ep = iso_in[0]
                cand = (num, alt, ep.getAddress(), ep.getMaxPacketSize() & 0x7FF, ch, subframe, bits, rates)
                # Prefer stereo; the QMX's RX/I-Q stream is the stereo IN one.
                if best is None or (ch == 2 and best[4] != 2):
                    best = cand
    # Pair each CDC comm interface with the data interface that follows it.
    # The QMX's functions are NOT contiguous (CAT 0-1, audio 2-4, port 2 at
    # 5-6), so pair by order, not by number+1.
    comms.sort()
    datas.sort()
    ports = []
    for i, (dnum, bin_, bout) in enumerate(datas):
        ports.append((comms[i] if i < len(comms) else None, dnum, bin_, bout))
    return ports, uac2, best


# ---------------------------------------------------------------------------
# Linux usbfs backend - no libusb needed (DSM ships only libusb-0.1)
# Structures and ioctl numbers follow <linux/usbdevice_fs.h>; ioctl numbers
# use the generic _IOC encoding of x86, ARM and arm64.
# ---------------------------------------------------------------------------

c_u8, c_u16, c_u32, c_int, c_void_p = ctypes.c_uint8, ctypes.c_uint16, ctypes.c_uint32, ctypes.c_int, ctypes.c_void_p


# ---- <linux/usbdevice_fs.h> ------------------------------------------------

class CtrlTransfer(ctypes.Structure):
    _fields_ = [("bRequestType", c_u8), ("bRequest", c_u8), ("wValue", c_u16), ("wIndex", c_u16),
                ("wLength", c_u16), ("timeout", c_u32), ("data", c_void_p)]


class BulkTransfer(ctypes.Structure):
    _fields_ = [("ep", c_u32), ("len", c_u32), ("timeout", c_u32), ("data", c_void_p)]


class SetInterface(ctypes.Structure):
    _fields_ = [("interface", c_u32), ("altsetting", c_u32)]


class IsoPacketDesc(ctypes.Structure):
    _fields_ = [("length", c_u32), ("actual_length", c_u32), ("status", c_u32)]


_URB_FIELDS = [("type", c_u8), ("endpoint", c_u8), ("status", c_int), ("flags", c_u32),
               ("buffer", c_void_p), ("buffer_length", c_int), ("actual_length", c_int),
               ("start_frame", c_int), ("number_of_packets", c_int), ("error_count", c_int),
               ("signr", c_u32), ("usercontext", c_void_p)]


class Urb(ctypes.Structure):
    _fields_ = _URB_FIELDS


def iso_urb_type(npackets):
    class IsoUrb(ctypes.Structure):
        _fields_ = _URB_FIELDS + [("iso_frame_desc", IsoPacketDesc * npackets)]
    return IsoUrb


class UsbdevfsIoctl(ctypes.Structure):
    _fields_ = [("ifno", c_int), ("ioctl_code", c_int), ("data", c_void_p)]


def _IOC(d, t, nr, size):
    return (d << 30) | (size << 16) | (ord(t) << 8) | nr


_R, _W = 2, 1
USBDEVFS_CONTROL = _IOC(_R | _W, "U", 0, ctypes.sizeof(CtrlTransfer))
USBDEVFS_BULK = _IOC(_R | _W, "U", 2, ctypes.sizeof(BulkTransfer))
USBDEVFS_SETINTERFACE = _IOC(_R, "U", 4, ctypes.sizeof(SetInterface))
USBDEVFS_SUBMITURB = _IOC(_R, "U", 10, ctypes.sizeof(Urb))
USBDEVFS_DISCARDURB = _IOC(0, "U", 11, 0)
USBDEVFS_REAPURBNDELAY = _IOC(_W, "U", 13, ctypes.sizeof(c_void_p))
USBDEVFS_CLAIMINTERFACE = _IOC(_R, "U", 15, ctypes.sizeof(ctypes.c_uint))
USBDEVFS_RELEASEINTERFACE = _IOC(_R, "U", 16, ctypes.sizeof(ctypes.c_uint))
USBDEVFS_IOCTL = _IOC(_R | _W, "U", 18, ctypes.sizeof(UsbdevfsIoctl))
USBDEVFS_DISCONNECT = _IOC(0, "U", 22, 0)
USBDEVFS_CONNECT = _IOC(0, "U", 23, 0)

URB_TYPE_ISO, URB_TYPE_BULK = 0, 3
URB_ISO_ASAP = 0x02

_libc = ctypes.CDLL(None, use_errno=True)
_ioctl = _libc.ioctl
_ioctl.argtypes = [c_int, ctypes.c_ulong, c_void_p]
_ioctl.restype = c_int


class UsbfsError(OSError):
    pass


def ioctl(fd, req, arg):
    """ioctl with a real pointer (fcntl.ioctl copies small buffers, which
    breaks async URBs whose address the kernel keeps)."""
    ptr = None if arg is None else (arg if isinstance(arg, int) else ctypes.addressof(arg))
    r = _ioctl(fd, req, ptr)
    if r < 0:
        e = ctypes.get_errno()
        raise UsbfsError(e, os.strerror(e))
    return r


# ---- device discovery from sysfs + raw descriptors --------------------------

SYS_USB = "/sys/bus/usb/devices"


def usbfs_find_device(vid, pid):
    """Return (sysfs name, /dev/bus/usb path) of the first matching device."""
    try:
        names = sorted(os.listdir(SYS_USB))
    except OSError:
        return None
    for name in names:
        d = os.path.join(SYS_USB, name)
        try:
            v = int(open(os.path.join(d, "idVendor")).read(), 16)
            p = int(open(os.path.join(d, "idProduct")).read(), 16)
            if (v, p) != (vid, pid):
                continue
            bus = int(open(os.path.join(d, "busnum")).read())
            dev = int(open(os.path.join(d, "devnum")).read())
        except (OSError, ValueError):
            continue
        return name, "/dev/bus/usb/%03d/%03d" % (bus, dev)
    return None


def usbfs_list_devices():
    out = []
    try:
        names = sorted(os.listdir(SYS_USB))
    except OSError:
        return out
    for name in names:
        d = os.path.join(SYS_USB, name)
        try:
            v = int(open(os.path.join(d, "idVendor")).read(), 16)
            p = int(open(os.path.join(d, "idProduct")).read(), 16)
            bus = int(open(os.path.join(d, "busnum")).read())
            dev = int(open(os.path.join(d, "devnum")).read())
        except (OSError, ValueError):
            continue
        out.append((bus, dev, v, p, name))
    return out


class UsbfsEndpoint:
    def __init__(self, addr, attrs, mps):
        self.a, self.attrs, self.mps = addr, attrs, mps

    def getAddress(self):
        return self.a

    def getAttributes(self):
        return self.attrs

    def getMaxPacketSize(self):
        return self.mps


class UsbfsSetting(list):
    """An interface alternate setting; iterates over its endpoints. Same
    accessor names as python-libusb1, so the relay's discovery code is shared."""

    def __init__(self, num, alt, cls, sub, proto):
        super().__init__()
        self.v = (num, alt, cls, sub, proto)
        self.extra = b""

    def getNumber(self):
        return self.v[0]

    def getAlternateSetting(self):
        return self.v[1]

    def getClass(self):
        return self.v[2]

    def getSubClass(self):
        return self.v[3]

    def getProtocol(self):
        return self.v[4]

    def getExtra(self):
        return [self.extra] if self.extra else []


def usbfs_parse_config(raw: bytes):
    """Raw descriptors (device descriptor, then the first configuration) ->
    list of interfaces, each a list of Settings."""
    i = 0
    # skip the device descriptor
    if len(raw) >= 2 and raw[1] == 1:
        i = raw[0]
    ifaces: dict = {}
    cur = None
    seen_config = False
    while i + 2 <= len(raw):
        ln, typ = raw[i], raw[i + 1]
        if ln < 2:
            break
        d = raw[i:i + ln]
        if typ == 2:                      # CONFIGURATION
            if seen_config:
                break                     # only the first configuration
            seen_config = True
        elif typ == 4 and ln >= 9:        # INTERFACE
            cur = UsbfsSetting(d[2], d[3], d[5], d[6], d[7])
            ifaces.setdefault(d[2], []).append(cur)
        elif typ == 5 and ln >= 7 and cur is not None:   # ENDPOINT
            cur.append(UsbfsEndpoint(d[2], d[3], d[4] | d[5] << 8))
        elif cur is not None and typ in (0x24, 0x25):    # class-specific
            cur.extra += bytes(d)
        i += ln
    return [ifaces[k] for k in sorted(ifaces)]


# ---- the device ---------------------------------------------------------------

class UsbfsDevice:
    """Minimal async usbfs device: control/bulk sync calls plus bulk/iso URBs
    completed on a reaper thread that calls each URB's callback."""

    def __init__(self, path):
        self.path = path
        self.fd = os.open(path, os.O_RDWR)
        self.lock = threading.Lock()
        self.pending: dict = {}          # urb address -> (urb, buffer, callback)
        self.running = True
        self.gone = False
        self.on_gone = None
        self.reaper = threading.Thread(target=self._reap_loop, name="usbfs-reaper", daemon=True)
        self.reaper.start()

    def read_descriptors(self) -> bytes:
        os.lseek(self.fd, 0, os.SEEK_SET)
        chunks = []
        while True:
            b = os.read(self.fd, 4096)
            if not b:
                break
            chunks.append(b)
        return b"".join(chunks)

    # interfaces
    def detach_kernel_driver(self, ifno):
        req = UsbdevfsIoctl(ifno, USBDEVFS_DISCONNECT, None)
        try:
            ioctl(self.fd, USBDEVFS_IOCTL, req)
        except UsbfsError as e:
            if e.errno not in (errno.ENODATA, errno.ENOENT, errno.EINVAL):
                raise

    def attach_kernel_driver(self, ifno):
        req = UsbdevfsIoctl(ifno, USBDEVFS_CONNECT, None)
        try:
            ioctl(self.fd, USBDEVFS_IOCTL, req)
        except UsbfsError:
            pass

    def claim(self, ifno):
        self.detach_kernel_driver(ifno)
        ioctl(self.fd, USBDEVFS_CLAIMINTERFACE, ctypes.c_uint(ifno))

    def release(self, ifno):
        try:
            ioctl(self.fd, USBDEVFS_RELEASEINTERFACE, ctypes.c_uint(ifno))
        except UsbfsError:
            pass

    def set_altsetting(self, ifno, alt):
        ioctl(self.fd, USBDEVFS_SETINTERFACE, SetInterface(ifno, alt))

    # synchronous transfers
    def control_write(self, rt, req, val, idx, data: bytes, timeout_ms=500):
        buf = ctypes.create_string_buffer(bytes(data), max(1, len(data)))
        ct = CtrlTransfer(rt, req, val, idx, len(data), timeout_ms, ctypes.addressof(buf) if data else None)
        return ioctl(self.fd, USBDEVFS_CONTROL, ct)

    def bulk_write(self, ep, data: bytes, timeout_ms=500):
        buf = ctypes.create_string_buffer(bytes(data), max(1, len(data)))
        bt = BulkTransfer(ep, len(data), timeout_ms, ctypes.addressof(buf))
        return ioctl(self.fd, USBDEVFS_BULK, bt)

    # asynchronous URBs
    def submit_bulk_in(self, ep, length, callback):
        buf = ctypes.create_string_buffer(length)
        urb = Urb()
        urb.type, urb.endpoint, urb.buffer, urb.buffer_length = URB_TYPE_BULK, ep, ctypes.addressof(buf), length
        self._submit(urb, buf, callback)

    def submit_iso_in(self, ep, npackets, mps, callback):
        T = iso_urb_type(npackets)
        buf = ctypes.create_string_buffer(npackets * mps)
        urb = T()
        urb.type, urb.endpoint, urb.flags = URB_TYPE_ISO, ep, URB_ISO_ASAP
        urb.buffer, urb.buffer_length, urb.number_of_packets = ctypes.addressof(buf), npackets * mps, npackets
        for k in range(npackets):
            urb.iso_frame_desc[k].length = mps
        self._submit(urb, buf, callback)

    def _submit(self, urb, buf, callback):
        addr = ctypes.addressof(urb)
        with self.lock:
            self.pending[addr] = (urb, buf, callback)
        try:
            ioctl(self.fd, USBDEVFS_SUBMITURB, urb)
        except UsbfsError:
            with self.lock:
                self.pending.pop(addr, None)
            raise

    def resubmit(self, urb, buf, callback):
        if self.running and not self.gone:
            # reset per-transfer fields before reuse
            urb.status = 0
            urb.actual_length = 0
            urb.error_count = 0
            if urb.type == URB_TYPE_ISO:
                for k in range(urb.number_of_packets):
                    urb.iso_frame_desc[k].actual_length = 0
                    urb.iso_frame_desc[k].status = 0
            self._submit(urb, buf, callback)

    def discard_all(self, callbacks=None):
        """Cancel pending URBs (all, or only those with the given callbacks)."""
        with self.lock:
            items = [(a, u) for a, (u, _b, cb) in self.pending.items() if callbacks is None or cb in callbacks]
        for _a, u in items:
            try:
                ioctl(self.fd, USBDEVFS_DISCARDURB, u)
            except UsbfsError:
                pass   # already completed: the reaper will collect it

    def outstanding(self, callbacks=None):
        with self.lock:
            return sum(1 for (_u, _b, cb) in self.pending.values() if callbacks is None or cb in callbacks)

    def _reap_loop(self):
        p = select.poll()
        p.register(self.fd, select.POLLOUT | select.POLLERR | select.POLLHUP)
        ptr = c_void_p()
        while self.running or self.outstanding():
            try:
                ev = p.poll(100)
            except InterruptedError:
                continue
            if not ev:
                if not self.running and self.gone:
                    break
                continue
            while True:
                try:
                    ioctl(self.fd, USBDEVFS_REAPURBNDELAY, ptr)
                except UsbfsError as e:
                    if e.errno == errno.EAGAIN:
                        break
                    if e.errno == errno.ENODEV:
                        self._mark_gone()
                        with self.lock:
                            self.pending.clear()
                        return
                    break
                with self.lock:
                    entry = self.pending.pop(ptr.value, None)
                if entry:
                    urb, buf, cb = entry
                    try:
                        cb(urb, buf)
                    except Exception:
                        pass
            if any(e & (select.POLLERR | select.POLLHUP) for _fd, e in ev):
                self._mark_gone()
                with self.lock:
                    self.pending.clear()
                return

    def _mark_gone(self):
        if not self.gone:
            self.gone = True
            cb = self.on_gone
            if cb:
                cb()

    def close(self):
        self.running = False
        self.discard_all()
        if self.reaper is not threading.current_thread():
            self.reaper.join(timeout=2.0)
        try:
            os.close(self.fd)
        except OSError:
            pass


class UsbfsQmx:
    """The real QMX through Linux usbfs directly (no libusb). Same interface
    and behaviour as QmxUsb; used where libusb-1.0 isn't installed (DSM)."""

    def __init__(self, on_iq, on_cat, on_gone, vid=QMX_VID, pid=QMX_PID):
        self.on_iq, self.on_cat, self.on_gone = on_iq, on_cat, on_gone
        self.vid, self.pid = vid, pid
        self.dev = None
        self.running = False
        self.gone_reported = False
        self.claimed: list[int] = []
        self.cdc_ports = []
        self.extra: dict[int, dict] = {}
        self.as_if = None

    def open(self):
        found = usbfs_find_device(self.vid, self.pid)
        if not found:
            raise RadioGone("QMX (%04x:%04x) not found on the NAS USB bus" % (self.vid, self.pid))
        name, path = found
        try:
            self.dev = UsbfsDevice(path)
        except PermissionError:
            raise RadioGone("no permission for %s - run the relay as root" % path)
        except OSError as e:
            raise RadioGone("cannot open %s: %s" % (path, e))
        self.dev.on_gone = self._gone
        cfg = usbfs_parse_config(self.dev.read_descriptors())
        self.cdc_ports, uac2, aud = discover_qmx(cfg)
        if not self.cdc_ports or aud is None:
            self.close()
            raise RadioGone("QMX descriptors not recognised (CAT=%s audio=%s)" % (self.cdc_ports, aud))
        cdc_ctrl, cdc_data, self.bulk_in, self.bulk_out = self.cdc_ports[0]
        as_if, alt, self.iso_ep, self.iso_mps, ch, self.subframe, bits, rates = aud
        log.info("QMX found via usbfs %s (%s): CAT if%d (IN 0x%02x OUT 0x%02x), I/Q if%d alt%d EP 0x%02x "
                 "mps=%d %dch %d-bit/%dB %s%s", path, name, cdc_data, self.bulk_in, self.bulk_out, as_if, alt,
                 self.iso_ep, self.iso_mps, ch, bits, self.subframe, rates or "", " UAC2" if uac2 else "")
        n = len(self.cdc_ports)
        log.info("QMX USB serial ports: %d (%s)", n, ", ".join(
            "port %d = if%s/if%d" % (i + 1, c, d) for i, (c, d, _, _) in enumerate(self.cdc_ports)))
        try:
            for i in [x for x in (cdc_ctrl, cdc_data, as_if) if x is not None]:
                self.dev.claim(i)
                self.claimed.append(i)
        except UsbfsError as e:
            self.close()
            if e.errno == errno.EBUSY:
                raise RadioGone("QMX is in use by another program on the NAS - stop it, then reconnect")
            raise RadioGone("claiming the QMX failed: %s" % e)
        if cdc_ctrl is not None:
            try:
                self.dev.control_write(0x21, 0x20, 0, cdc_ctrl, struct.pack("<IBBB", CAT_BAUD, 0, 0, 8))
                self.dev.control_write(0x21, 0x22, 0x0003, cdc_ctrl, b"")
            except UsbfsError as e:
                log.warning("CDC line setup: %s (continuing)", e)
        self.dev.set_altsetting(as_if, alt)
        self.as_if = as_if
        if not uac2:
            try:
                self.dev.control_write(0x22, 0x01, 0x0100, self.iso_ep, SAMPLE_RATE.to_bytes(3, "little"))
            except UsbfsError as e:
                log.info("sample-rate SET_CUR not accepted (%s) - device default used", e)
        self.running = True
        self.gone_reported = False
        for _ in range(ISO_TRANSFERS):
            self.dev.submit_iso_in(self.iso_ep, ISO_PACKETS, self.iso_mps, self._iso_cb)
        for _ in range(2):
            self.dev.submit_bulk_in(self.bulk_in, 64, self._bulk_cb)

    # -- completions (reaper thread) ------------------------------------------
    def _gone(self):
        if not self.gone_reported:
            self.gone_reported = True
            log.warning("QMX unplugged / powered off")
            self.running = False
            self.on_gone()

    def _status_ok(self, urb):
        st = urb.status
        if st in (0, -errno.EXDEV, -errno.EREMOTEIO):   # EXDEV: some iso packets missed; still usable
            return True
        if st in (-errno.ENODEV, -errno.ESHUTDOWN, -errno.EPROTO) and self.running:
            self._gone()                                 # only while running: closing kills URBs too
        return False                                     # ENOENT / ECONNRESET = discarded

    def _resubmit(self, urb, buf, cb):
        if not self.running:
            return
        try:
            self.dev.resubmit(urb, buf, cb)
        except UsbfsError as e:
            log.warning("USB resubmit failed: %s", e)
            self._gone()

    def _iso_cb(self, urb, buf):
        if not self._status_ok(urb):
            return
        raw = bytearray()
        mps = self.iso_mps
        for k in range(urb.number_of_packets):
            d = urb.iso_frame_desc[k]
            if d.status == 0 and d.actual_length:
                raw += buf.raw[k * mps: k * mps + d.actual_length]
        if raw:
            self.on_iq(to_s16(raw, self.subframe))
        self._resubmit(urb, buf, self._iso_cb)

    def _bulk_cb(self, urb, buf):
        if not self._status_ok(urb):
            return
        if urb.actual_length:
            self.on_cat(buf.raw[:urb.actual_length])
        self._resubmit(urb, buf, self._bulk_cb)

    # -- extra serial ports ----------------------------------------------------
    def serial_count(self) -> int:
        return len(self.cdc_ports)

    def serial_open(self, idx, on_data):
        name = "port %d" % (idx + 1)
        st = self.extra.get(idx)
        if st and st["cb"]:
            st["cb"] = on_data
            return True, ""
        if len(self.cdc_ports) <= idx:
            return False, ("the radio has %d USB serial port%s - set 'USB serial ports' to %d"
                           % (len(self.cdc_ports), "" if len(self.cdc_ports) == 1 else "s", idx + 1))
        comm, data, bin_, bout = self.cdc_ports[idx]
        st = {"ifs": [], "out": bout, "cb": None, "rx": None}
        self.extra[idx] = st
        try:
            for i in [x for x in (comm, data) if x is not None]:
                self.dev.claim(i)
                st["ifs"].append(i)
        except UsbfsError as e:
            self._serial_release(idx)
            return False, ("%s is in use by another program on the NAS" % name if e.errno == errno.EBUSY
                           else "%s claim failed: %s" % (name, e))
        if comm is not None:
            try:
                self.dev.control_write(0x21, 0x20, 0, comm, struct.pack("<IBBB", CAT_BAUD, 0, 0, 8))
                self.dev.control_write(0x21, 0x22, 0x0003, comm, b"")
            except UsbfsError as e:
                log.warning("%s line setup: %s (continuing)", name, e)
        st["cb"] = on_data

        def rx(urb, buf, idx=idx):
            s = self.extra.get(idx)
            if not self._status_ok(urb) or not s or not s["cb"]:
                return
            if urb.actual_length:
                s["cb"](buf.raw[:urb.actual_length])
            self._resubmit(urb, buf, s["rx"])
        st["rx"] = rx
        for _ in range(2):
            self.dev.submit_bulk_in(bin_, 512, rx)
        log.info("QMX %s open (if%s/if%d)", name, comm, data)
        return True, ""

    def serial_send(self, idx, data: bytes):
        st = self.extra.get(idx)
        if not self.dev or not st or not st["cb"]:
            return
        try:
            self.dev.bulk_write(st["out"], data)
        except UsbfsError as e:
            if e.errno == errno.ENODEV:
                self._gone()
                raise RadioGone("QMX gone")
            log.warning("port %d write: %s", idx + 1, e)

    def serial_close(self, idx):
        st = self.extra.get(idx)
        if not st:
            return
        st["cb"] = None
        if st["rx"] and self.dev:
            self.dev.discard_all({st["rx"]})
            deadline = time.time() + 1.0
            while time.time() < deadline and self.dev.outstanding({st["rx"]}):
                time.sleep(0.02)
        self._serial_release(idx)
        log.info("QMX port %d closed", idx + 1)

    def _serial_release(self, idx):
        st = self.extra.pop(idx, None)
        if st and self.dev:
            for i in st["ifs"]:
                self.dev.release(i)

    def term_open(self, on_data):
        return self.serial_open(1, on_data)

    def term_send(self, data: bytes):
        self.serial_send(1, data)

    def term_close(self):
        self.serial_close(1)

    def send_cat(self, data: bytes):
        if not self.dev:
            raise RadioGone("closed")
        try:
            self.dev.bulk_write(self.bulk_out, data)
        except UsbfsError as e:
            if e.errno == errno.ENODEV:
                self._gone()
                raise RadioGone("QMX gone")
            log.warning("CAT write: %s", e)

    def close(self):
        self.running = False
        dev, self.dev = self.dev, None
        if not dev:
            return
        for st in self.extra.values():
            st["cb"] = None
            self.claimed += st["ifs"]
        self.extra = {}
        dev.on_gone = None                    # an orderly close is not an unplug
        dev.discard_all()
        deadline = time.time() + 1.0
        while time.time() < deadline and dev.outstanding():
            time.sleep(0.02)
        if self.as_if is not None and not dev.gone:
            try:
                dev.set_altsetting(self.as_if, 0)   # stop the isochronous stream
            except UsbfsError:
                pass
        dev.close()          # waits for the reaper, closes the fd (releases interfaces)
        self.claimed = []


def libusb_available() -> bool:
    try:
        from usb1 import _libusb1
        path = os.environ.get("QMX_LIBUSB")
        _libusb1.loadLibrary(path) if path else _libusb1.loadLibrary()
        return True
    except Exception:
        return False


def pick_backend():
    """libusb if it loads (any OS), else Linux usbfs. QMX_BACKEND=libusb|usbfs forces one."""
    want = os.environ.get("QMX_BACKEND", "").lower()
    if want == "usbfs" or (want != "libusb" and not libusb_available()):
        if not sys.platform.startswith("linux"):
            raise RadioGone("libusb-1.0 not found (and usbfs is Linux-only)")
        return UsbfsQmx
    return QmxUsb


class FakeRadio:
    """Bench-test stand-in: a +3 kHz tone and a tiny Kenwood CAT emulator."""

    def __init__(self, on_iq, on_cat, on_gone):
        self.on_iq, self.on_cat, self.on_gone = on_iq, on_cat, on_gone
        self.running = False
        self.freq, self.mode = 14074000, "2"
        self.bufs = {0: b"", 2: b""}
        self.cbs = {}            # idx -> data callback for extra ports
        self.sel = 0

    def open(self):
        self.running = True
        threading.Thread(target=self._gen, daemon=True).start()
        log.info("FAKE radio: synthetic I/Q tone at +3000 Hz, CAT emulator")

    def _gen(self):
        ph, step = 0.0, 2 * math.pi * 3000 / SAMPLE_RATE
        nxt = time.monotonic()
        while self.running:
            out = bytearray()
            for _ in range(FRAME_PAIRS):
                out += struct.pack("<hh", int(8000 * math.cos(ph)), int(8000 * math.sin(ph)))
                ph = (ph + step) % (2 * math.pi)
            self.on_iq(bytes(out))
            nxt += FRAME_PAIRS / SAMPLE_RATE
            time.sleep(max(0.0, nxt - time.monotonic()))

    def serial_count(self) -> int:
        n = getattr(self.args_ns, "fake_ports", 3)
        return 1 if getattr(self.args_ns, "fake_one_port", False) else n

    def send_cat(self, data: bytes, idx: int = 0, reply=None):
        reply = reply or self.on_cat
        self.bufs[idx] += data
        while b";" in self.bufs[idx]:
            cmd, self.bufs[idx] = self.bufs[idx].split(b";", 1)
            c = cmd.decode(errors="replace")
            r = None
            if c == "ID":
                r = "ID020;"
            elif c == "FA":
                r = "FA%011d;" % self.freq
            elif c.startswith("FA") and c[2:].isdigit():
                self.freq = int(c[2:])
            elif c == "MD":
                r = "MD%s;" % self.mode
            elif c.startswith("MD") and len(c) == 3:
                self.mode = c[2]
            elif c == "FW":
                r = "FW2700;"
            elif c == "VN":
                r = "VN1_03_002QMX;"
            elif c in ("Q9", "Q9 1"):
                r = "Q91;"
            elif c.startswith("MM"):
                r = "MM;"
            if r:
                reply(r.encode())

    # Fake extra ports: port 2 answers CR with a tiny ANSI menu (arrows move);
    # port 3 is a second, independent CAT port.
    def serial_open(self, idx, on_data):
        n = self.serial_count()
        if n <= idx:
            return False, ("the radio has %d USB serial port%s - set 'USB serial ports' to %d"
                           % (n, "" if n == 1 else "s", idx + 1))
        self.cbs[idx] = on_data
        if idx == 1:
            self.sel = 0
        return True, ""

    def _paint(self):
        items = ["Band config.", "Mode config.", "System config", "Exit terminal"]
        out = "\x1b[2J\x1b[H QMX menu\r\n"
        for i, it in enumerate(items):
            out += ("\x1b[7m %s \x1b[0m" if i == self.sel else " %s ") % it + "\r\n"
        self.cbs[1](out.encode())

    def serial_send(self, idx, data: bytes):
        cb = self.cbs.get(idx)
        if not cb:
            return
        if idx == 2:
            self.send_cat(data, idx=2, reply=cb)
        elif data in (b"\r", b"\x1b[B", b"\x1b[A"):
            if data == b"\x1b[B":
                self.sel = (self.sel + 1) % 4
            elif data == b"\x1b[A":
                self.sel = (self.sel - 1) % 4
            self._paint()

    def serial_close(self, idx):
        self.cbs.pop(idx, None)

    def term_open(self, on_data):
        return self.serial_open(1, on_data)

    def term_send(self, data: bytes):
        self.serial_send(1, data)

    def term_close(self):
        self.serial_close(1)

    def close(self):
        self.running = False
        self.cbs = {}


# ---------------------------------------------------------------------------
# Shared radio: opened by the first user (Tab5 session or port-3 client),
# released by the last.
# ---------------------------------------------------------------------------

class RadioManager:
    def __init__(self, args):
        self.args = args
        self.lock = threading.Lock()
        self.radio = None
        self.dead = False
        self.users: set = set()
        self.session = None          # the current Tab5 session gets I/Q and CAT

    def acquire(self, user):
        with self.lock:
            if self.radio is not None and self.dead:
                self._close_locked()            # a previous QMX connection died; start fresh
            if self.radio is None:
                cls = FakeRadio if self.args.fake else pick_backend()
                r = cls(self._on_iq, self._on_cat, self._on_gone)
                r.args_ns = self.args
                r.open()                         # raises RadioGone
                self.radio, self.dead = r, False
            self.users.add(user)
            return self.radio

    def release(self, user, radio):
        with self.lock:
            self.users.discard(user)
            if self.session is user:
                self.session = None
            if radio is self.radio and not self.users:
                self._close_locked()

    def _close_locked(self):
        r, self.radio = self.radio, None
        if r:
            r.close()
            log.info("QMX released")

    # radio callbacks (libusb / fake thread)
    def _on_iq(self, b):
        s = self.session
        if s:
            s._on_iq(b)

    def _on_cat(self, b):
        s = self.session
        if s:
            s._on_cat(b)

    def _on_gone(self):
        self.dead = True
        for u in list(self.users):
            u.radio_gone()


# ---------------------------------------------------------------------------
# One Tab5 session
# ---------------------------------------------------------------------------

class Session:
    def __init__(self, sock: socket.socket, peer, args, mgr: RadioManager):
        self.sock, self.peer, self.args, self.mgr = sock, peer, args, mgr
        # Two queues: control frames (CAT, terminal, status, ping) always go
        # out before queued I/Q, so a slow WiFi link delays the spectrum, not
        # the radio's replies. The I/Q queue is short and drops when full.
        self.ctl: collections.deque[bytes] = collections.deque()
        self.iq: collections.deque[bytes] = collections.deque()
        self.wake = threading.Condition()
        self.iq_acc = bytearray()
        self.alive = True
        self.dropped = 0
        self.iq_bytes = 0

    def _put_ctl(self, data: bytes):
        with self.wake:
            self.ctl.append(data)
            self.wake.notify()

    # radio callbacks (libusb thread)
    def _on_iq(self, s16: bytes):
        self.iq_acc += s16
        fb = FRAME_PAIRS * 4
        while len(self.iq_acc) >= fb:
            chunk = bytes(self.iq_acc[:fb])
            del self.iq_acc[:fb]
            with self.wake:
                if len(self.iq) >= IQ_QUEUE_MAX:
                    self.dropped += 1      # Tab5/WiFi can't keep up: drop I/Q, keep latency low
                    continue
                self.iq_bytes += len(chunk)
                self.iq.append(frame(PROTO_IQ, chunk))
                self.wake.notify()

    def _on_cat(self, data: bytes):
        log.debug("QMX -> Tab5 CAT %r", data)
        self._put_ctl(frame(PROTO_CAT, data))

    def _on_term(self, data: bytes):
        self._put_ctl(frame(PROTO_TERM_DATA, data))

    def radio_gone(self):
        self.stop("QMX disconnected")

    def stop(self, why: str):
        if self.alive:
            self.alive = False
            with self.wake:
                self.wake.notify()
            log.info("Tab5 session %s:%d ending: %s", self.peer[0], self.peer[1], why)
            try:
                self.sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def run(self):
        sock = self.sock
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        # Small kernel send buffer: otherwise Linux autotunes it to megabytes,
        # seconds of I/Q pile up there instead of being dropped above, and every
        # CAT reply waits behind them (the Tab5 then times out IQ-mode setup).
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, TAB5_SNDBUF)
        except OSError:
            pass
        radio = None
        try:
            sock.settimeout(5)
            t, _, n = HDR.unpack(recv_exact(sock, 4))
            hello = recv_exact(sock, n) if n else b""
            if t != PROTO_HELLO or not hello.startswith(b"QMXR/1"):
                raise ConnectionError("not a QMXR/1 client")
            log.info("Tab5 %s:%d hello: %s", self.peer[0], self.peer[1], hello.decode(errors="replace"))

            radio = self.mgr.acquire(self)    # raises RadioGone -> we close without answering
            self.mgr.session = self

            sock.sendall(frame(PROTO_HELLO, b"QMXR/1 rate=%d ch=2 fmt=s16le src=nas term=1" % SAMPLE_RATE))
            sock.settimeout(None)
            sender = threading.Thread(target=self._send_loop, daemon=True)
            sender.start()
            while self.alive:
                t, _, n = HDR.unpack(recv_exact(sock, 4))
                payload = recv_exact(sock, n) if n else b""
                if t == PROTO_CAT and payload:
                    log.debug("Tab5 -> QMX CAT %r", payload)
                    radio.send_cat(payload)
                elif t == PROTO_TERM_DATA and payload:
                    radio.term_send(payload)
                elif t == PROTO_TERM_OPEN:
                    ok, why = radio.term_open(self._on_term)
                    if not ok:
                        log.warning("terminal: %s", why)
                    self._put_ctl(frame(PROTO_TERM_STATUS, (b"\x01" if ok else b"\x00" + why.encode())[:200]))
                elif t == PROTO_TERM_CLOSE:
                    radio.term_close()
        except RadioGone as e:
            log.warning("%s", e)
        except (ConnectionError, OSError, socket.timeout) as e:
            if self.alive:
                log.info("Tab5 %s:%d disconnected: %s", self.peer[0], self.peer[1], e)
        finally:
            self.alive = False
            if radio:
                try:
                    radio.term_close()
                except Exception:
                    pass
                if self.dropped:
                    log.info("%d I/Q frames were dropped for a slow link", self.dropped)
                self.mgr.release(self, radio)
            try:
                sock.close()
            except OSError:
                pass

    def _send_loop(self):
        last_ping = time.monotonic()
        while self.alive:
            with self.wake:
                if not self.ctl and not self.iq:
                    self.wake.wait(0.25)
                # all pending control frames first, then at most one I/Q frame,
                # so a CAT reply never waits behind more than one I/Q frame here
                out = list(self.ctl)
                self.ctl.clear()
                if self.iq:
                    out.append(self.iq.popleft())
            if time.monotonic() - last_ping >= 1.0:
                out.insert(0, frame(PROTO_PING))
                last_ping = time.monotonic()
            try:
                for data in out:
                    self.sock.sendall(data)
            except OSError as e:
                self.stop("send failed: %s" % e)
                return


# ---------------------------------------------------------------------------
# QMX port 3 as raw TCP serial for PC software
# ---------------------------------------------------------------------------

PORT3 = 2   # index into the QMX's serial ports (0 = CAT, 1 = terminal, 2 = port 3)


class SerialClient:
    """One PC on the QMX's third serial port. Bytes are passed through
    unchanged in both directions - no framing, like a serial cable."""

    def __init__(self, sock: socket.socket, peer, mgr: RadioManager):
        self.sock, self.peer, self.mgr = sock, peer, mgr
        self.q: queue.Queue[bytes] = queue.Queue()
        self.alive = True

    def radio_gone(self):
        self.stop("QMX disconnected")

    def stop(self, why: str):
        if self.alive:
            self.alive = False
            log.info("port 3 client %s:%d ending: %s", self.peer[0], self.peer[1], why)
            try:
                self.sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def _on_data(self, data: bytes):
        self.q.put(data)               # libusb thread: never block on the PC's socket

    def _send_loop(self):
        while self.alive:
            try:
                data = self.q.get(timeout=0.25)
            except queue.Empty:
                continue
            try:
                self.sock.sendall(data)
            except OSError as e:
                self.stop("send failed: %s" % e)
                return

    def run(self):
        sock = self.sock
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        radio = opened = None
        try:
            radio = self.mgr.acquire(self)
            ok, why = radio.serial_open(PORT3, self._on_data)
            if not ok:
                log.warning("port 3 client %s refused: %s", self.peer[0], why)
                return
            opened = True
            log.info("port 3 client %s:%d connected", self.peer[0], self.peer[1])
            threading.Thread(target=self._send_loop, daemon=True).start()
            while self.alive:
                data = sock.recv(4096)
                if not data:
                    log.info("port 3 client %s:%d disconnected", self.peer[0], self.peer[1])
                    break
                radio.serial_send(PORT3, data)
        except RadioGone as e:
            log.warning("port 3: %s", e)
        except OSError as e:
            if self.alive:
                log.info("port 3 client %s:%d disconnected: %s", self.peer[0], self.peer[1], e)
        finally:
            self.alive = False
            if radio:
                if opened:
                    try:
                        radio.serial_close(PORT3)
                    except Exception:
                        pass
                self.mgr.release(self, radio)
            try:
                sock.close()
            except OSError:
                pass


def serve(listen, port, make, label):
    """Accept loop: one client at a time; a new connection replaces the old one."""
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((listen, port))
    srv.listen(2)
    log.info("listening on %s:%d (%s)", listen, port, label)
    current: list = [None, None]   # [client, thread]
    while True:
        sock, peer = srv.accept()
        old, th = current
        if old and old.alive:
            old.stop("replaced by new connection from %s" % peer[0])
            th.join(timeout=3)     # let it release its port before the new one opens it
        c = make(sock, peer)
        t = threading.Thread(target=c.run, daemon=True)
        current[:] = [c, t]
        t.start()


# ---------------------------------------------------------------------------
# Discovery: a Tab5 broadcasts "QMXR?" on UDP (same port number as the TCP
# service, 7355) and every relay on the network answers it directly with
# "QMXR! <its IP address> <TCP port>". Nothing is sent unless asked.
# ---------------------------------------------------------------------------

DISCOVERY_QUERY = b"QMXR?"
DISCOVERY_REPLY = b"QMXR!"


def local_ip_for(peer_ip: str) -> str:
    """The address of THIS host on the interface that reaches peer_ip (a NAS can
    have several). A connected UDP socket sends nothing; it only picks a route."""
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        u.connect((peer_ip, 9))
        return u.getsockname()[0]
    except OSError:
        return "0.0.0.0"
    finally:
        u.close()


def discovery_responder(listen: str, udp_port: int, tcp_port: int):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((listen, udp_port))
    except OSError as e:
        log.warning("discovery disabled - cannot listen on UDP %d: %s", udp_port, e)
        return
    log.info("discovery: answering QMXR? on UDP %s:%d", listen, udp_port)
    last_logged: dict = {}
    while True:
        try:
            data, peer = s.recvfrom(256)
            if not data.startswith(DISCOVERY_QUERY):
                continue
            ip = local_ip_for(peer[0])
            if ip == "0.0.0.0":
                continue
            s.sendto(b"%s %s %d" % (DISCOVERY_REPLY, ip.encode(), tcp_port), peer)
            now = time.monotonic()
            if now - last_logged.get(peer[0], -1e9) > 60:      # a search sends 3 queries
                last_logged[peer[0]] = now
                log.info("discovery: %s asked, answered %s:%d", peer[0], ip, tcp_port)
        except Exception as e:                                  # never take the relay down
            log.warning("discovery: %s", e)
            time.sleep(1)


# ---------------------------------------------------------------------------
# Self-test against the real radio (read-only: never keys the transmitter)
# ---------------------------------------------------------------------------

class _SelfTestUser:
    def __init__(self):
        self.pairs = 0
        self.sumsq = 0
        self.nsq = 0
        self.peak = 0
        self.cat = bytearray()
        self.gone = False

    def radio_gone(self):
        self.gone = True

    def _on_iq(self, b: bytes):
        from array import array
        a = array("h")
        a.frombytes(b[: len(b) // 2 * 2])
        self.pairs += len(a) // 2
        sub = a[::8]
        self.sumsq += sum(x * x for x in sub)
        self.nsq += len(sub)
        m = max((abs(x) for x in sub), default=0)
        if m > self.peak:
            self.peak = m

    def _on_cat(self, b: bytes):
        self.cat += b


def selftest(mgr) -> bool:
    """Open the QMX, measure the I/Q stream, ask read-only CAT questions on
    port 1, check ports 2 and 3, then release it. Results go to the log."""
    log.info("SELFTEST: starting (read-only - nothing is transmitted)")
    u = _SelfTestUser()
    try:
        radio = mgr.acquire(u)
    except RadioGone as e:
        log.error("SELFTEST FAIL: %s", e)
        return False
    ok_all = True
    mgr.session = u
    try:
        # 1. I/Q stream
        t0 = time.monotonic()
        time.sleep(2.0)
        dt = time.monotonic() - t0
        rate = u.pairs / dt if dt else 0
        rms = math.sqrt(u.sumsq / u.nsq) if u.nsq else 0.0
        dbfs = 20 * math.log10(rms / 32768) if rms > 0 else float("-inf")
        iq_ok = 40000 <= rate <= 56000
        ok_all &= iq_ok
        log.info("SELFTEST %s: I/Q %.0f pairs/s (expect ~48000), level %.1f dBFS rms, peak %d",
                 "PASS" if iq_ok else "FAIL", rate, dbfs, u.peak)
        if iq_ok and u.peak == 0:
            log.warning("SELFTEST note: I/Q is all zeros - is the radio receiving? (IQ mode is set by the Tab5)")

        # 2. CAT on port 1 - queries only
        for q in (b"ID;", b"FA;", b"MD;", b"VN;"):
            u.cat.clear()
            radio.send_cat(q)
            deadline = time.monotonic() + 1.0
            while time.monotonic() < deadline and b";" not in u.cat:
                time.sleep(0.02)
            time.sleep(0.05)
            reply = bytes(u.cat).decode(errors="replace").strip()
            good = bool(reply) and reply.endswith(";")
            ok_all &= good if q == b"ID;" else True
            log.info("SELFTEST %s: port 1 CAT %s -> %s", "PASS" if good else "FAIL",
                     q.decode(), reply or "(no reply)")

        # 3. serial ports 2 and 3
        n = radio.serial_count()
        log.info("SELFTEST: radio reports %d USB serial port(s)", n)
        if n >= 2:
            ok, why = radio.serial_open(1, lambda b: None)   # open/close only: no bytes sent,
            if ok:                                           # so the radio never enters terminal mode
                radio.serial_close(1)
            ok_all &= ok
            log.info("SELFTEST %s: port 2 (Radio menus) %s", "PASS" if ok else "FAIL", "opens" if ok else why)
        else:
            log.info("SELFTEST skip: port 2 - set 'USB serial ports' to 2 or 3 for Radio menus")
        if n >= 3:
            got = bytearray()
            ok, why = radio.serial_open(2, lambda b: got.extend(b))
            reply = ""
            if ok:
                radio.serial_send(2, b"FA;")
                deadline = time.monotonic() + 1.0
                while time.monotonic() < deadline and b";" not in got:
                    time.sleep(0.02)
                radio.serial_close(2)
                reply = bytes(got).decode(errors="replace").strip()
                ok = bool(reply)
            ok_all &= ok
            log.info("SELFTEST %s: port 3 (PC serial) FA; -> %s", "PASS" if ok else "FAIL",
                     reply or why or "(no reply)")
        else:
            log.info("SELFTEST skip: port 3 - set 'USB serial ports' to 3 for PC software on TCP 7356")
        if u.gone:
            ok_all = False
            log.error("SELFTEST FAIL: the QMX disconnected during the test")
    except RadioGone as e:
        ok_all = False
        log.error("SELFTEST FAIL: %s", e)
    finally:
        if mgr.session is u:
            mgr.session = None
        mgr.release(u, radio)
    log.info("SELFTEST %s", "PASSED" if ok_all else "FAILED - see the lines above")
    return ok_all


def probe_usbfs():
    print("(usbfs backend - libusb-1.0 not available)")
    found = False
    for bus, devn, vid, pid, name in usbfs_list_devices():
        mark = "  <== QMX" if (vid, pid) == (QMX_VID, QMX_PID) else ""
        print("%03d/%03d %04x:%04x %s%s" % (bus, devn, vid, pid, name, mark))
        if mark:
            found = True
            with open("/dev/bus/usb/%03d/%03d" % (bus, devn), "rb") as f:
                cfg = usbfs_parse_config(f.read())
            for iface in cfg:
                for st in iface:
                    eps = ", ".join("0x%02x/%s/%d" % (e.getAddress(), "CIBI"[e.getAttributes() & 3],
                                                      e.getMaxPacketSize()) for e in st)
                    print("    if%d alt%d class %02x/%02x/%02x  eps: %s" % (
                        st.getNumber(), st.getAlternateSetting(), st.getClass(), st.getSubClass(),
                        st.getProtocol(), eps or "-"))
            ports, _uac2, aud = discover_qmx(cfg)
            print("    USB serial ports: %d  (Radio menus need 2+, PC serial on port 3 needs 3)" % len(ports))
            print("    I/Q input: %s" % (aud,))
    if not found:
        print("QMX not found. Is it plugged into the NAS and powered on?")
    return 0 if found else 1


def probe(args):
    if os.environ.get("QMX_BACKEND", "").lower() == "usbfs" or not libusb_available():
        return probe_usbfs()
    import usb1
    _load_libusb(usb1)
    with usb1.USBContext() as ctx:
        found = False
        for dev in ctx.getDeviceIterator(skip_on_error=True):
            vid, pid = dev.getVendorID(), dev.getProductID()
            mark = "  <== QMX" if (vid, pid) == (QMX_VID, QMX_PID) else ""
            print("%03d/%03d %04x:%04x%s" % (dev.getBusNumber(), dev.getDeviceAddress(), vid, pid, mark))
            if mark:
                found = True
                for iface in dev[0]:
                    for s in iface:
                        eps = ", ".join("0x%02x/%s/%d" % (e.getAddress(), "CIBI"[e.getAttributes() & 3],
                                                          e.getMaxPacketSize()) for e in s)
                        print("    if%d alt%d class %02x/%02x/%02x  eps: %s" % (
                            s.getNumber(), s.getAlternateSetting(), s.getClass(), s.getSubClass(),
                            s.getProtocol(), eps or "-"))
                ncdc = sum(1 for iface in dev[0] for s in iface
                           if s.getClass() == 0x0A and s.getAlternateSetting() == 0)
                print("    USB serial ports: %d  (Radio menus need 2+, PC serial on port 3 needs 3)" % ncdc)
        if not found:
            print("QMX not found. Is it plugged into the NAS and powered on?")
        return 0 if found else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--listen", default="0.0.0.0", help="bind address (default all)")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT, help="Tab5 TCP port (default 7355)")
    ap.add_argument("--serial-port", type=int, default=DEFAULT_SERIAL_PORT,
                    help="TCP port for the QMX's 3rd serial port, for PC software "
                         "(default 7356, 0 = off; needs 'USB serial ports' = 3 on the radio)")
    ap.add_argument("--fake", action="store_true", help="synthetic radio for bench tests (no QMX needed)")
    ap.add_argument("--fake-one-port", action="store_true", help=argparse.SUPPRESS)
    ap.add_argument("--fake-ports", type=int, default=3, choices=(1, 2, 3), help=argparse.SUPPRESS)
    ap.add_argument("--probe", action="store_true", help="list USB devices / QMX interfaces and exit")
    ap.add_argument("--selftest", action="store_true",
                    help="at startup, test the QMX (I/Q, read-only CAT, ports 2/3), log the result, then serve")
    ap.add_argument("--selftest-only", action="store_true", help="run the self-test and exit (0 = passed)")
    ap.add_argument("--discovery-port", type=int, default=None,
                    help="UDP port answering Tab5 'QMXR?' searches (default: same as --port; 0 = off)")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")
    if args.probe:
        return probe(args)

    mgr = RadioManager(args)
    if args.selftest or args.selftest_only:
        passed = selftest(mgr)
        if args.selftest_only:
            return 0 if passed else 1
    if args.fake:
        log.info("FAKE radio with %d USB serial port(s)", 1 if args.fake_one_port else args.fake_ports)
    if args.serial_port:
        threading.Thread(target=serve, daemon=True, args=(
            args.listen, args.serial_port, lambda s, p: SerialClient(s, p, mgr),
            "QMX port 3, raw serial for PC software")).start()
    disc = args.port if args.discovery_port is None else args.discovery_port
    if disc:
        threading.Thread(target=discovery_responder, daemon=True, name="discovery",
                         args=(args.listen, disc, args.port)).start()
    serve(args.listen, args.port, lambda s, p: Session(s, p, args, mgr), "QMXR/1 for the Tab5")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        pass

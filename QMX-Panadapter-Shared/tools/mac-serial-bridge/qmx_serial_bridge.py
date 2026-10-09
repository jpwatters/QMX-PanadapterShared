#!/usr/bin/env python3
"""
qmx_serial_bridge.py - make the QMX on the Synology NAS show up on a Mac as a
serial port, so WSJT-X, Hamlib/rigctld, fldigi, loggers or a terminal can use
it as if the radio were plugged into the Mac's USB.

    QMX --USB--> NAS (qmx_nas_relay.py)  --TCP 7356 (QMX serial port 3)-->
        this program --> serial device on the Mac  (~/cu.QMX-NAS by default)

Finding the NAS: unless --host is given, it asks the network the same way the
Tab5's Find NAS does - broadcasts "QMXR?" on UDP 7355 and the relay answers
"QMXR! <its IP address> <TCP port>". The address is taken from that answer.
The port in the answer is the Tab5's QMXR/1 service (7355); this program uses
the relay's port 3 service on the same NAS, TCP 7356 (--port).
If the NAS stops answering at the remembered address, it searches again.

It creates a pseudo-terminal (the same kind of device a USB serial adapter
gives you) and links it at a fixed path. Point the program at that path the
same way you would for a USB-connected QMX (any baud rate works; the setting
is ignored).

  * Connects to the relay only when a program actually talks to the port, and
    lets go after --idle seconds of silence, so the radio's port 3 is only
    held while something is using it (--keep-connected holds it all the time).
  * If the QMX is off or the relay is down, what the program sends is dropped
    and it retries on the next command, like a radio that is switched off.
  * Bytes pass through unchanged in both directions - no framing.
  * If the NAS is not found it falls back to --fallback-host, if given.

Needs only the Python 3 that comes with macOS (Xcode command line tools).
Also runs on Linux.

    python3 qmx_serial_bridge.py                      # find the NAS, ~/cu.QMX-NAS
    python3 qmx_serial_bridge.py --discover           # list the relays that answer, then exit
    python3 qmx_serial_bridge.py --host 10.0.0.137    # fixed address, no search
    python3 qmx_serial_bridge.py --probe              # one-off check: ID; FA; MD;
"""

from __future__ import annotations

import argparse
import errno
import logging
import os
import select
import signal
import re
import socket
import subprocess
import sys
import termios
import time
import tty

log = logging.getLogger("qmx-serial-bridge")

DEFAULT_PORT = 7356          # relay: QMX serial port 3, raw bytes
DISCOVERY_PORT = 7355        # relay: answers "QMXR?" on UDP (same number as its QMXR/1 TCP port)
DISCOVERY_TIME = 1.5         # seconds; "QMXR?" is sent 3 times in this window, like the Tab5
DISCOVERY_QUERY = b"QMXR?"
DISCOVERY_REPLY = b"QMXR!"
DEFAULT_LINK = "~/cu.QMX-NAS"
DEFAULT_IDLE = 120          # seconds without traffic before the relay port is released
CONNECT_TIMEOUT = 3.0
RETRY_AFTER = 3.0           # after a failed connect, drop commands for this long
QUICK_CLOSE = 1.5           # relay closing this fast after connect = port 3 refused


def fmt(b: bytes, n: int = 60) -> str:
    s = b.decode("ascii", "replace")
    return s if len(s) <= n else s[:n] + "..."


def broadcast_addresses() -> list[str]:
    """255.255.255.255 plus each interface's own broadcast address. A Mac sends
    255.255.255.255 out of one interface only, so with Wi-Fi and Ethernet both
    up the directed addresses make sure the NAS's network is asked too."""
    out = ["255.255.255.255"]
    try:
        txt = subprocess.run(["ifconfig"], capture_output=True, text=True, timeout=3).stdout
        for b in re.findall(r"\bbroadcast (\d+\.\d+\.\d+\.\d+)", txt) + \
                re.findall(r"\bBcast:(\d+\.\d+\.\d+\.\d+)", txt):
            if b not in out:
                out.append(b)
    except (OSError, subprocess.SubprocessError):
        pass
    return out


def discover(timeout: float = DISCOVERY_TIME, udp_port: int = DISCOVERY_PORT,
             targets: list[str] | None = None) -> list[tuple[str, int]]:
    """Ask the network for QMX relays: send "QMXR?" three times over `timeout`
    seconds and collect the distinct "QMXR! <ip> <tcp port>" answers, in the
    order they arrive. The answer's own address is used; if it doesn't parse,
    the address the answer came from. Returns [(ip, advertised tcp port), ...]."""
    targets = targets or broadcast_addresses()
    found: list[tuple[str, int]] = []
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        u.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        u.settimeout(0.1)
        start, sent = time.monotonic(), 0
        while time.monotonic() - start < timeout:
            if sent < 3 and time.monotonic() - start >= sent * timeout / 3:
                for t in targets:
                    try:
                        u.sendto(DISCOVERY_QUERY, (t, udp_port))
                    except OSError as e:
                        log.debug("discovery: send to %s failed: %s", t, e)
                sent += 1
            try:
                data, peer = u.recvfrom(256)
            except socket.timeout:
                continue
            except OSError as e:
                log.debug("discovery: %s", e)
                continue
            parts = data.decode("ascii", "replace").split()
            if not parts or parts[0] != DISCOVERY_REPLY.decode():
                continue
            ip = parts[1] if len(parts) > 1 else ""
            try:
                socket.inet_aton(ip)
                if ip.count(".") != 3:
                    raise OSError
            except OSError:
                ip = peer[0]
            port = int(parts[2]) if len(parts) > 2 and parts[2].isdigit() else DISCOVERY_PORT
            if not 0 < port < 65536:
                port = DISCOVERY_PORT
            if (ip, port) not in found:
                found.append((ip, port))
    finally:
        u.close()
    return found


class Bridge:
    def __init__(self, args):
        self.args = args
        self.link = os.path.expanduser(args.link)
        self.master = self.slave = -1
        self.sock: socket.socket | None = None
        self.connected_at = 0.0
        self.got_reply = False
        self.last_traffic = 0.0
        self.retry_at = 0.0
        self.dropped_note = 0.0
        self.running = True
        self.host = args.host            # None = find it with "QMXR?"
        self.searched_at = -1e9

    # ---- finding the NAS ---------------------------------------------------

    def find_nas(self) -> bool:
        """Ask the network where the relay is (not more than every RETRY_AFTER s)."""
        now = time.monotonic()
        if now - self.searched_at < RETRY_AFTER:
            return self.host is not None
        self.searched_at = now
        found = discover(udp_port=self.args.discovery_port)
        if found:
            ip, adv = found[0]
            if ip != self.host:
                log.info("found the NAS relay: QMXR! %s %d - using %s:%d for QMX port 3",
                         ip, adv, ip, self.args.port)
            if len(found) > 1:
                log.info("other relays answered too (using the first): %s",
                         ", ".join("%s:%d" % f for f in found[1:]))
            self.host = ip
            return True
        if self.args.fallback_host:
            if self.host != self.args.fallback_host:
                log.warning("no relay answered QMXR? on UDP %d; using --fallback-host %s",
                            self.args.discovery_port, self.args.fallback_host)
            self.host = self.args.fallback_host
            return True
        log.warning("no relay answered QMXR? on UDP %d (is the relay running, and the Mac "
                    "on the same network as the NAS?)", self.args.discovery_port)
        return self.host is not None

    # ---- the serial device -------------------------------------------------

    def open_pty(self):
        self.master, self.slave = os.openpty()
        # Raw 8-bit, no echo: an echo would send the radio's replies back to it.
        tty.setraw(self.slave)
        self.no_echo()
        os.set_blocking(self.master, False)
        name = os.ttyname(self.slave)
        # We keep our own handle on the device open (and never read it), so the
        # device stays put while programs open and close it.
        d = os.path.dirname(self.link)
        if d:
            os.makedirs(d, exist_ok=True)
        tmp = "%s.%d.tmp" % (self.link, os.getpid())
        os.symlink(name, tmp)
        os.replace(tmp, self.link)
        log.info("serial port ready: %s  (device %s)", self.link, name)

    def no_echo(self):
        """Programs may change the port settings; never allow echo, which would
        loop the radio's replies straight back into the radio."""
        try:
            a = termios.tcgetattr(self.slave)
            bad = termios.ECHO | termios.ECHONL
            if a[3] & bad:
                a[3] &= ~bad
                termios.tcsetattr(self.slave, termios.TCSANOW, a)
                log.info("turned echo off on the serial port")
        except termios.error:
            pass

    def flush_stale(self):
        """Throw away radio bytes no program has read (e.g. a reply that came
        after the program closed the port), so the next program doesn't see them."""
        try:
            termios.tcflush(self.slave, termios.TCIFLUSH)
        except termios.error:
            pass

    def to_port(self, data: bytes):
        self.no_echo()
        view = memoryview(data)
        while view:
            try:
                n = os.write(self.master, view)
                view = view[n:]
            except BlockingIOError:
                log.warning("serial port full (nothing reading it): dropped %d bytes", len(view))
                return
            except OSError as e:
                log.warning("serial port write failed: %s", e)
                return

    # ---- the relay ---------------------------------------------------------

    def connect(self) -> bool:
        a = self.args
        searching = a.host is None
        if self.host is None and not (searching and self.find_nas()):
            self.retry_at = time.monotonic() + RETRY_AFTER
            return False
        try:
            s = socket.create_connection((self.host, a.port), CONNECT_TIMEOUT)
        except OSError as e:
            log.warning("can't reach the relay at %s:%d: %s", self.host, a.port, e)
            if e.errno in (errno.EHOSTUNREACH, errno.ENETUNREACH, errno.EPERM):
                log.warning("if this Mac is on the NAS's network, check System Settings -> "
                            "Privacy & Security -> Local Network allows python3")
            old = self.host
            if searching and self.find_nas() and self.host != old:
                return self.connect()        # the NAS moved: try its new address once
            self.retry_at = time.monotonic() + RETRY_AFTER
            return False
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        s.setblocking(False)
        self.sock = s
        self.connected_at = self.last_traffic = time.monotonic()
        self.got_reply = False
        self.flush_stale()
        log.info("connected to the relay %s:%d (QMX serial port 3)", self.host, a.port)
        return True

    def disconnect(self, why: str):
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None
            log.info("released the relay: %s", why)

    def to_relay(self, data: bytes):
        try:
            self.sock.setblocking(True)
            self.sock.settimeout(CONNECT_TIMEOUT)
            self.sock.sendall(data)
        except OSError as e:
            self.disconnect("send failed: %s" % e)
        finally:
            if self.sock:
                self.sock.setblocking(False)

    # ---- main loop ---------------------------------------------------------

    def on_port_data(self):
        try:
            data = os.read(self.master, 4096)
        except BlockingIOError:
            return
        except OSError as e:
            if e.errno == errno.EIO:      # no program has the port open
                time.sleep(0.05)
                return
            raise
        if not data:
            return
        log.debug("port -> radio: %s", fmt(data))
        now = time.monotonic()
        if not self.sock:
            if now < self.retry_at or not self.connect():
                if now - self.dropped_note > 30:
                    log.info("radio not reachable: dropping commands (retrying)")
                    self.dropped_note = now
                return
        self.last_traffic = now
        self.to_relay(data)

    def on_relay_data(self):
        try:
            data = self.sock.recv(4096)
        except BlockingIOError:
            return
        except OSError as e:
            if not self.quick_close():
                self.disconnect("connection lost: %s" % e)
            return
        if not data:
            if not self.quick_close():
                self.disconnect("relay closed the connection (QMX off or relay restarted)")
            return
        self.got_reply = True
        self.last_traffic = time.monotonic()
        log.debug("radio -> port: %s", fmt(data))
        self.to_port(data)

    def quick_close(self) -> bool:
        """The relay drops port 3 at once when the radio can't serve it."""
        if not self.got_reply and time.monotonic() - self.connected_at < QUICK_CLOSE:
            log.warning("the relay closed port 3 straight away. Is the QMX on, and is "
                        "'USB serial ports' set to 3 on the radio? (see the relay's log)")
            self.retry_at = time.monotonic() + RETRY_AFTER
            self.disconnect("port 3 refused")
            return True
        return False

    def run(self):
        self.open_pty()
        a = self.args
        if a.host is None:
            self.find_nas()
        log.info("relay: %s:%d   %s", self.host or "(not found yet)", a.port,
                 "kept connected" if a.keep_connected else
                 "connects on demand, releases after %ds idle" % a.idle if a.idle else
                 "connects on demand, stays connected")
        try:
            while self.running:
                now = time.monotonic()
                if a.keep_connected and not self.sock and now >= self.retry_at:
                    self.connect()
                if (self.sock and a.idle and not a.keep_connected
                        and now - self.last_traffic > a.idle):
                    self.disconnect("idle for %ds" % a.idle)
                    self.flush_stale()
                rl = [self.master] + ([self.sock] if self.sock else [])
                try:
                    r, _, _ = select.select(rl, [], [], 1.0)
                except InterruptedError:
                    continue
                if self.sock and self.sock in r:
                    self.on_relay_data()
                if self.master in r:
                    self.on_port_data()
        finally:
            self.cleanup()

    def cleanup(self):
        self.disconnect("stopping")
        try:
            if os.path.islink(self.link) and self.slave >= 0 and \
                    os.readlink(self.link) == os.ttyname(self.slave):
                os.unlink(self.link)
        except OSError:
            pass
        for fd in (self.slave, self.master):
            if fd >= 0:
                try:
                    os.close(fd)
                except OSError:
                    pass


def probe(args) -> int:
    """One-off check through the relay: read-only CAT queries, never transmits."""
    host = args.host
    if host is None:
        found = discover(udp_port=args.discovery_port)
        if found:
            print("ok  : QMXR? -> %s" % ", ".join("QMXR! %s %d" % f for f in found))
            host = found[0][0]
        elif args.fallback_host:
            print("note: no relay answered QMXR?; using --fallback-host %s" % args.fallback_host)
            host = args.fallback_host
        else:
            print("FAIL: no relay answered QMXR? on UDP %d" % args.discovery_port)
            return 1
    try:
        s = socket.create_connection((host, args.port), CONNECT_TIMEOUT)
    except OSError as e:
        print("FAIL: can't reach the relay at %s:%d: %s" % (host, args.port, e))
        return 1
    print("ok  : connected to %s:%d (QMX port 3)" % (host, args.port))
    s.settimeout(3)
    ok = True
    for q in (b"ID;", b"FA;", b"MD;"):
        s.sendall(q)
        reply, end = b"", time.monotonic() + 3
        while time.monotonic() < end and not reply.endswith(b";"):
            try:
                c = s.recv(256)
            except socket.timeout:
                break
            if not c:
                print("FAIL: the relay closed port 3 - is the QMX on, with "
                      "'USB serial ports' = 3?")
                return 1
            reply += c
        good = reply.endswith(b";")
        ok &= good
        print("%s: %s -> %s" % ("ok  " if good else "FAIL", q.decode(), fmt(reply) or "(no reply)"))
    s.close()
    print("PROBE %s" % ("PASSED" if ok else "FAILED"))
    return 0 if ok else 1


def main():
    p = argparse.ArgumentParser(description="QMX on the NAS as a serial port on this Mac")
    p.add_argument("--host", default=os.environ.get("QMX_NAS_HOST") or None,
                   help="fixed NAS address; without it the NAS is found by asking QMXR?")
    p.add_argument("--fallback-host", default=None,
                   help="address to use when no relay answers the search")
    p.add_argument("--discovery-port", type=int, default=DISCOVERY_PORT,
                   help="UDP port the relay answers QMXR? on (default %(default)s)")
    p.add_argument("--discover", action="store_true",
                   help="list the relays that answer QMXR? and exit")
    p.add_argument("--port", type=int, default=DEFAULT_PORT,
                   help="relay port for QMX serial port 3 (default %(default)s)")
    p.add_argument("--link", default=DEFAULT_LINK,
                   help="path of the serial port to create (default %(default)s)")
    p.add_argument("--idle", type=int, default=DEFAULT_IDLE,
                   help="release the relay after this many idle seconds, 0 = never (default %(default)s)")
    p.add_argument("--keep-connected", action="store_true",
                   help="stay connected to the relay all the time")
    p.add_argument("--probe", action="store_true",
                   help="check the relay once (ID; FA; MD;) and exit")
    p.add_argument("-v", "--verbose", action="store_true", help="log every byte")
    args = p.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s", stream=sys.stdout)
    if args.discover:
        found = discover(udp_port=args.discovery_port)
        for ip, port in found:
            print("QMXR! %s %d   -> serial port 3 at %s:%d" % (ip, port, ip, args.port))
        if not found:
            print("no relay answered QMXR? on UDP %d" % args.discovery_port)
        sys.exit(0 if found else 1)
    if args.probe:
        sys.exit(probe(args))
    b = Bridge(args)

    def stop(*_):
        b.running = False
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGHUP, stop)
    b.run()
    log.info("stopped")


if __name__ == "__main__":
    main()

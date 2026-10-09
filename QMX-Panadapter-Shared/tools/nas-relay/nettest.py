#!/usr/bin/env python3
"""End-to-end network test of a running relay, from the NAS itself.
Acts as the Tab5 on TCP 7355 (QMXR/1) and as a PC on TCP 7356 (port 3).
Read-only: CAT queries only, the terminal port is opened and closed without
sending anything, so the radio never transmits or enters terminal mode."""
import socket, struct, sys, time

HOST = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
HDR = struct.Struct("<BBH")
ok_all = True


def say(ok, msg):
    global ok_all
    ok_all &= ok
    print("NETTEST %s: %s" % ("PASS" if ok else "FAIL", msg), flush=True)


def frame(t, p=b""):
    return HDR.pack(t, 0, len(p)) + p


def rx(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise ConnectionError("closed by relay")
        b += c
    return b


def read_frames(s, secs, want=None):
    """Collect frames for `secs` seconds (or until `want(type, payload)` is true)."""
    out, end = [], time.monotonic() + secs
    while time.monotonic() < end:
        s.settimeout(max(0.05, end - time.monotonic()))
        try:
            t, _f, n = HDR.unpack(rx(s, 4))
            p = rx(s, n) if n else b""
        except socket.timeout:
            break
        out.append((t, p))
        if want and want(t, p):
            break
    return out


def discovery(dest, label, required):
    """Ask like a Tab5 does: 'QMXR?' on UDP 7355, expect 'QMXR! <ip> <port>'."""
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    u.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    u.settimeout(1.0)
    got = None
    try:
        for _ in range(3):
            try:
                u.sendto(b"QMXR?", (dest, 7355))
                data, peer = u.recvfrom(256)
            except socket.timeout:
                continue
            except OSError as e:            # e.g. no route for a broadcast
                got = None
                print("NETTEST INFO: discovery %s: %s" % (label, e), flush=True)
                break
            parts = data.decode(errors="replace").split()
            if len(parts) == 3 and parts[0] == "QMXR!" and parts[2].isdigit():
                got = "%s port %s (from %s)" % (parts[1], parts[2], peer[0])
                break
    finally:
        u.close()
    if required or got:
        say(got is not None, "discovery %s: %s" % (label, got or "no answer"))
    else:
        print("NETTEST INFO: discovery %s: no answer (a host may not hear its own "
              "broadcast; the Tab5 is a different host)" % label, flush=True)


try:
    discovery(HOST, "to %s" % HOST, True)
    discovery("255.255.255.255", "by broadcast", False)
    tab5 = socket.create_connection((HOST, 7355), 5)
    tab5.sendall(frame(1, b"QMXR/1 nettest"))
    tab5.settimeout(8)
    t, _f, n = HDR.unpack(rx(tab5, 4))
    hello = rx(tab5, n)
    say(t == 1 and hello.startswith(b"QMXR/1"), "Tab5 handshake on 7355: %s" % hello.decode(errors="replace"))

    fr = read_frames(tab5, 3.0)
    iq = sum(len(p) // 4 for t, p in fr if t == 2)
    pings = sum(1 for t, _ in fr if t == 4)
    say(40000 * 3 <= iq <= 56000 * 3, "I/Q over the network: %.0f pairs/s, %d pings" % (iq / 3.0, pings))

    for q in (b"ID;", b"FA;", b"VN;"):
        tab5.sendall(frame(3, q))
        cat = b""
        for t, p in read_frames(tab5, 2.0, lambda t, p: t == 3 and p.endswith(b";")):
            if t == 3:
                cat += p
        say(cat.endswith(b";"), "Tab5 CAT %s -> %s" % (q.decode(), cat.decode(errors="replace") or "(nothing)"))

    tab5.sendall(frame(5))                       # TERM_OPEN (Radio menus port) - nothing is sent on it
    status = [p for t, p in read_frames(tab5, 3.0, lambda t, p: t == 6) if t == 6]
    if status:
        okt = status[0][:1] == b"\x01"
        say(okt, "Radio menus port over the network: %s" % ("opens" if okt else status[0][1:].decode(errors="replace")))
    else:
        say(False, "Radio menus port: no TERM_STATUS reply")
    tab5.sendall(frame(8))                       # TERM_CLOSE
    time.sleep(0.3)

    pc = socket.create_connection((HOST, 7356), 5)
    pc.settimeout(3)
    pc.sendall(b"FA;")
    reply = b""
    end = time.monotonic() + 2
    while time.monotonic() < end and not reply.endswith(b";"):
        try:
            reply += pc.recv(256)
        except socket.timeout:
            break
    say(reply.endswith(b";"), "PC on port 3 (7356) while the Tab5 is connected: FA; -> %s" % reply.decode(errors="replace"))
    pc.close()

    tab5.sendall(frame(3, b"FA;"))
    cat = b"".join(p for t, p in read_frames(tab5, 2.0, lambda t, p: t == 3 and p.endswith(b";")) if t == 3)
    say(cat.endswith(b";"), "Tab5 still answered after the PC left: %s" % cat.decode(errors="replace"))
    tab5.close()
except Exception as e:
    say(False, "error: %r" % (e,))

print("NETTEST %s" % ("PASSED" if ok_all else "FAILED"), flush=True)
sys.exit(0 if ok_all else 1)

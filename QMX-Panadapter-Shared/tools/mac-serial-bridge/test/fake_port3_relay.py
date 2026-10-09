#!/usr/bin/env python3
# Bench test: stand-in for qmx_nas_relay.py port 3 (TCP 17356) with a tiny CAT emulator.
# Usage: python3 fake_port3_relay.py [ok|refuse]   (refuse = act like a radio without port 3)
import socket, sys, threading
mode = sys.argv[1] if len(sys.argv) > 1 else "ok"
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 17356)); srv.listen(2)
freq = [14074000]
def handle(c):
    if mode == "refuse": c.close(); print("refused", flush=True); return
    print("client", flush=True); buf = b""
    while True:
        d = c.recv(4096)
        if not d: print("client gone", flush=True); return
        print("got", d, flush=True); buf += d
        while b";" in buf:
            cmd, buf = buf.split(b";", 1)
            if cmd == b"FA": c.sendall(b"FA%011d;" % freq[0])
            elif cmd.startswith(b"FA"): freq[0] = int(cmd[2:])
            elif cmd == b"ID": c.sendall(b"ID020;")
            elif cmd == b"MD": c.sendall(b"MD3;")
while True:
    c, _ = srv.accept(); threading.Thread(target=handle, args=(c,), daemon=True).start()

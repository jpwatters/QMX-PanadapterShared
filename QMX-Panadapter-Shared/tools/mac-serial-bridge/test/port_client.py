#!/usr/bin/env python3
# Bench test: open the bridge serial port like an application and send CAT commands.
# Usage: python3 port_client.py <port path> "FA;" ["ID;" ...]   (ECHO=1 turns echo on first)
import os, sys, termios, tty, time, select
path = os.path.expanduser(sys.argv[1]); cmds = sys.argv[2:]
fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
if os.environ.get("ECHO"):   # simulate a sloppy app that turns echo on
    a = termios.tcgetattr(fd); a[3] |= termios.ECHO; termios.tcsetattr(fd, termios.TCSANOW, a)
for c in cmds:
    os.write(fd, c.encode()); r = b""; end = time.time() + 5
    while time.time() < end and not r.endswith(b";"):
        if select.select([fd], [], [], 0.2)[0]: r += os.read(fd, 256)
    print(c, "->", r.decode() or "(none)")
os.close(fd)

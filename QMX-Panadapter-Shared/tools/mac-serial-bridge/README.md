# QMX on the NAS as a serial port on the Mac

`qmx_serial_bridge.py` makes the QMX that's plugged into the Synology show up
on a Mac as a serial port, so programs that expect a USB-connected QMX (WSJT-X,
JTDX, fldigi, Hamlib/rigctld, loggers, `screen`) can use it unchanged.

```
QMX ──USB──▶ NAS (qmx_nas_relay.py) ──TCP 7356 (QMX serial port 3)──▶
     qmx_serial_bridge.py on the Mac ──▶ ~/cu.QMX-NAS  ◀── WSJT-X, rigctld …
```

It uses the relay's existing **port 3** service, so nothing changes on the NAS
or the Tab5. It finds the NAS the same way the Tab5's **Find NAS** does (see
below), so no address needs to be typed in. The Tab5 keeps its own connection, and both can control the radio
at the same time.

## Setup

1. On the radio: **System config → GPS & Ser. ports → USB serial ports = 3**.
2. On the Mac (needs only macOS's own Python 3):

   ```
   cd tools/mac-serial-bridge
   bash install-mac.sh                # find the NAS; or: bash install-mac.sh <NAS IP>
   ```

   This installs it as a login item that starts automatically and restarts if
   it stops. At the end it runs a read-only check (`ID;` `FA;` `MD;`) and should
   print `PROBE PASSED`.
3. In your program, choose the **QMX** (or Kenwood TS-480) rig and type this
   serial port path: `/Users/<you>/cu.QMX-NAS`. Any baud rate works.
   For PTT, use **CAT** (DTR/RTS lines don't go over the network).

Run it by hand instead of installing it:
`python3 qmx_serial_bridge.py -v` (`-v` logs every byte).
`python3 qmx_serial_bridge.py --discover` lists the relays that answer.
`bash uninstall-mac.sh` removes the login item.

## Finding the NAS

Unless `--host` is given, the bridge broadcasts `QMXR?` on UDP 7355 (three
times over 1.5 s, like the Tab5) and the relay answers straight back with
`QMXR! 10.0.0.137 7355`. The bridge takes the **address** from that answer.
The **port** in the answer is the relay's Tab5 service (QMXR/1, 7355); the
serial port uses the relay's port 3 service on the same NAS, **TCP 7356**
(`--port`), because 7355 carries the Tab5's framed I/Q stream, not raw serial.

* It searches when it starts, and again whenever the remembered address stops
  answering, so a NAS that gets a new address is followed automatically.
* If several relays answer, the first is used and the others are logged.
* The installer adds `--fallback-host 10.0.0.137`, used only when no relay
  answers (for example if broadcasts are blocked). `bash install-mac.sh <IP>`
  uses a fixed address and never searches.
* The NAS and the Mac must be on the same network; if DSM's firewall is on,
  allow UDP 7355 as well as TCP 7356.

## How it behaves

* It connects to the relay only when a program sends something, and releases
  the radio's port 3 after 120 s of silence (`--idle N`; `--keep-connected` to
  hold it all the time). A program that polls the radio, like WSJT-X, keeps it
  connected while it runs.
* If the QMX is off or the NAS can't be reached, commands get no reply, just as
  if a USB radio were switched off, and the bridge retries on the next command.
  If the radio isn't set to 3 serial ports, the log says so.
* Echo is always kept off on the port, so the radio's replies can never loop
  back into it.
* Log: `~/Library/Logs/qmx-serial-bridge.log`.
* If macOS blocks local-network access for python3 (System Settings → Privacy
  & Security → Local Network), both the search and the connection fail; the
  log points there when the NAS is unreachable.

## Limits

* **Serial (CAT) only, no audio.** For digital modes you still need the radio's
  audio on the Mac by some other route.
* The port is a pseudo-terminal at a path you choose, not a USB device in
  macOS's device list. Programs whose port list can't be edited won't list it.
  (Making macOS see a real USB serial device would need a DriverKit driver
  signed with entitlements from Apple.) Hamlib-based programs (WSJT-X, JTDX,
  fldigi, rigctld) accept a typed path.
* One PC at a time on port 3. A second Mac connecting takes over from the first.

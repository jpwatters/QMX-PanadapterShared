# QMX on the NAS for WS, WSJT-X and JTDX on the Mac (TCI)

The bridge makes the QMX that's plugged into the Synology usable from digital-mode
programs on a Mac. By default it is a **TCI server**: WS (formerly WSJT-X
Improved), WSJT-X 3 and JTDX connect to it as a network radio, and it carries
**receive audio, transmit and CAT** in that one connection. No serial port and
no virtual audio device are needed.

```
QMX ──USB──▶ NAS relay ──TCP 7357 (copy of the I/Q, listen only)──▶ ┐
                       ──TCP 7356 (QMX serial port 3, CAT)──────────▶ ┤ qmx_serial_bridge.py --tci
                                                                     │   ws://127.0.0.1:40001
                                                        WS / WSJT-X ◀┘   (TCI)
```

* **Receive:** the relay sends the bridge a copy of the radio's 48 kHz I/Q (the
  same stream the Tab5 gets, on its own port). The bridge turns it into
  upper-sideband audio (dial to dial + 3.2 kHz) and streams it to the program.
* **Control:** frequency, mode and transmit on/off become the QMX's own CAT
  commands (FA, MD, TX;/RX;) on serial port 3, which the Tab5 never uses.
* **Transmit:** FT8, FT4, JS8, WSPR and Tune send one tone at a time. The bridge
  measures each tone in the program's transmit audio and sends it to the QMX
  as `TA<Hz>;` - the same way the Tab5 transmits - on a fixed 50 ms delay so
  every symbol keeps its spacing (bench test: 160 ms ± 1 ms, within 0.2 Hz).
  **Voice (SSB) does not work**: the QMX has no transmit-audio path over the network.
* The Tab5 keeps its own connection: it can stay on the panadapter while WS
  runs on the Mac. While WS is connected the relay keeps the Tab5 off the
  transmitter (its transmit commands are dropped, and the Tab5 shows "TX locked:
  Another Device has the transmitter"), and while the Tab5 is
  transmitting it keeps the Mac off. A file named `tab5-tx-always` in the
  relay folder lets the Tab5 transmit anyway.

The bridge's older mode, a serial port at `~/cu.QMX-NAS` (CAT only), is still
there (`MODE=serial bash install-mac.sh`), but WS and WSJT-X could not open that
port on macOS, which is why TCI is now the default.

## Setup

1. On the radio: **System config → GPS & Ser. ports → USB serial ports = 3**.
2. The relay on the NAS must be the version with the I/Q copy (port 7357): copy
   the new `qmx_nas_relay.py` to the NAS, put `restart.request` in its folder
   and run the **QMX relay check** task. If DSM's firewall is on, allow TCP 7357
   as well as 7355/7356 and UDP 7355.
3. On the Mac:

   ```
   cd ~/src/QMX-Panadapter-NAS/tools/mac-serial-bridge
   bash install-mac.sh                # finds the NAS; or: bash install-mac.sh <NAS IP>
   ```

   It installs numpy for macOS's own Python 3 (once), installs the bridge as a
   login item that starts automatically and restarts if it stops, and ends with
   a read-only check that should print `PROBE PASSED` (port 3 and the I/Q copy).
   If macOS asks whether python3 may find devices on the local network, allow it.
4. In **WS** (or WSJT-X 3): **Settings → Radio**: Rig **TCI Client RX1**,
   TCI Server **127.0.0.1:40001**, PTT Method **CAT**, Mode **Data/Pkt**, Split
   Operation **None**. **Settings → Audio**: tick **Use TCI Audio**. Click OK and
   restart WS.

Run it by hand instead of installing it:
`python3 qmx_serial_bridge.py --tci -v` (`-v` logs every command).
`python3 qmx_serial_bridge.py --discover` lists the relays that answer.
`python3 qmx_serial_bridge.py --tci --probe` checks the relay once.
`bash uninstall-mac.sh` removes the login item.

## Finding the NAS

Unless `--host` is given, the bridge broadcasts `QMXR?` on UDP 7355 (three
times over 1.5 s, like the Tab5) and the relay answers straight back with
`QMXR! 10.0.0.137 7355`. The bridge takes the **address** from that answer.
The **port** in the answer is the relay's Tab5 service (QMXR/1, 7355), which the
bridge leaves to the Tab5. It uses the relay's port 3 service on the same NAS,
**TCP 7356** (`--port`), for CAT, and the I/Q copy, **TCP 7357** (`--iq-port`).

* It searches when it starts, and again whenever the remembered address stops
  answering, so a NAS that gets a new address is followed automatically.
* If several relays answer, the first is used and the others are logged.
* The installer adds `--fallback-host 10.0.0.137`, used only when no relay
  answers (for example if broadcasts are blocked). `bash install-mac.sh <IP>`
  uses a fixed address and never searches.
* The NAS and the Mac must be on the same network; if DSM's firewall is on,
  allow UDP 7355 as well as TCP 7356.

## How it behaves

* The bridge holds QMX serial port 3 and the I/Q copy only while a TCI program
  is connected, and releases both when it disconnects.
* It reads the radio's frequency and mode every second, so a change made on the
  Tab5 or the radio shows up in WS.
* It turns the QMX's I/Q mode on (`Q9 1;`) if it finds it off; the Tab5 needs
  it on too.
* While keyed, if the program sends no transmit audio for 3 s, the bridge keys
  the radio up by itself. When the program disconnects mid-transmission, the
  radio is put back in receive.
* Receive audio has a slow automatic level control; set WS's input level with
  its own slider.
* Log: `~/Library/Logs/qmx-serial-bridge.log`.
* If macOS blocks local-network access for python3 (System Settings → Privacy
  & Security → Local Network), both the search and the connection fail; the
  log points there when the NAS is unreachable.

## Limits

* **Transmit is one tone at a time** (FT8, FT4, JS8, WSPR, Tune), not voice.
* **Receive is upper sideband** from the I/Q, 0.1-3.2 kHz above the dial: what
  digital modes use.
* One TCI program at a time; a second one takes over from the first. One PC at
  a time on QMX port 3 (a PC program on TCP 7356 and the bridge share it).
* One transmitter at a time: while WS is connected the Tab5 can't transmit (see above).

# QMX on the Synology NAS → Tab5 over the network

The QMX stays plugged into the Synology. A small relay runs **on the NAS
itself**, and the Tab5 connects to it directly over WiFi. No other computer
is involved.

```
QMX ──USB──▶ Synology NAS  (qmx_nas_relay.py)
                  │  TCP 7355 (QMXR/1: I/Q 48 kHz + CAT + Radio menus)
                  ├──▶ Tab5 QMX-Panadapter   Radio → Radio source: NAS
                  │
                  │  TCP 7356 (QMX serial port 3, raw bytes)
                  └──▶ PC software (WSJT-X CAT, rigctld, a terminal …)
```

The QMX can present up to three USB serial ports (**System config → GPS &
Ser. ports → USB serial ports**). The relay uses them like this:

| QMX port | Used for | Needs "USB serial ports" |
|---|---|---|
| 1 | CAT for the Tab5 (panadapter, FT8, WSPR …) | 1 or more |
| 2 | Tab5 **Radio menus** (the QMX's own menu terminal) | 2 or 3 |
| 3 | PC software over the network, TCP 7356 | 3 |

The relay talks to the QMX from userspace, so it doesn't need any DSM kernel
drivers (DSM doesn't ship USB audio drivers). On the NAS it uses Linux usbfs
(`/dev/bus/usb`) directly and needs nothing but DSM's own Python 3; where
libusb-1.0 is available it uses that instead. It opens the QMX when the Tab5
or a PC on port 3 connects, and releases it when the last one disconnects.

## 1. Install the relay on the NAS

This runs on any DSM 7 model, including ARM models such as the DS416j that
have no Container Manager. Tested on a DS416j (DSM 7.4.1) with a QMX+.

1. Copy this folder to a shared folder on the NAS with File Station, e.g.
   `/volume1/File Share/qmx-relay`.
2. **Control Panel → Task Scheduler → Create → Triggered Task →
   User-defined script.** Task: `QMX relay`, User: `root`, Event:
   `Boot-up`. On **Task Settings**, Run command:

   ```
   sh "/volume1/File Share/qmx-relay/start-relay.sh"
   ```

   DSM warns about running scripts as root and asks for your password.
   Root is needed to open the USB device.
3. Select the task and click **Run** (it also starts on every boot).
   `start-relay.sh` keeps the relay running and restarts it if it exits.
   `stop-relay.sh` stops it.
4. Open `qmx-relay.log` in that folder. You should see `SELFTEST PASSED`,
   `listening on 0.0.0.0:7355 (QMXR/1 for the Tab5)` and
   `listening on 0.0.0.0:7356 (QMX port 3, raw serial for PC software)`.

On every start the relay runs a short **self-test** of the QMX and logs it.
It measures the I/Q stream, asks read-only CAT questions (`ID;` `FA;` `MD;`
`VN;`; nothing that transmits), and checks serial ports 2 and 3.

**Check from the NAS.** Create a second user-defined script task (root; a
Scheduled Task set to run once is fine) with
`sh "/volume1/File Share/qmx-relay/check.sh"` and click **Run**. It writes
`check.log`: system info, the USB devices, a probe of the QMX's interfaces,
and then either

* the relay is running: `nettest.py` connects to it like a Tab5 (handshake,
  I/Q rate, CAT, Radio menus port) and like a PC on port 3, and prints
  `NETTEST PASSED`; or
* it isn't: a one-off self-test of the QMX (`SELFTEST PASSED`).

If the probe says `QMX not found`, check that the radio is on and try another
USB cable: a charge-only cable powers the QMX but shows no device.

`get_libusb1.py` (run by the scripts) fetches python-libusb1 from PyPI, checked
against its published SHA-256. It is only used where libusb-1.0 exists; the
relay works without it.

### Updating the relay later

Copy the new files over the old ones with File Station, then create an empty
file named `restart.request` in the same folder and **Run** the check task.
`check.sh` sees the file, stops the running relay (the supervisor in
`start-relay.sh` starts the new version 5 s later, with its self-test), deletes
the file and then runs the network test. No new root task or password is needed.

### Docker (Container Manager) instead

On x86 models with Container Manager (DSM 7.2+) you can run it as a container:
**Container Manager → Project → Create**, Path = this folder, using the
existing `docker-compose.yml`. Or over SSH:

```
cd /volume1/docker/qmx-relay
sudo docker compose up -d --build
sudo docker logs -f qmx-relay
```

## 2. Point the Tab5 at the NAS

On the Tab5 itself: open the settings drawer and tap **Radio source** (top of
the Radio group). The button shows where the radio is and whether it is
connected, e.g. `NAS 10.0.0.137 ✓`, `NAS 10.0.0.137 (offline)` or
`Radio: USB`. Tap **Find NAS** to have the Tab5 look for the relay on the
network and fill in its address (or type the NAS's IP address), then tap
**Use NAS**, or tap
**Use USB** to go back to a QMX plugged into the Tab5. The last NAS address is
remembered, so switching back is one tap.

Or on the Tab5's web page, open the **Radio** menu, click **Radio source**, and
enter the NAS's IP address. It reads **Radio source: NAS (network)** once
connected, and the panadapter, FT8 and CAT work exactly as they do over USB.
Leave the field blank to go back to the QMX on the Tab5's own USB port.

You can also set `relay_host` / `relay_port` in the Tab5 config file, or call
`POST /api/relay {"host":"192.168.1.x","port":7355}`.
`GET /api/relay` shows the link state, the I/Q sample count and the last error.

### The Tab5 firmware needs the network-radio WiFi patches

The stream is a steady ~1.5 Mbit/s into the Tab5, far more than its WiFi
link (an ESP32-C6 on SDIO, driven by esp_hosted) normally receives. Two of the
project's standing patches make that work, and `tools/check_patches.py`
refuses a build without them:

* `apply_esp_hosted_sdio_split_bundles.ps1` - the C6 delivers several frames
  per SDIO transfer; stock code kept only the first, or discarded a large
  burst whole. Every frame is now delivered.
* `apply_esp_hosted_sdio_rx_copy_psram.ps1` - every received frame was copied
  into the Tab5's small internal RAM; under the stream that ran out and touch
  input and the web page stopped. The copy now goes to PSRAM.
* `apply_esp_hosted_sdio_split_psram.ps1` - received frames waited in the RX
  queue in blocks of a buffer pool that never gives memory back, so the pool
  grew until the Tab5's DMA-capable RAM was gone. Frames are now queued as
  PSRAM copies and the pool block is returned at once.

With these (and the TCP receive window at 11520 in `sdkconfig`) a Tab5 on WiFi
receives ~47,700 of the 48,000 I/Q pairs per second, measured on a DS416j and
a QMX+. Without them it gets 10-20k and touch input freezes.

### Building the Tab5 firmware on a Mac

```
bash tools/mac-build-flash.sh            # build + flash (asks before flashing)
bash tools/mac-build-flash.sh --build    # build only
bash tools/mac-capture-serial.sh 90      # record the Tab5's USB serial output
```

It uses the ESP-IDF in `~/esp/esp-idf` (v5.4.4) and an installed PowerShell
(`pwsh`, or `PWSH=/path/to/pwsh`) for the standing patches, keeps PlatformIO's
own Python out of ESP-IDF's way, applies and checks all patches, builds, and
does a normal flash (settings kept). Logs go to `build/mac-build-flash.log`.
The firmware reports itself as the release it is based on plus `-NAS`, e.g.
`v1.16.11-NAS`.

## 3. PC software on QMX port 3 (optional)

Set **USB serial ports = 3** on the radio. The relay then serves the QMX's
third serial port as a plain TCP port on the NAS, **7356**. Whatever a PC sends
there goes to the radio unchanged, and the radio's replies come straight back,
just like a serial cable. Use it for CAT control from WSJT-X, Hamlib/rigctld,
logging programs, or a terminal. Configure the program for the QMX exactly as
you would for a USB-connected QMX.

Most programs expect a COM port, so map one to the TCP port on the PC:

* **macOS / Linux:** `socat pty,link=$HOME/qmx-port3,raw,echo=0 tcp:<NAS IP>:7356`
  and point the program at `~/qmx-port3`.
* **Windows:** any "virtual serial port over TCP" tool, pointed at
  `<NAS IP>:7356`.
* Quick check: `nc <NAS IP> 7356`, then type `FA;` and the radio answers with
  its frequency.

Notes:

* Port 3 carries **serial data only, not audio**. For digital modes on the
  PC you still need the radio's audio there by other means. The Tab5 keeps
  its own I/Q stream either way.
* The PC and the Tab5 can use the radio at the same time, each on its own
  port. Changes made from the PC (frequency, mode) show up on the Tab5 within
  a poll cycle.
* One PC at a time on port 3; a new connection replaces the old one.
* With the radio set to 1 or 2 ports, a connection to 7356 is closed straight
  away and the log says why.
* Change the port with `--serial-port N`, or turn it off with
  `--serial-port 0` (add it to the `qmx_nas_relay.py` line in
  `start-relay.sh`, or to `command:` in `docker-compose.yml`).

## Behaviour

* If the QMX is powered off or unplugged, the relay closes the connection
  and the Tab5 treats it like a USB unplug. The Tab5 retries every ~2 s and
  reconnects on its own when the QMX comes back.
* The relay must be the only program on the NAS that uses the QMX. If the
  log says `QMX is in use by another program`, stop whatever else holds it.
* One Tab5 at a time. A new connection replaces the old one, so a rebooted
  Tab5 doesn't get locked out by its own stale session. A PC on port 3 is
  independent of the Tab5: either can come and go without affecting the other.
* **Radio menus** (the QMX's own menu system, on the web page's Radio menu)
  work over the network too. Like on USB, they use the QMX's *second* serial
  port, so CAT is never disturbed. Set **System config → GPS & Ser. ports →
  USB serial ports = 2** (or 3) on the radio. With one port, the Tab5 says so
  instead of opening.
* While a NAS address is set, a QMX plugged into the Tab5's USB port is ignored.
* If WiFi can't keep up, the relay drops I/Q frames rather than build up
  delay. It never drops CAT: radio replies are always sent ahead of queued
  I/Q, the I/Q queue holds only 3 frames (30 ms), and the NAS's kernel send
  buffer is kept small (8 KB), so CAT replies are never stuck behind seconds
  of spectrum data. Drops are counted in the log.
* Bandwidth is about 200 kB/s (48 kHz × 2 × 16-bit).
* **Discovery.** The relay also listens on **UDP** 7355. The Tab5's
  **Find NAS** broadcasts `QMXR?` three times over 1.5 s; every relay answers
  the Tab5 directly with `QMXR! <its IP address> <TCP port>`. Nothing is sent
  unless asked. Broadcasts stay on the local network, so the NAS and the Tab5
  must be on the same one; if DSM's firewall is on, allow UDP 7355 as well as
  TCP 7355/7356. `--discovery-port N` moves it, `--discovery-port 0` turns it
  off. `nettest.py` checks it (`discovery to 127.0.0.1`).
* Tested: switching NAS → USB → NAS from the drawer, and powering the QMX off
  and on (power lead pulled) while the Tab5 stays connected - the stream
  resumes by itself.
* The Tab5 sets the QMX's clock when it gets network time. Over the network
  that CAT write must not run on the network stack's own thread, or every
  connection on the Tab5 freezes for good about 20-50 s after boot (fixed in
  `wifi.c`; `radio_relay.c` refuses such a send instead of hanging).

## Troubleshooting

* **Touch dead, but the screen and stream keep running, even after a restart:**
  the touch chip itself is stuck, and the yellow button does not remove its
  power. Unplug the Tab5's USB-C (and switch off or remove its battery) for
  ~15 s, then power it on.
* `bash tools/mac-capture-serial.sh 120` records the Tab5's serial log. On a
  Mac, opening the port restarts the Tab5, so the log starts from boot.

## Bench test without the radio

```
python3 qmx_nas_relay.py --fake        # synthetic +3 kHz tone, CAT emulator on ports 1 and 3,
                                       # and a small menu terminal on port 2
```

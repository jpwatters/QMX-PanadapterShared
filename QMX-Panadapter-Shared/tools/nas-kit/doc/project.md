@title M5Stack Tab5 QMX+ Shared Over Network
@subtitle Sharing a QRP Labs QMX/QMX+ over the network with the M5Stack Tab5 QMX-Panadapter: Synology NAS relay, Raspberry Pi relay, Tab5 firmware and Mac tools

|~ 1.4 | 5.6
| Item | Value
| Firmware base | Upstream SteffenLav/qmx-panadapter **{BASE}**, plus the NAS patch series {SERIES} (reports itself as **{NAS}**)
| Folders (Mac) | ~/src/QMX-Panadapter-NAS (newest upstream + NAS patches; build, flash and test here); ~/src/QMX-Panadapter-Shared (last version tested on the hardware); ~/src/QMX-Panadapter-NAS/tools/nas-kit (the update kit, the current patch series and this document's source, copied into every build)
| Relay | tools/nas-relay/qmx_nas_relay.py (Python 3). Synology DSM: native, started by Task Scheduler. Raspberry Pi 4/5: the same file as a systemd service (tools/pi-relay)
| Network | TCP 7355 QMXR/1 to the Tab5 (I/Q, CAT, Radio menus, relay-timed transmit); TCP 7356 QMX serial port 3 for PC software; TCP 7357 listen-only I/Q copy; UDP 7355 discovery (QMXR? / QMXR!)
| Tested on | Synology DS416j, DSM 7.4.1, NAS at 10.0.0.137, with a QMX+ (firmware 1_03_002) and an M5Stack Tab5
| Toolchain | ESP-IDF v5.4.4, target ESP32-P4; built and flashed from a Mac with tools/mac-build-flash.sh
| Document date | {DATE}

{{TOC}}

# 1. Summary of outcome

The QMX-Panadapter firmware on the M5Stack Tab5 can use a QMX or QMX+ that is plugged into another machine on the network, a Synology NAS or a Raspberry Pi, instead of the Tab5’s own USB port. A small relay program on that machine owns the radio over USB and serves it to the Tab5 over Wi-Fi or wired Ethernet. Everything the Tab5 does with a USB-connected radio works over the network: the full-rate spectrum and waterfall, FT8/FT4 and WSPR receive and transmit, CAT control, RX audio and the radio’s own menus.

- **Synology relay**: runs natively on DSM 7 (no Container Manager or DSM drivers needed), started at boot by Task Scheduler and kept running by a supervisor script. Tested on a DS416j. It answers Find NAS on the network the question came from, so a VPN client on the NAS does not hide it.
- **Raspberry Pi relay**: the same relay file run as a systemd service on a Pi 4/5, with a control command, a log and limited automatic restarts. Written and checked against the Pi’s kernel interfaces; not yet run on a Pi.
- **Tab5 firmware**: a network-radio driver (QMXR/1 client), Radio source in the touchscreen drawer and on the web page, Find NAS discovery, Wi-Fi receive fixes that let the Tab5 take the full 48 kHz I/Q stream, and wired Ethernet through the M5Stack W5500 PoE base alongside Wi-Fi.
- **Relay-timed transmit**: the Tab5 hands each FT8/FT4 burst to the relay in one message and the relay plays every tone to the radio on its own clock. In 10 of 10 test bursts every tone reached the radio within 2 ms of schedule (see FT8 burst timing comparisons).
- **Operations**: CAT log of every command and reply, a power-off (PS0;) guard, a transmit log for every burst, one transmitter at a time, and flag files to change behaviour without a restart.
- **PC software**: the QMX’s third serial port is offered on TCP 7356 for PC software. On the Mac, a TCI server lets WS, WSJT-X 3 and JTDX use the radio with receive audio and FT8/FT4/JS8/WSPR transmit (bench-tested; not yet on the air).
- **Keeping current**: an update kit rebuilds the NAS version from every new upstream release and only promotes it to the Shared folder after it has been tested on the hardware. Section 9 records what each upstream release changed that stopped the patches applying, and how each was resolved.

## Change history (patch series)

{{PATCH_TABLE}}

!small {PORT_STATUS}

{{PAGEBREAK}}

# 2. Architecture

```
QMX / QMX+ --USB--> Synology NAS or Raspberry Pi 4/5  (qmx_nas_relay.py)
                         |
                         | TCP 7355  QMXR/1: I/Q 48 kHz, CAT, Radio menus, transmit bursts
                         +------------------------------> M5Stack Tab5 QMX-Panadapter
                         |                                (Radio source: NAS; Wi-Fi or W5500 Ethernet)
                         | TCP 7356  QMX serial port 3, raw bytes
                         +------------------------------> PC software / the Mac TCI bridge (CAT)
                         | TCP 7357  copy of the I/Q, listen only
                         +------------------------------> the Mac TCI bridge (receive audio for WS / WSJT-X)
                         |
                         + UDP 7355  answers "QMXR?" with "QMXR! <ip> <port>" (Find NAS)
```

The QMX presents itself over USB as a USB Audio Class device (the I/Q stream: 48 kHz, stereo, 24-bit) plus up to three CDC-ACM serial ports (System config → GPS & Ser. ports → USB serial ports). The relay uses them as follows:

|~ 1.1 | 4.6 | 1.3
| QMX port | Used for | Needs "USB serial ports"
| Audio (UAC) | I/Q to the Tab5: converted to 16-bit exactly as the Tab5’s own USB path does (s24 >> 8) | any
| Serial 1 | CAT for the Tab5: panadapter, FT8/FT4, WSPR, power/SWR | 1 or more
| Serial 2 | The Tab5’s Radio menus (the QMX’s own menu terminal), never mixed with CAT | 2 or 3
| Serial 3 | PC software over TCP 7356 (rigctld, loggers) or the Mac TCI bridge’s CAT | 3

## Components

|~ 1.5 | 1.6 | 3.9
| Component | Where it runs | What it does
| qmx_nas_relay.py | Synology NAS (DSM 7) or Raspberry Pi | Owns the QMX through Linux usbfs (or libusb), serves QMXR/1 to the Tab5, port 3 to PCs, answers discovery, keeps the CAT and transmit logs, times transmit bursts, allows one transmitter at a time
| Tab5 firmware ({NAS}) | M5Stack Tab5 (ESP32-P4) | QMXR/1 client (radio_relay.c) feeding the same audio ring and CAT parser as the USB drivers; Radio source UI; Wi-Fi receive fixes; W5500 Ethernet; relay-timed FT8/FT4 transmit
| Synology scripts | NAS | start-relay.sh (supervisor), stop-relay.sh, check.sh (diagnostics, restart.request), env.sh, nettest.py, get_libusb1.py, Docker files
| Pi scripts | Raspberry Pi | install-pi.sh / uninstall-pi.sh, qmx-relay-ctl, systemd service and timer, event logger, udev rule, logrotate
| Mac tools | Mac | qmx_serial_bridge.py --tci with qmx_tci.py (TCI server for WS / WSJT-X / JTDX), mac-build-flash.sh, mac-capture-serial.sh
| Test tools | Mac | tx-test/tx_compare.py, capture-tab5-console.sh; the web page’s 10-burst test button
| Update kit | Mac | make-qmx-panadapter-nas.sh (rebuild from a new upstream release), push-to-github.sh, doc/ (this document’s source and builder)

An open TCP session means "radio present". When the relay loses the QMX (powered off or unplugged) it closes the session, and the Tab5 treats it exactly like a USB unplug: it retries every ~2 s and resumes on its own when the radio comes back. One Tab5 and one port-3 client can use the radio at the same time; a new connection of the same kind replaces a stale one.

# 3. Why the data goes through a relay

## Why a relay at all

The QMX is a USB device: its I/Q audio and its serial ports exist only on the USB bus of the machine it is plugged into. To use it from anywhere else, something on that machine has to own the USB interfaces and carry their data over the network. The relay is that program, and it runs on the machine the radio is already plugged into (the NAS, or a Pi), so no extra computer sits in the path.

- **No drivers on the host.** DSM ships no USB audio driver, and the DS416j has no libusb. The relay talks to the QMX directly from userspace through Linux usbfs ioctls, so it needs only the Python 3 that DSM already has, and runs unchanged on a Pi.
- **Same data as USB.** The relay converts the I/Q exactly as the Tab5’s USB driver does and the Tab5 pushes it into the same sample ring, and CAT bytes go to the same parser. FFT, waterfall, FT8 decoding and the UI cannot tell the difference.
- **One connection, several streams.** I/Q, CAT and the menu terminal share one TCP connection, framed by QMXR/1 so each stream stays separate (the menu port can never disturb CAT).
- **Control ahead of bulk data.** The relay sends CAT replies before any queued I/Q, keeps only 3 I/Q frames (30 ms) queued, drops I/Q rather than build up delay, and keeps the kernel send buffer small, so a radio reply never waits behind seconds of spectrum data.
- **Shared access.** Because the relay owns the radio, it can serve the Tab5 and PC software at once, each on its own serial port, and can apply rules for everyone: the CAT log and the power-off guard.

## Why the whole transmit burst is sent to the relay

An FT8 transmission is 79 tones, each held for exactly 160 ms. Over USB the Tab5 sends one tone-change command (TA) every 160 ms and the radio follows it within a millisecond or two. Over the network, each of those 79 commands had to cross Wi-Fi on time. Most did, but the Tab5 only knows when it handed a command to its network stack, not when it reached the radio. The relay’s transmit log showed what the Tab5 could not see:

- 16:42:30: the Tab5’s send blocked while its Wi-Fi chip’s SDIO link was draining an oversize receive; the last symbols reached the radio 1.3 s late (RF on-air 13,643 ms instead of 12,640).
- 17:54:15, with I/Q already paused during transmit: one gap of 1,316 ms in transit (most likely a TCP retransmission), while the Tab5’s own figures were normal.

Pausing I/Q during transmit (patch 0017) removed one cause but not the other: one stall in ten bursts either way. The remedy is to stop depending on Wi-Fi during the burst. Since patch 0018 the Tab5 sends all 79 (FT8) or 105 (FT4) tone frequencies and the symbol period to the relay in one TX_SCHED message at key-down. The relay keys the QMX, sends each tone at key-down + i × 160 ms on the NAS’s own clock over its wired USB link, sends the key-up tone at the end and reports back (TX_DONE). A Wi-Fi hiccup during the burst can no longer delay a symbol; it could at most delay the start, which shows up in the key-down offset.

The Tab5 still runs its symbol loop on its own clock for the progress display, the live power/SWR reading, SWR protection and abort (an abort sends TX_ABORT and the relay keys up at once). It still sends the post-burst power/SWR query and the final RX;. If the hand-off fails the Tab5 sends the tones itself as before, and if no TX_DONE arrives it sends the key-up tone itself; if the Tab5 disconnects mid-burst the relay keys up and returns the radio to receive.

## Why I/Q is paused while transmitting

While the QMX transmits its I/Q is of no use, yet it is ~190 KB/s of traffic into the Tab5, the direction that overloads the Tab5’s Wi-Fi (ESP32-C6 over SDIO). Pausing it leaves the link nearly idle during the burst. Pings continue, so the Tab5’s 3 s idle timeout is not tripped; the pause is capped at 180 s in case RX; never comes. The spectrum and waterfall freeze for each burst.

## Why PS0; is blocked

While the radio was being debugged it was found switched off more than once. CAT can switch a QMX off (PS0;) but never on: once off, it is not on the USB bus at all. (The cause turned out to be a 12 V current limiter in the supply, not CAT.) The relay therefore blocks PS0; from the Tab5 and from PC software alike, logs it as BLOCKED, and lets it through only while a flag file allow-ps0 is present.

## Why one transmitter at a time

The Tab5 and a TCI program on the Mac (WS, WSJT-X) can both use the radio at once, but only one may transmit. The relay is the one place that sees both, so it decides: while the Mac’s TCI bridge is connected, the Tab5’s TX; and tone commands are dropped and its relay-timed bursts refused; while the Tab5 is keyed, TX; and tones on port 3 are dropped. Key-up commands always pass. Every refusal is logged as BLOCKED; the flag file tab5-tx-always lets the Tab5 transmit anyway. Tune (MD8;) counts as keying. The relay also tells the Tab5 (TX_LOCK), so instead of “transmitting” bursts that never reach the air, the Tab5 shows “TX locked: Another Device has the transmitter” on its FT8 screen, status line and web page, and refuses FT8/FT4, WSPR, Tune and power calibration until the Mac lets go.

## Why discovery, and why it answers from the arrival interface

The Tab5’s Find NAS and the Mac bridge broadcast QMXR? on UDP 7355; every relay answers with its address and port. No address needs to be typed, and a relay that gets a new address is found again. The relay sends nothing unless asked.

The relay answers with the address of the network interface the question arrived on, and sends the answer from that address (patch 0042). Until 2026-10-31 it answered by the routing table. With the DS416j’s VPN client (SSI_Connection, tun0, 192.168.113.5) connected and pushing a route for 10.0.0.0/24 - inside the LAN’s own 10.0.0.0/22 - the routing table sent the answer for a Tab5 at 10.0.0.28 into the tunnel, naming 192.168.113.5, and Find NAS found nothing, while TCP to 10.0.0.137 kept working because DSM routes replies from the LAN address out of eth0. The in_pktinfo spec_dst field could not be used for a broadcast: Linux fills it from the same route lookup, and it said 192.168.113.5 too.

# 4. QMXR/1 wire protocol

Every frame is a 4-byte header followed by the payload: u8 type, u8 flags (0), u16 length (little-endian). The Tab5 opens with HELLO; the relay answers HELLO only after it has opened the QMX, announcing its capabilities, e.g. `QMXR/1 rate=48000 ch=2 fmt=s16le src=nas term=1 txsched=1 txlock=1`.

|~ 0.4 | 1.2 | 1.1 | 4.3
| Type | Name | Direction | Payload
| 1 | HELLO | both | ASCII "QMXR/1 ..." with capability tokens
| 2 | IQ | relay → Tab5 | Interleaved int16 LE I/Q pairs, 48 kHz (480 pairs per frame)
| 3 | CAT | both | Raw CAT bytes for QMX serial port 1
| 4 | PING | relay → Tab5 | empty; once a second (the Tab5 treats 3 s of silence as a lost link)
| 5 | TERM_OPEN | Tab5 → relay | Open serial port 2 (Radio menus)
| 6 | TERM_STATUS | relay → Tab5 | u8 ok (1/0) [+ reason text]; also unsolicited if the port goes away
| 7 | TERM_DATA | both | Bytes on serial port 2
| 8 | TERM_CLOSE | Tab5 → relay | Close serial port 2
| 9 | TX_SCHED | Tab5 → relay | u8 version (1), u8 flags (0), u16 n, u32 symbol period (µs), then n × u32 tone frequency in centi-Hz. Relay keys the QMX at once.
| 10 | TX_ABORT | Tab5 → relay | empty; stop now and send the key-up tone
| 11 | TX_DONE | relay → Tab5 | u8 status (0 complete, 1 aborted, 2 failed), u16 tones sent, u32 ms TX; → key-up, i32 ms latest symbol vs schedule
| 12 | TX_LOCK | relay → Tab5 | u8 locked (1/0) [+ reason text]; after HELLO and whenever it changes. While 1 the Tab5 shows “TX locked: Another Device has the transmitter”

Tone frequencies are sent in centi-Hz so the relay prints exactly the TAnnnn.nn; command the Tab5 would have sent. Types 9-11 are used only when the relay announces txsched=1; with an older relay, or with the flag file tab5-timed-tx present, the Tab5 sends every tone itself.

## Discovery (UDP 7355)

```
Tab5 / Mac  -> broadcast  QMXR?                          (3 times over 1.5 s)
each relay  -> direct     QMXR! <relay IP> <TCP port>    e.g. QMXR! 10.0.0.137 7355
```

# 5. Tab5 firmware changes

## Driver side

- **main/net/radio_relay.c/.h** (new): the QMXR/1 client. Connect and handshake, a receive task that feeds I/Q into the audio ring and CAT into the CAT parser, the Radio menus channel, UDP discovery, relay-timed transmit (radio_relay_tx_schedule / tx_abort / tx_wait_done), and diagnostics for /api/relay. Refuses to send from lwIP’s own thread instead of deadlocking it.
- **main/cat/cat.c/.h**: a network transport branch inside upstream’s own cat_tx(), so every CAT write - including upstream’s GP/TM probes - works over the network; upstream’s raw-CAT door accepts USB or network; cat_get_transport() reports "usb", "net" or "none". A frequency the radio refuses (e.g. 60 m on a QMX+ with 1_03_002 that has the band disabled) puts the display back and says so (patch 0039).
- **main/audio/audio.c/.h**: an entry point for network I/Q into the same ring the USB audio driver fills.
- **main/wifi/wifi.c**: the QMX clock update after network time runs on a worker task with its microseconds, not on the lwIP thread (it froze every connection 20-50 s after boot). The got-IP services start from one function that Ethernet calls too, and upstream’s tcpip-stack guard is also set by the Ethernet task.
- **main/qmx_term.c**: Radio menus over the network on serial port 2.
- **main/net/eth_w5500.c/.h** (new): wired Ethernet through the M5Stack W5500 PoE base on the M5-Bus (section 5.1). net_is_up() (Ethernet or Wi-Fi) replaces wifi_is_connected() in the network features.
- **Wi-Fi receive patches** (tools/patches): esp_hosted SDIO receive keeps every frame of a bundled transfer, copies frames to PSRAM instead of internal RAM, and returns pool blocks at once; with the TCP window at 11520 the Tab5 receives ~47,700 of 48,000 I/Q pairs a second. The PSRAM copy also drops a frame when no memory is left instead of rebooting, which is what upstream’s v1.24.2 copypayload patch does, so it carries that patch’s marker as well. tools/check_patches.py refuses a build without them.

## Application side

- **main/ui/ui.c**: Radio source in the settings drawer: shows USB or NAS and whether it is connected, with Find NAS, Use NAS and Use USB; the last NAS address is remembered.
- **main/net/webserver.c, www/index.html**: Radio source on the web page (Radio menu, with its own Find NAS) and /api/relay, /api/relay/find; the URI handler limit raised so the live-spectrum socket registers; the 10-burst test button (shown only at http://qmx.local/?test); the bottom bar names Ethernet while it is in use; /api/status reports eth.
- **main/ft8_tx.c**: hands each FT8/FT4 burst to the relay when it is connected over the network and the relay supports it; logs the relay’s TX_DONE report; refuses to key while the relay reports TX locked.
- **main/rtty_tx.c**: upstream’s RTTY transmit (v2.0.0) refuses while the relay reports TX locked. Its tones are sent by the Tab5 itself, not relay-timed.
- **main/storage/settings.c/.h, config_io.c, main.c**: relay_host / relay_port settings (dirty bit DIRTY_RELAY, now 163 with DIRTY_WORDS 6), the config-file keys, and start-up.
- **Version**: builds report the upstream version with -NAS appended, e.g. {NAS}.

## 5.1 Wired Ethernet: M5Stack W5500 PoE base

The Tab5 can be wired to the network with M5Stack’s W5500 PoE base on its M5-Bus, the connector on the back. Ethernet runs alongside Wi-Fi rather than replacing it: its network interface has a higher route priority (200 against the Wi-Fi station’s 100), so while the cable has a DHCP address it carries every new connection - the NAS relay stream, the web page, spots, SNTP, updates - and when the cable is pulled traffic falls back to Wi-Fi by itself. qmx.local is announced on both links. With no base fitted nothing changes. The base has been detected on the Tab5 (eth.present in /api/status); it has not yet been used with a cable.

### Installation

- Power the Tab5 off and plug the base onto the M5-Bus. No wiring or soldering. Leave Port B unplugged: G52 is also Port B’s output.
- Connect the base’s Ethernet port to the switch. PoE (IEEE 802.3af) powers the base; keep the Tab5 on its own USB-C power - M5Stack documents the Tab5’s M5-Bus 5 V as an output, so it is not confirmed that the Tab5 can run from the base.
- Flash the firmware as usual (bash tools/mac-build-flash.sh) and power-cycle the Tab5. Nothing to configure: the firmware looks for the base at every boot.
- Give the Tab5 a DHCP reservation for its Ethernet MAC address (different from the Wi-Fi one); the serial log and /api/status (eth.mac) show it.

|~ 1.3 | 1.1 | 1.1 | 3.5
| W5500 signal | M5-Bus pin | Tab5 GPIO | Note
| MOSI | 7 | G18 |
| MISO | 9 | G19 |
| SCK | 11 | G5 |
| CS | 10 | G52 | Also Port B output
| INT | 26 | G51 |
| RST | 22 | G48 | Set explicitly: IDF’s default PHY reset pin is GPIO 5, the SCK

The base is driven on the ESP32-P4’s SPI3 bus at 20 MHz (SPI2 belongs to the SD card), with CONFIG_ETH_SPI_ETHERNET_W5500=y in sdkconfig and sdkconfig.defaults.

### Operation

|~ 1.5 | 5.5
| Situation | What happens
| Startup, base fitted | Log: "W5500 PoE base found on the M5-Bus, MAC ...", then "link up: 100 Mbit/s full duplex" and "address ... - Ethernet is now the preferred route". The bottom bar shows Ethernet and its address; the web page shows "Ethernet <ip>" (speed and address in its tooltip). Find NAS searches over Ethernet.
| Startup, no base | One log line, "no W5500 PoE base on the M5-Bus - Wi-Fi only"; everything as before.
| Cable pulled | "link down": the NAS relay link drops and reconnects over Wi-Fi within seconds; the bottom bar goes back to the Wi-Fi network.
| Cable back | New connections use Ethernet again.
| Shutdown | No procedure: unplug USB-C and the Ethernet cable. Settings are saved as they change.
| Scripts | /api/status has an eth object: present, link, in_use, ip, mbps, full_duplex, mac.

# 6. Synology relay: installation, operation and maintenance

## Installation

- Copy the tools/nas-relay folder to a shared folder on the NAS with File Station, e.g. /volume1/File Share/qmx-relay.
- Control Panel → Task Scheduler → Create → Triggered Task → User-defined script. Task QMX relay, user root, event Boot-up, run command `sh "/volume1/File Share/qmx-relay/start-relay.sh"`. DSM asks for your password because the task runs as root (needed to open the USB device).
- Select the task and click Run (it also starts on every boot). start-relay.sh keeps the relay running and restarts it if it exits.
- Create a second user-defined task, QMX relay check (root, a scheduled task set to run once is fine), with `sh "/volume1/File Share/qmx-relay/check.sh"`.
- Open qmx-relay.log in the folder: expect SELFTEST PASSED and "listening on 0.0.0.0:7355" and ":7356".
- On the Tab5: settings drawer → Radio source → Find NAS, then Use NAS.
- On the radio: USB serial ports = 2 for Radio menus, 3 to also serve PC software on TCP 7356. If the DSM firewall is on, allow TCP 7355-7357 and UDP 7355.

## Operation

|~ 2.4 | 4.6
| Script / task | What it does
| start-relay.sh (task QMX relay, boot) | Supervisor: runs the relay with --selftest, restarts it 5 s after it exits, writes qmx-relay.log
| stop-relay.sh | Stops the supervisor and the relay
| check.sh (task QMX relay check) | Writes check.log: system info, USB devices, a probe of the QMX’s interfaces; then nettest.py against the running relay (NETTEST PASSED) or a one-off self-test. Also handles restart.request (see Maintenance)
| nettest.py | Connects like a Tab5 (handshake, I/Q rate, CAT, Radio menus) and like a PC on port 3; checks discovery. Read-only: never transmits
| env.sh, get_libusb1.py | Environment for the scripts; fetches python-libusb1 (SHA-256 checked) where libusb-1.0 exists. Not needed on the DS416j (usbfs backend)
| Dockerfile, docker-compose.yml | Alternative for x86 models with Container Manager
| qmx_nas_relay.py --fake | Bench test without a radio: synthetic tone, CAT emulator, menu terminal

## Flag files (in the relay folder, re-checked every 2 s, no restart needed)

|~ 1.4 | 5.6
| File | Effect
| restart.request | Run the QMX relay check task: the relay is stopped and the supervisor starts the new version 5 s later, then the network test runs (check.log about 30 s later). On the DS416j the file is not deleted (a Synology ACL refuses even root), so each run of the check task restarts the relay while it is there
| catlog.off | Pauses the CAT log (catlog/catlog-<date>.log, 40 MB a day cap)
| allow-ps0 | Lets the power-off command PS0; through (blocked by default)
| iq-during-tx | Keeps I/Q streaming to the Tab5 while transmitting (paused by default)
| tab5-timed-tx | The Tab5 times each tone itself instead of the relay (takes effect when the Tab5 next connects)
| tab5-tx-always | Lets the Tab5 transmit even while a TCI program on the Mac is connected (normally the Tab5 is kept off the transmitter then)

## Logs

|~ 2.0 | 5.0
| Log | Contents
| qmx-relay.log | Self-test, connections, discovery answers (with the address used), warnings, blocked PS0;, transmit summaries
| check.log | Output of the QMX relay check task
| catlog/catlog-<date>.log | Every CAT command and reply, timestamped; labels T5>QMX, QMX>T5, PC>QMX, QMX>PC, T5 menu, RELAY>QMX
| txlog/txlog-<date>.log | One entry per transmit burst: every command handed to the QMX on the NAS clock, RF on-air, tone gaps, symbol timing, I/Q mode, who timed the tones. Off with --txlog-dir ''

## Maintenance

- **Updating the relay**: copy the new files over the old ones with File Station, create an empty file restart.request in the folder and Run the QMX relay check task. No new root task or password is needed.
- **QMX not found in check.log**: check that the radio is on and powered, and try another USB cable (a charge-only cable powers the QMX but shows no device). The radio needs its own supply; the relay keeps running while it is off and the Tab5 reconnects when it returns.
- **QMX is in use by another program**: the relay must be the only program using the radio. Never run a NAS relay and a Pi relay on the same radio.
- **Find NAS finds nothing, but typing the address works**: look at the discovery line in qmx-relay.log. A note "the routing table would have used ..." means a VPN or second network on the NAS claims the LAN’s range; the relay answers on the arrival interface regardless (patch 0042), but other traffic the NAS starts toward the LAN may still go into the VPN.
- **Touch dead on the Tab5 after a restart without power-off**: unplug its USB-C and battery for ~15 s.

# 7. Raspberry Pi relay: installation, operation and maintenance

The Pi runs the same qmx_nas_relay.py, unchanged: it reaches the QMX through Linux usbfs, which the Pi has. Its USB structures and ioctl numbers were checked against the 64-bit ARM kernel headers; on the Pi it detaches the kernel’s serial and audio drivers from the QMX, as on any Linux. Status: written, not yet run on a Pi.

## Installation

```
# on the Mac: copy the relay and the Pi scripts to the Pi (Raspberry Pi OS Bookworm, 64-bit)
rsync -a ~/src/QMX-Panadapter-NAS/tools/{nas-relay,pi-relay} pi@qmxpi.local:qmx/tools/
# on the Pi
cd ~/qmx/tools/pi-relay
sudo bash install-pi.sh              # install and start now
sudo bash install-pi.sh --no-start   # install; start 60 s after the next boot
```

Then on the Tab5: Radio source → Find NAS finds the Pi. Set USB serial ports = 3 on the radio for PC software on TCP 7356.

## How it starts and restarts

|~ 1.6 | 5.4
| Situation | Behaviour
| After a reboot | qmx-relay.timer starts the relay 60 s after boot (OnBootSec=60s)
| If it fails | Restart=on-failure, 10 s apart, up to 3 restarts (StartLimitBurst=4)
| After 3 restarts | Stays stopped until the next reboot or sudo qmx-relay-ctl restart; qmx-relay-gaveup.service writes GAVE UP in the log
| Stopped by hand | sudo qmx-relay-ctl stop is not counted as a failure

## Operation and maintenance commands

```
qmx-relay-ctl status          # service, timer, restarts used, ports, QMX on USB, last log lines
qmx-relay-ctl log 100         # last 100 log lines
qmx-relay-ctl follow          # watch the log
qmx-relay-ctl test            # network test (read-only, never transmits)
sudo qmx-relay-ctl probe      # USB devices and the QMX's interfaces
sudo qmx-relay-ctl restart    # start again now, with a fresh 3 restarts
sudo qmx-relay-ctl stop       # stop (starts again 60 s after the next boot)
sudo bash uninstall-pi.sh     # remove (--purge also removes the log and settings)
```

|~ 2.4 | 4.6
| File | Purpose
| install-pi.sh / uninstall-pi.sh | Install or remove the relay, units, rules, settings and log rotation
| qmx-relay-ctl | Everyday control command (above)
| qmx-relay-event.sh | Writes SERVICE lines (boot, start, failure, restart count, GAVE UP) into the log
| /etc/default/qmx-relay | RELAY_ARGS and QMX_BACKEND; then sudo qmx-relay-ctl restart
| systemd/qmx-relay.service, .timer, -boot, -gaveup | Service with hardening (NoNewPrivileges, ProtectSystem, ProtectHome, PrivateTmp), the 60 s boot timer and the event hooks
| udev/70-qmx-relay.rules | Keeps ModemManager and PipeWire/PulseAudio away from the QMX; no USB autosuspend
| logrotate/qmx-relay | /var/log/qmx-relay/qmx-relay.log rotated weekly, 8 kept

The flag files of the Synology section work the same way in the Pi relay’s folder.

# 8. Mac tools and the update kit

- **TCI bridge** (tools/mac-serial-bridge, --tci): a TCI server at ws://127.0.0.1:40001 for WS (formerly WSJT-X Improved), WSJT-X 3 and JTDX. Receive audio is made on the Mac from the relay’s listen-only I/Q copy (TCP 7357): the dial sits at +12 kHz, the band from the dial to dial+3.2 kHz is shifted down and kept as upper-sideband audio with a slow level control. Frequency, mode and PTT become FA/MD/TX;/RX; on QMX serial port 3. Transmit: the program’s audio is requested in real time (TCI tx_chrono, 10 ms); each tone is measured from its zero crossings once it has settled and sent as TA<Hz>; at a fixed 50 ms after the half-way point of the transition. Bench test with the fake radio: 12 GFSK tones at 160 ms ± 1 ms spacing, within 0.2 Hz. Voice does not work.
- **QMX Bridge** (tools/mac-bridge-app): a native Swift/SwiftUI app that replaces the Python bridge in one window - Discover (QMXR? on UDP 7355), Probe (read-only ID; FA; MD; on port 3 and the I/Q copy’s hello), the port-3 serial port (connect on demand, release after 120 s idle) and the TCI server (the same demodulator, tone tracker and 3 s transmit watchdog). Its serial port is either a virtual USB serial port, /dev/cu.QMX-NAS, made by QMXSerialDriver.dext - a DriverKit IOUserSerial driver with no hardware, which hands what programs write to the app and puts the radio’s replies in the receive ring - or a pseudo-terminal at ~/cu.QMX-NAS (QMX Bridge Lite.app, no driver). build.sh generates the Xcode project with XcodeGen and builds both apps. The driver loads only when signed with the DriverKit entitlements Apple grants per team; until then it needs SIP relaxed and systemextensionsctl developer on. Built with Xcode 27.2; not yet tested on the air.
- **Why TCI**: WS and WSJT-X on macOS never opened the bridge’s pseudo-terminal serial port (the bridge’s log shows no byte from them), and FT8 programs also need audio both ways. TCI carries CAT and audio in one network connection, so neither a serial device nor a virtual audio device is needed.
- **Build and flash**: bash tools/mac-build-flash.sh (ESP-IDF v5.4.4 in ~/esp/esp-idf, pwsh for the standing patches; applies and checks all patches, builds, asks before a normal flash). Nothing may be plugged into the Tab5’s USB-A port while flashing; power the Tab5 off and on afterwards.
- **Serial log**: bash tools/mac-capture-serial.sh 90. Opening the port restarts the Tab5, so for timing tests use the Tab5’s own log at http://qmx.local/api/log instead.
- **Update kit**: bash tools/nas-kit/make-qmx-panadapter-nas.sh downloads the newest upstream release and applies patches {SERIES} into ~/src/QMX-Panadapter-NAS; --mark-tested copies it to ~/src/QMX-Panadapter-Shared after a hardware test; replaced folders go to ~/src/.qmx-panadapter-archive. push-to-github.sh publishes both folders to jpwatters/QMX-PanadapterShared.
- **The kit travels with the build**: every build copies the kit (scripts, README, the current patch series and doc/, the source and builder of this document) into tools/nas-kit of the new QMX-Panadapter-NAS, so the next version is built from ~/src/QMX-Panadapter-NAS/tools/nas-kit. Run from there, the script first copies itself to a temporary folder, because a rebuild moves that folder to the archive. The kit does not treat any release as tested at first, so a first build does not copy itself to Shared.
- **This document**: python3 tools/nas-kit/doc/build_pdf.py ~/src/QMX-Panadapter-NAS writes it from doc/project.md, the git history (change history) and the current code (listings), so the version, the patch table and the listings always match the folder it is built from.

## TCI bridge setup

```
# on the radio: System config -> GPS & Ser. ports -> USB serial ports = 3
# on the NAS: the relay version with the I/Q copy (TCP 7357); allow 7357 in DSM's firewall if it is on
cd ~/src/QMX-Panadapter-NAS/tools/mac-serial-bridge
bash install-mac.sh                          # numpy (once), login item, ends with PROBE PASSED
python3 qmx_serial_bridge.py --tci -v        # run by hand instead (-v logs every command)
python3 qmx_serial_bridge.py --tci --probe   # check the relay once
MODE=serial bash install-mac.sh              # the old serial port ~/cu.QMX-NAS (CAT only)
bash uninstall-mac.sh                        # remove the login item
```

In WS or WSJT-X 3: Settings → Radio: Rig TCI Client RX1, TCI Server 127.0.0.1:40001, PTT Method CAT, Mode Data/Pkt, Split None; Settings → Audio: tick Use TCI Audio, then restart the program. The Tab5 keeps its own connection; the relay lets only one of them transmit at a time.

# 9. Keeping up with upstream: what each release changed

Upstream (SteffenLav/qmx-panadapter) releases often, and each release is a moving target for the NAS patches: new settings take the same slots in the settings bitmap, new drawer sections take the same ids, and files the patches touch get rewritten or removed. When git am --3way cannot merge a patch, the kit stops, leaves the NAS and Shared folders untouched and keeps the failed attempt in the archive. The series is then rebased onto the new release by hand, built, checked against upstream’s own checks and host tests, and a new kit is committed. The table lists what stopped each release and how it was resolved.

|~ 0.85 | 2.45 | 3.8
| Release (ported) | What stopped the patches | Resolution
| v1.20.5 (2026-10-23) | Settings bits 143-144 taken; upstream now sends every CAT command through its own cat_tx(); new raw-CAT door; SNTP hand-over changed; a new band guard in front of transmit | DIRTY_RELAY 145; the network transport became a branch inside cat_tx() and the raw-CAT door accepts USB or network (0001); the SNTP time is handed over with its microseconds (0005); the TX-locked refusal sits after the band guard (0029); the KS keyer-speed patch became empty and was dropped
| v1.21.0 (2026-10-25) | Bits 145-146 (spectrum peak hold, CW peak filter); drawer section 52 (server mode); five new "Switch to ..." entries in the web Radio menu | DIRTY_RELAY 147; Radio source drawer section 53; "Radio source" placed under upstream’s Switch-to entries (0001, 0005)
| v1.22.0 (2026-10-28) | Bits 147-150 (log view, SSB low-cut, FT4/JS8 presets); drawer section 53 (manual log); a new Scheduled events pane that only asked for Wi-Fi; upstream tags became annotated, and the kit’s download printed "is not a commit!" | DIRTY_RELAY 151; Radio source section 55; the Scheduled events pane accepts Ethernet or Wi-Fi (0040); the kit fetches the tag and checks out the commit it points to
| v1.23.0 (2026-10-31) | Bit 151 (alternate JS8 submode); a new standing patch for esp_hosted’s RPC table | DIRTY_RELAY 152; the new standing patch is applied with the others before the build
| v1.23.1 (2026-10-31) | Upstream changed the README lines above the NAS Ethernet section, and git am had no base copy to merge from ("sha1 information is lacking"); a new tcpip-stack guard that only Wi-Fi set | The series was rebased on v1.23.1 itself, so the kit no longer needs a 3-way merge; the Ethernet task also sets the tcpip-stack guard, and Wi-Fi accepts a default event loop Ethernet created first (0040)
| v1.24.1 (2026-11-04) | Bits 152-156 (web-radio player, CW page, macro sets); the settings flush now works on a snapshot pointer; drawer sections 54-55 (web radio, CW practice); dxcluster.c, psk_rx.c and rbn.c rewritten to read single settings; a new Helix MP3 component | DIRTY_RELAY 157 and the relay’s NVS writes use snap->; Radio source section 56; the rewritten feeds keep net_is_up() (0040); the new component and its standing patch build as upstream’s do
| v1.24.2 (2026-11-05) | Bits 157-158 (CW RST cut, contest serial) left only bit 159; drawer section 56 (Semi QSK); upstream’s new apply_esp_hosted_sdio_copypayload_tolerant.ps1 edits the same allocation as the NAS’s PSRAM copy patch, so check_patches refused to build | DIRTY_RELAY 159; Radio source section 57; the NAS patch script accepts either order, keeps its drop-on-failure code, and carries upstream’s marker (0004)
| v1.26.1 (2026-11-12) | Bit 159 taken - the settings bitmap was full; new TX power and noise-reduction rows in the web Radio menu; dxcluster.c and rbn.c removed (spots now come through spots.c); the web bottom bar shows only the network name | DIRTY_WORDS raised from 5 to 6 (192 bits) and DIRTY_RELAY 160 (31 free); "Radio source" kept under "Switch to WSPR"; nothing to carry for the removed files, because spots.c already accepts Ethernet or Wi-Fi; the bottom bar shows "Ethernet <ip>" while the W5500 base is in use (0001, 0040)
| v1.26.3 (2026-11-13) | Nothing: the series applied as it was | - |
| v2.0.0 (2026-11-15) | Upstream raised DIRTY_WORDS to 6 itself and took bit 160 for RTTY; /api/status gained rtty_mark_off where the NAS adds radio_link; set_frequency() became set_frequency_from(); upstream’s apply_esp_hosted_sdio_recovery.ps1 now re-runs the other sdio patches with a command named "powershell", which macOS does not have; RTTY transmit is new; the NAS’s own sdio PSRAM-copy script carried a regex with literal line ends that missed on a CRLF checkout | DIRTY_RELAY 161; both status fields kept (0001); the refused-frequency check moved into set_frequency_from() (0039); the recovery script runs the other patches with the PowerShell already running it, pwsh on the Mac (0044); RTTY refuses to transmit while another device has the transmitter (0045); the regex uses \r?\n (0004) |
| v2.0.2 (2026-11-18) | Upstream took bit 161 for the RTTY contest settings (R030) and bit 162 for the TX subnet interlock (T206); the README’s licence section, which the NAS appendix follows, gained the MP3-decoder licence note; the web radio’s Helix MP3 component was replaced by minimp3 vendored in the tree | DIRTY_RELAY 163 (28 free) (0001); the appendix kept after upstream’s new licence text (0041); nothing to carry for the MP3 decoder. Upstream’s new check_tx_guard passes on the NAS version |

!small Each port is checked the same way: a full ESP-IDF v5.4.4 build with every source compiled and the standing patches applied, upstream’s check scripts (check_dirty_bits, check_tx_guard, check_unattended_tx, check_web, check_webui, check_docs) and host harnesses run on plain upstream and on the NAS version with the same results, and the new kit run against GitHub on the Mac, producing the same tree. The relay’s discovery fix (0042, 2026-10-31) was not a port: it was found on the NAS when a VPN client was connected (section 3).

# 10. FT8 burst timing comparisons

## The FT8 burst

An FT8 transmission carries a 77-bit message plus a 14-bit CRC (91 bits), LDPC-encoded to 174 bits and sent as 58 data symbols of 3 bits each, with three 7-symbol Costas synchronisation arrays at symbols 0-6, 36-42 and 72-78: 79 symbols in all. Each symbol is one of 8 tones 6.25 Hz apart, held for 160 ms, so a correct burst is 79 × 160 ms = 12,640 ms of RF and occupies about 50 Hz. The transmitter changes tone with one TA command per symbol, then keys up with TA0;. FT4 uses 105 symbols of 48 ms.

## How it was measured

- The relay writes every burst to its transmit log with each command’s time on the NAS clock; the Tab5 logs its own key-down offset and on-air time on its own clock. tx_compare.py pairs bursts by FT8 slot.
- **One clock per number.** Every interval compared has both ends on the same clock. The NAS and Tab5 clocks are used only to identify the slot; a Tab5 time is never subtracted from a NAS time.
- A stall is a gap between two tone changes at the radio of more than 300 ms, or RF on-air more than 20 ms from 12,640 ms. Ten consecutive CQs were sent with the web page’s 10-burst test button into a dummy load. The runs were made on 2026-10-14; the transmit path (ft8_tx.c, radio_relay.c, the relay) is unchanged since apart from upstream’s own changes.

## Summary by run (2026-10-14, local time)

|~ 0.4 | 0.9 | 0.6 | 0.7 | 0.6 | 0.5 | 0.7 | 0.8 | 1.0 | 0.8
| Run | Time | Tones timed by | I/Q in TX | Bursts | Stalls | Longest gap (ms) | Worst symbol (ms late) | RF on-air min-max (ms) | Relay key-down mean (+ms)
| 1 | 10:54-10:58 | Tab5 | streamed | 8 | 0 | 236 | +69 | 12624-12656 | +290
| 2 | 16:42-16:46 | Tab5 | streamed | 10 | 1 | 1505 | +1342 | 12627-13643 | +610
| 3 | 17:53-17:58 | Tab5 | paused | 10 | 1 | 1316 | +1145 | 12620-12638 | +408
| 4 | 18:45-18:50 | relay | paused | 10 | 0 | 161 | +2 | 12640-12641 | +209

!small Ideal: longest gap 160 ms, symbol timing 0 ms, RF on-air 12,640 ms. Run 1 used the relay before the I/Q pause existed. "Relay key-down" is when the slot’s first command reached the radio, NAS clock vs UTC; it includes the Tab5’s own start-up delay.

## What the runs show

- **Runs 1-3 (Tab5 timing)**: most bursts were close to ideal, but one burst in ten stalled in runs 2 and 3 (1.5 s and 1.3 s gaps). In run 1, tone gaps of 175-236 ms and up to 13 tone changes per burst more than 20 ms off show Wi-Fi jitter even without a stall.
- **Pausing I/Q (run 3)** did not remove stalls: the 17:54:15 stall happened in transit with the link nearly idle.
- **Relay timing (run 4)**: every burst 12,640-12,641 ms, longest gap 160-161 ms, no tone change more than 20 ms off, worst symbol +2 ms. Ten bursts cannot prove stalls are gone for good (they came about once in 10-18 bursts), but a Wi-Fi delay during the burst can no longer reach the radio.
- **Late key-down** (17:53:45, +1,647 ms) is unrelated to the network: the CQ waited for the previous slot’s decode before transmitting.

## Every burst

!small Relay columns are on the NAS clock, Tab5 columns on the Tab5 clock (Tab5 logs were kept for run 4 only). Stalled bursts are marked.

|~ 0.4 | 0.75 | 0.65 | 0.65 | 0.65 | 0.65 | 0.55 | 0.9 | 0.6 | 0.6 | 0.55
| Run | Slot (local) | Relay key (+ms) | RF on-air (ms) | TX;→RX; (ms) | Longest gap (ms) | Gaps >20 ms off | Symbol timing (ms) | Tab5 key (+ms) | Tab5 on-air (ms) | Result
| 1 | 10:54:45 | +292 | 12628 | 12681 | 185 | 4 | -13..+16 | | | ok
| 1 | 10:55:00 | +289 | 12631 | 12668 | 200 | 13 | -11..+34 | | | ok
| 1 | 10:55:30 | +287 | 12650 | 12675 | 175 | 0 | -10..+11 | | | ok
| 1 | 10:56:00 | +292 | 12634 | 12667 | 201 | 2 | -14..+28 | | | ok
| 1 | 10:56:30 | +289 | 12630 | 12670 | 192 | 7 | -13..+20 | | | ok
| 1 | 10:57:00 | +288 | 12634 | 12673 | 205 | 4 | -11..+41 | | | ok
| 1 | 10:57:30 | +286 | 12656 | 12693 | 236 | 6 | -10..+69 | | | ok
| 1 | 10:58:30 | +293 | 12624 | 12660 | 184 | 4 | -17..+10 | | | ok
| 2 | 16:42:00 | +522 | 12641 | 12682 | 201 | 9 | -10..+35 | | | ok
| 2 | 16:42:30 | +525 | 13643 | 13680 | 1505 | 11 | -13..+1342 | | | STALL
| 2 | 16:43:00 | +638 | 12628 | 12665 | 199 | 4 | -12..+32 | | | ok
| 2 | 16:43:30 | +579 | 12637 | 12673 | 222 | 11 | -8..+57 | | | ok
| 2 | 16:44:00 | +637 | 12634 | 12669 | 210 | 6 | -9..+42 | | | ok
| 2 | 16:44:30 | +525 | 12630 | 12667 | 201 | 6 | -12..+29 | | | ok
| 2 | 16:45:00 | +612 | 12627 | 12664 | 255 | 4 | -13..+84 | | | ok
| 2 | 16:45:30 | +595 | 12632 | 12670 | 184 | 5 | -12..+13 | | | ok
| 2 | 16:46:00 | +944 | 12630 | 12670 | 193 | 4 | -11..+27 | | | ok
| 2 | 16:46:30 | +518 | 12649 | 12686 | 255 | 12 | -11..+86 | | | ok
| 3 | 17:53:45 | +1647 | 12620 | 12655 | 196 | 4 | -28..+13 | | | ok
| 3 | 17:54:15 | +263 | 12630 | 12681 | 1316 | 17 | -11..+1145 | | | STALL
| 3 | 17:54:45 | +263 | 12638 | 12671 | 244 | 3 | -11..+82 | | | ok
| 3 | 17:55:15 | +271 | 12622 | 12658 | 183 | 1 | -17..+6 | | | ok
| 3 | 17:55:45 | +265 | 12631 | 12664 | 209 | 4 | -13..+56 | | | ok
| 3 | 17:56:15 | +276 | 12625 | 12679 | 197 | 3 | -14..+24 | | | ok
| 3 | 17:56:45 | +262 | 12631 | 12669 | 253 | 2 | -12..+91 | | | ok
| 3 | 17:57:15 | +262 | 12631 | 12673 | 205 | 7 | -9..+75 | | | ok
| 3 | 17:57:45 | +299 | 12621 | 12666 | 204 | 4 | -19..+30 | | | ok
| 3 | 17:58:15 | +268 | 12633 | 12672 | 194 | 3 | -11..+25 | | | ok
| 4 | 18:45:30 | +171 | 12640 | 12682 | 160 | 0 | +0..+1 | +24 | 12725 | ok
| 4 | 18:46:00 | +180 | 12641 | 12689 | 161 | 0 | +1..+2 | +24 | 12740 | ok
| 4 | 18:46:30 | +177 | 12641 | 12678 | 160 | 0 | +0..+1 | +25 | 12728 | ok
| 4 | 18:47:00 | +194 | 12640 | 12685 | 161 | 0 | +0..+1 | +78 | 12690 | ok
| 4 | 18:47:30 | +215 | 12640 | 12677 | 160 | 0 | +0..+1 | +87 | 12704 | ok
| 4 | 18:48:00 | +335 | 12641 | 12687 | 160 | 0 | +0..+1 | +217 | 12704 | ok
| 4 | 18:48:30 | +233 | 12641 | 12691 | 160 | 0 | +0..+1 | +121 | 12688 | ok
| 4 | 18:49:00 | +204 | 12641 | 12681 | 160 | 0 | +0..+1 | +86 | 12694 | ok
| 4 | 18:49:30 | +229 | 12640 | 12682 | 160 | 0 | +0..+1 | +92 | 12717 | ok
| 4 | 18:50:00 | +148 | 12641 | 12679 | 161 | 0 | +0..+1 | +24 | 12702 | ok

!small Run 4 Tab5 summary: key-down +24 to +217 ms (median +82), on-air 12,688-12,740 ms (median 12,704). The Tab5’s on-air figure runs from key-down until RX; has been sent, so it includes the post-burst power/SWR query and, for relay-timed bursts, waiting for TX_DONE; it is not a measure of the RF. The same data is in the workbook QMX-NAS-TX-Timing-2026-10-14.xlsx.

# 11. Verification and open items

|~ 2.3 | 4.7
| Area | Status
| Synology relay (DS416j, DSM 7.4.1, QMX+) | Tested on the hardware: self-test, network test, I/Q ~47,700 pairs/s on the Tab5, CAT, Radio menus, port 3, discovery (including with the NAS’s VPN client connected, 2026-10-31), QMX power-cycle recovery
| Tab5 {NAS} | {TAB5_STATUS}
| Update kit | Builds {NAS} from a clean upstream {BASE} without a 3-way merge (cloud test, and on the Mac against GitHub with the same resulting tree). Downloads only the release and retries a dropped connection; runs from inside QMX-Panadapter-NAS
| CAT log, PS0 guard, I/Q pause | Running on the NAS during the timing runs
| Relay-timed transmit | Bench-tested against the fake radio (complete, abort, disconnect mid-burst), then 10 of 10 FT8 bursts on the hardware
| Raspberry Pi relay | Written; not yet run on a Pi
| Mac TCI bridge | Bench-tested against the relay’s fake radio (receive audio pitch, FT8 GFSK tones at 160 ms ± 1 ms, Tab5 network test passing at the same time); not yet used with WS on the air
| Wired Ethernet (W5500 PoE base) | Full ESP-IDF build succeeds; the base was detected on a Tab5 (eth.present); not yet used with a cable
| FT4 relay-timed bursts | Supported by the same path; not yet measured on the air
| RTTY over the NAS | New in upstream v2.0.0. Receive uses the same I/Q as everything else; transmit tones are sent by the Tab5 over the network (not relay-timed), so Wi-Fi timing applies. Not yet tried over the NAS
| Band menu over the NAS | Seen once with an empty band list (bands []) after a start-up over the NAS; a reconnect re-reads it. Open: the relay’s CAT log of the band scan has not been examined yet
| Direct-USB baseline | Optional comparison run (tx_compare.py --usb) not yet made

{{PAGEBREAK}}

# 12. Sources (references)

!small "Verified" means it was read or executed during this work; "background knowledge" means it was relied on but not re-checked here.

{{SOURCES}}

{{PAGEBREAK}}

{{LISTINGS}}

{{PAGEBREAK}}

@appendix Appendix: Initial Setup of the QMX/QMX+ for use with the Tab5-Panadapter

**1. Check the firmware version.** It’s on the QMX screen at power-on, or on the Tab5 status page if you have no front panel.
- v1.03.002 to v1.04.010 works.
- v1.04 versions also give you AM mode and the Antenna Tune button.
- v1.04.011 is not recommended yet. Steffen’s docs report no transmit output when keyed over CAT from the Tab5, and the QMX’s own Tune SWR and Hardware Test screens freezing. Go back to v1.04.010 if you’re on it.

**2. Check these settings on the radio** (or through the Tab5’s Radio menus):
- **System config → IQ Mode: enabled.** The Tab5 switches it on at each connection, and this keeps it on. If it’s missing, signals look shifted or mirrored and slide across the whole spectrum when you tune.
- **System config → GPS & Ser. ports → USB serial ports = 3.**
-- Port 1 carries CAT for the Tab5.
-- Port 2 is for the Tab5’s Radio menus (the QMX menu terminal on the Tab5 screen).
-- Port 3 is for PC software through the NAS relay (TCP 7356).
- **Band config: enable every band you want to use.** The Tab5 builds its band list from this table. A band the radio doesn’t have enabled is ignored when the Tab5 asks for it. That’s the 60 m problem you saw: the QMX stayed put, and the Tab5 now tells you so.

**3. Connect and power up in order.**
- With the QMX+ on the Synology, the relay picks the radio up again after it restarts, so you don’t need to do anything there.
- If the QMX is plugged into the Tab5 directly: start the Tab5 first and wait for the spectrum and Wi-Fi to come up, then switch the QMX on. Steffen warns that turning the radio on while the Tab5 is still starting up can leave it short of memory.

**4. Check it from the Tab5.**
- The top bar shows Band, Mode and BW, and the spectrum is live.
- Pick a few bands, including 60 m, and confirm the radio follows.
- If the Tab5 uses the NAS, check the drawer’s Radio source shows the NAS.

**5. Optional: calibrate power for WSPR.** If you use WSPR with Declared power, run Calibrate Power on a dummy load for each band you use.

If you used the Tab5’s Radio menus to change any of these, close the menu session afterwards. The Tab5 then turns IQ mode back on and returns the radio to the frequency and mode you were on.

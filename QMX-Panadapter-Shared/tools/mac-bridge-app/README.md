# QMX Bridge for macOS

A native Mac app (Swift/SwiftUI) that replaces `tools/mac-serial-bridge` (Python). It
does everything the Python bridge did, in one window:

| Tab | What it does |
|---|---|
| **Relay** | **Discover** sends `QMXR?` on UDP 7355 and lists the relays that answer. **Probe** runs read-only checks: `ID;` `FA;` `MD;` on port 3, plus the I/Q copy's hello on TCP 7357. |
| **Serial Port** | Makes QMX serial port 3 (relay TCP 7356) a serial port on this Mac. It connects only while a program talks to the port and releases the port after 120 s idle. |
| **TCI** | A TCI server at `ws://127.0.0.1:40001` for WS, WSJT-X 3 and JTDX. Receive audio is demodulated from the I/Q copy; transmit sends one tone at a time as `TA<Hz>;`. |
| **Driver** | Installs or removes the virtual USB serial port driver. |
| **Settings** | Fixed or fallback NAS address, ports, idle time, TCI address, verbose log. |

The serial port and the TCI server both use the radio's port 3, so only one runs at a time.

## Two kinds of serial port

1. **Virtual USB serial port (driver).** `QMXSerialDriver.dext` is a DriverKit
   `IOUserSerial` driver. With it, the QMX appears as **`/dev/cu.QMX-NAS`**, exactly like a
   USB serial adapter, so it shows up in every program's port list (WSJT-X, fldigi, CHIRP,
   loggers, `screen`). The driver has no hardware: what programs write goes to the app, which
   forwards it to the relay, and the radio's replies come back the same way.
2. **Pseudo-terminal link (no driver).** This works the same way as the Python bridge: a pty
   linked at `~/cu.QMX-NAS`. It needs no driver or special signing, but programs that only
   list `/dev/cu.*` won't show it, so you type the path instead. **QMX Bridge Lite.app** is the
   build that has only this mode.

## Building

You need Xcode with the DriverKit SDK; Xcode 15 or later includes it.
[XcodeGen](https://github.com/yonaskolb/XcodeGen) is downloaded automatically if it is
missing.

```bash
cd ~/src/QMX-Panadapter-NAS/tools/mac-bridge-app
./build.sh                    # both apps, signed to run locally
./build.sh --lite             # only QMX Bridge Lite.app
./build.sh --team ABCDE12345  # sign with your Apple developer team
./build.sh --install          # also copy to /Applications
```

The apps go to `build/out/`. The log goes to `build/build.log` and, if `~/Claude` exists,
also to `~/Claude/mac-bridge-build.log`.

To work in Xcode instead, run `xcodegen` in this folder and open `QMXBridge.xcodeproj`.

## Running the driver: signing and approval

macOS loads a driver extension only when it is signed with the DriverKit entitlements the
driver uses:

- `com.apple.developer.driverkit`
- `com.apple.developer.driverkit.family.serial`
- `com.apple.developer.driverkit.allow-third-party-userclients`

The app needs two more:

- `com.apple.developer.system-extension.install`
- `com.apple.developer.driverkit.userclient-access`

Apple grants the DriverKit ones per developer team, on request. Until Apple grants them, run
the driver in **development mode**:

1. Restart into Recovery: hold the power button on Apple silicon, or Cmd-R on Intel. Open
   Terminal there and run `csrutil disable`, then restart.
2. In Terminal, run `systemextensionsctl developer on`.
3. Build with `./build.sh --install`, open **/Applications/QMX Bridge.app**, go to
   **Driver**, then click **Install / Update**.
4. Approve the extension. On macOS 15 or later: System Settings → General → Login Items &
   Extensions → Driver Extensions. On older macOS: Privacy & Security → Allow.
5. Check the driver is loaded: `systemextensionsctl list` shows
   `com.qmx.panadapter.bridge.serialdriver [activated enabled]`. Then start **Serial Port**,
   and `ls /dev/cu.*` shows `cu.QMX-NAS`.

If macOS still rejects an ad-hoc-signed driver ("invalid signature" or "missing
entitlement" in the Driver tab or in Console), also run
`sudo nvram boot-args="amfi_get_out_of_my_way=0x1"` and restart. To undo it, run
`sudo nvram -d boot-args`. Turn SIP back on with `csrutil enable` from Recovery when you are
done.

### Asking Apple for the entitlements

At developer.apple.com → Account → **Request DriverKit entitlements**:

> **Driver:** QMX Bridge virtual serial port (`com.qmx.panadapter.bridge.serialdriver`), an
> `IOUserSerial` driver matching `IOUserResources`.
>
> **Purpose:** Amateur radio. A QRP Labs QMX transceiver is plugged into a NAS on the home
> network. The companion app connects to the NAS over TCP and presents the radio's CAT
> serial port on the Mac as a normal serial device, so that existing ham-radio software
> (WSJT-X, fldigi, Hamlib, loggers) can use it unchanged.
>
> **Entitlements:**
> - `com.apple.developer.driverkit`
> - `com.apple.developer.driverkit.family.serial`
> - `com.apple.developer.driverkit.allow-third-party-userclients` (for the dext)
> - `com.apple.developer.driverkit.userclient-access` (for the app, `com.qmx.panadapter.bridge`)
> - `com.apple.developer.system-extension.install` (for the app)

Once Apple grants them, build with `./build.sh --team <your team ID> --install`. SIP can stay
on.

## Using it

- **Serial Port:** in WSJT-X, Rig is QRP Labs QMX (or Kenwood TS-480), and Serial Port is
  `/dev/cu.QMX-NAS` (driver) or `~/cu.QMX-NAS` (pty). Any baud rate works.
- **TCI:** in WS or WSJT-X, Settings → Radio → Rig is **TCI Client RX1** and Network Server is
  `127.0.0.1:40001`. Audio comes over TCI.
- Allow **Local Network** access when macOS asks, or later in System Settings → Privacy &
  Security → Local Network → QMX Bridge.

## How the driver works

| Piece | Role |
|---|---|
| `QMXSerialDriver` (`IOUserSerial`) | Implements the serial family's hardware calls with no hardware. The kernel shares two rings with it, through the `SerialPortInterface` indices. The **tx ring** holds what programs wrote: on `TxDataAvailable` the driver signals the app, the app pulls the bytes (`kQMXMethodRead`), and the driver advances `txCI` and calls `TxFreeSpaceAvailable`. The **rx ring** carries the radio's bytes: the app pushes them (`kQMXMethodWrite`), the driver copies them in, advances `rxPI` and calls `RxDataAvailable`. CTS, DSR and DCD always read as on. |
| `QMXBridgeControl` and `QMXBridgeUserClient` | A separate service the app opens, user client type `'QMX'`. It carries the read and write methods, a status method, and an async notification for "data written", "port opened", "port closed" and DTR/RTS changes. See `Shared/QMXBridgeShared.h`. |
| Ring index mode | Apple doesn't document whether the ring indices run free or wrap at the ring size. The driver assumes free-running and switches to it by itself when it sees an index larger than the ring. If replies stop after about 16 KB of traffic, try **Wrapped** in the Driver tab. |

Driver log: `log stream --predicate 'eventMessage CONTAINS "QMXSerialDriver" OR eventMessage CONTAINS "QMXBridge"'`.

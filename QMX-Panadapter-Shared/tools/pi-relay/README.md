# QMX relay on a Raspberry Pi 4 / 5

Runs the same relay as the Synology NAS (`tools/nas-relay/qmx_nas_relay.py`,
unchanged) on a Raspberry Pi, as a systemd service:

```
QMX ──USB──▶ Raspberry Pi (qmx-relay.service)
                │  TCP 7355  QMXR/1 → Tab5 QMX-Panadapter (Radio source: NAS / Find NAS)
                │  TCP 7356  QMX serial port 3 → PC software, Mac serial bridge
                └  UDP 7355  answers QMXR? searches (Find NAS, mac-serial-bridge)
```

No separate Pi version of the relay is needed: it talks to the QMX through
Linux usbfs, which the Pi has. Its USB structures and ioctl numbers were
checked against the 64-bit ARM (aarch64) kernel headers, and it was tested
on the hardware on a 32-bit ARM NAS. On the Pi it detaches the kernel's
serial and audio drivers from the QMX when it opens it, as it does on any
Linux.

## Install

On the Pi (Raspberry Pi OS Bookworm, 64-bit recommended), with the current
NAS build copied over (`~/src/QMX-Panadapter-NAS`, which has the relay with
Find NAS; the installer warns if the relay next to it is older), e.g.
`rsync -a ~/src/QMX-Panadapter-NAS/tools/{nas-relay,pi-relay} pi@qmxpi.local:qmx/tools/`:

```
cd tools/pi-relay
sudo bash install-pi.sh            # install and start now
sudo bash install-pi.sh --no-start # install; start 60 s after the next boot
```

Then on the Tab5: **Radio source → Find NAS** finds the Pi (or type its
address). The Mac serial bridge finds it the same way.

Set **USB serial ports = 3** on the radio for PC software on TCP 7356, and 2
or 3 for the Tab5's Radio menus, exactly as with the NAS.

## How it starts and restarts

| What | How |
|---|---|
| After a reboot | `qmx-relay.timer` starts the relay **60 s after boot** (`OnBootSec=60s`). The service itself is not started at boot, only by the timer. |
| If it fails | `Restart=on-failure`, 10 s apart, **up to 3 restarts** (`StartLimitBurst=4` = first start + 3 restarts). |
| After 3 restarts | A 4th failure is final: the service stays stopped until the next reboot or `sudo qmx-relay-ctl restart`, and `qmx-relay-gaveup.service` writes **GAVE UP** in the log. |
| Stopped by hand | `sudo qmx-relay-ctl stop` is not counted as a failure and is not restarted. |

The relay itself keeps running while the QMX is off or unplugged (the Tab5
sees "radio offline" and retries); only a crash of the relay counts as a
failure.

## The log

`/var/log/qmx-relay/qmx-relay.log` holds both the service's events (lines
marked `SERVICE`) and the relay's own output (self-test, connections,
warnings). Rotated weekly, 8 kept.

```
2026-10-08 07:00:03 SERVICE ---- system booted (uptime 9 s, qmxpi, kernel 6.6.51+rpt-rpi-2712).
2026-10-08 07:00:03 SERVICE relay will be started by qmx-relay.timer 60 s after boot.
2026-10-08 07:01:00 SERVICE starting the relay: 60 s after boot, by qmx-relay.timer (uptime 60 s).
2026-10-08 07:01:00 SERVICE command: python3 qmx_nas_relay.py --selftest   backend: usbfs
2026-10-08 07:01:01,412 INFO SELFTEST ...
2026-10-08 07:01:04,020 INFO listening on 0.0.0.0:7355 (QMXR/1 for the Tab5)
...
2026-10-08 09:12:40 SERVICE relay FAILED: it exited with status 1 (result: exit-code). Restart 1 of 3 in 10 s.
2026-10-08 09:12:50 SERVICE starting the relay: restart 1 of 3 (uptime 7967 s).
...
2026-10-08 09:13:31 SERVICE relay FAILED: it exited with status 1 (result: exit-code). All 3 restarts used - not restarting.
2026-10-08 09:13:41 SERVICE GAVE UP: the relay failed and its 3 restarts are used up. It stays stopped
2026-10-08 09:13:41 SERVICE until the next reboot or 'sudo qmx-relay-ctl restart'. See the lines above for why.
```

## Everyday commands

```
qmx-relay-ctl status          # service, timer, restarts used, ports, QMX on USB, last log lines
qmx-relay-ctl log 100         # last 100 log lines
qmx-relay-ctl follow          # watch the log
qmx-relay-ctl test            # network test (read-only, never transmits; QMX plugged in)
sudo qmx-relay-ctl probe      # USB devices and the QMX's interfaces
sudo qmx-relay-ctl restart    # start again now, with a fresh 3 restarts
sudo qmx-relay-ctl stop       # stop (starts again 60 s after the next boot)
```

Settings: `/etc/default/qmx-relay` (`RELAY_ARGS`, `QMX_BACKEND`), then
`sudo qmx-relay-ctl restart`. Remove: `sudo bash uninstall-pi.sh`
(`--purge` also removes the log and settings).

## Notes

* The relay runs as root, as on the NAS: opening the QMX through usbfs and
  detaching the kernel drivers needs it. The unit adds `NoNewPrivileges`,
  `ProtectSystem=full`, `ProtectHome` and `PrivateTmp`.
* `70-qmx-relay.rules` tells ModemManager not to probe the QMX's serial ports
  (it would send AT commands to the radio) and PipeWire/PulseAudio not to open
  its audio, and keeps the QMX out of USB autosuspend.
* The QMX needs its own power supply as usual; USB carries only data here.
* Only one program can own the QMX. Don't run the relay on the NAS and the Pi
  with the same radio; with two relays on the network, Find NAS lists both.

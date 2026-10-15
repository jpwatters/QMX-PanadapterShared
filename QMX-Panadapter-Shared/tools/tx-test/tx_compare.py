#!/usr/bin/env python3
"""
tx_compare.py - compare transmit bursts as the Tab5 timed them with the same
bursts as the NAS relay handed them to the QMX.

    python3 tools/tx-test/tx_compare.py TAB5_CONSOLE.log RELAY_TXLOG.log [...]
    python3 tools/tx-test/tx_compare.py --usb TAB5_USB.log      (Tab5 only, e.g. a direct-USB baseline)

Inputs
  TAB5_CONSOLE.log  from tools/tx-test/capture-tab5-console.sh (each line
                    stamped with the Mac's clock)
  RELAY_TXLOG.log   txlog/txlog-<date>.log from the relay folder on the NAS

The rule this script is built on: every number it compares is an interval
whose two ends were read from ONE clock.
  Tab5 side  "key down at +N ms into the slot"  and "(N ms on-air)" - both
             measured by the firmware on the Tab5's own clock.
  Relay side "RF on-air", tone gaps and symbol timing - differences of the
             NAS's monotonic clock, around the actual USB writes to the QMX.
The Mac's and the NAS's wall clocks are used only to say which 15 s (FT8) or
7.5 s (FT4) slot a burst was in, so the same burst can be found in both logs.
They are never subtracted from each other. Two clocks only need to agree to
within a few seconds for that, and a burst that cannot be placed is listed as
unpaired rather than guessed.
"""
from __future__ import annotations

import argparse
import calendar
import re
import statistics
import sys
import time

ANSI = re.compile(r"\x1b\[[0-9;]*m")
STAMP = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}) \| (.*)$")
KEY = re.compile(r"key down at \+(-?\d+) ms into the slot")
START = re.compile(r"TX burst starting \((FT4|FT8)\)")
DONE = re.compile(r"TX burst (\[SIM\] )?(complete|ABORTED): '(.*)' \((\d+) ms on-air\)")
R_HEAD = re.compile(r"^# burst (\d+)\s+slot (\S+)\s+\((.*)\)")
R_KEY = re.compile(r"^RELAY key down at \+(-?\d+) ms into the slot")
R_SUM = re.compile(r"^RELAY TX burst: (\d+) tones")

FT8_ON_AIR_MS = 79 * 160          # 12640: the burst length if every symbol is on time


def slot_key(t: float, period: float) -> int:
    """Index of the slot that started nearest to t (seconds since the epoch)."""
    return int(round(t / period))


ESPLINE = re.compile(r"^[IWEDV] \((\d+)\) [^:]+: (.*)$")
UTC_ANCHOR = re.compile(r"(?:SNTP sync: UTC|online; UTC) (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)")


def parse_tab5(path: str):
    """Two input forms:
      - Mac capture: "<Mac date time.ms> | <console line>"  (capture-tab5-console.sh)
      - the Tab5's own log over WiFi (web page log download, /api/log):
        "I (<ms since boot>) tag: text". Its slot is placed from the latest
        "SNTP sync: UTC ..." / "online; UTC ..." line on the Tab5 itself.
    Either way the wall time only picks the slot; the compared numbers are
    the firmware's own "key down at +N ms" and "(N ms on-air)"."""
    bursts, cur, proto = [], None, "FT8"
    anchor = None                      # (boot_ms, utc_epoch) from the Tab5's own log
    last_boot_ms = -1
    with open(path, "rb") as f:
        for raw in f:
            line = ANSI.sub("", raw.decode(errors="replace").rstrip("\r\n"))
            wall = None
            m = STAMP.match(line)
            if m:
                wall = time.mktime(time.strptime(m.group(1)[:19], "%Y-%m-%d %H:%M:%S")) + int(m.group(1)[20:]) / 1000
                line = m.group(2)
            e = ESPLINE.match(line)
            if e:
                boot_ms = int(e.group(1))
                if boot_ms < last_boot_ms:          # the Tab5 rebooted: old anchor is void
                    anchor, cur = None, None
                last_boot_ms = boot_ms
                if (u := UTC_ANCHOR.search(line)):
                    anchor = (boot_ms, calendar.timegm(time.strptime(u.group(1), "%Y-%m-%d %H:%M:%S")))
                if wall is None and anchor:
                    wall = anchor[1] + (boot_ms - anchor[0]) / 1000
            text = line
            if (s := START.search(text)):
                proto = s.group(1)
            elif (k := KEY.search(text)):
                cur = {"proto": proto, "key_ms": int(k.group(1)), "wall": wall}
            elif (d := DONE.search(text)) and cur:
                cur.update(sim=bool(d.group(1)), status=d.group(2), text=d.group(3), on_air=int(d.group(4)))
                period = 7.5 if cur["proto"] == "FT4" else 15.0
                cur["period"] = period
                if cur["wall"] is None:
                    cur["slot"] = None                 # no clock anchor: cannot be placed
                else:
                    # the slot started key_ms before the key-down line was logged
                    cur["slot"] = slot_key(cur["wall"] - cur["key_ms"] / 1000, period)
                bursts.append(cur)
                cur = None
    return bursts


def parse_relay(paths):
    bursts, cur = [], None
    for path in paths:
        with open(path) as f:
            for line in f:
                line = line.rstrip("\n")
                if (h := R_HEAD.match(line)):
                    utc = h.group(2).rstrip("Z")
                    frac = 0.5 if utc.endswith(".5") else 0.0
                    t = calendar.timegm(time.strptime(utc[:19], "%Y-%m-%dT%H:%M:%S")) + frac
                    cur = {"slot_t": t, "status": h.group(3)}
                    bursts.append(cur)
                elif cur is not None and (k := R_KEY.match(line)):
                    cur["key_ms"] = int(k.group(1))
                elif cur is not None and (s := R_SUM.match(line)):
                    cur["tones"] = int(s.group(1))
                    for key, pat in (("rf_on_air", r"RF on-air (\d+) ms"), ("tx_rx", r"TX; -> RX; (\d+) ms"),
                                     ("gap_max", r"min/avg/max \d+/[\d.]+/(\d+) ms"),
                                     ("gaps_off", r"off by >20 ms: (\d+)"),
                                     ("late_min", r"vs schedule ([+-]\d+)\.\."), ("late_max", r"\.\.([+-]\d+) ms"),
                                     ("usb_max", r"USB write max ([\d.]+) ms")):
                        m = re.search(pat, line)
                        if m:
                            cur[key] = float(m.group(1))
                    m = re.search(r"I/Q to Tab5 (paused|streamed)", line)
                    cur["iq"] = m.group(1) if m else ""
                    m = re.search(r"tones timed by (\w+)", line)
                    cur["timed"] = m.group(1) if m else "Tab5"
    for b in bursts:
        period = 7.5 if 90 <= b.get("tones", 0) <= 110 else 15.0
        b["period"] = period
        b["slot"] = slot_key(b["slot_t"], period)
    return bursts


def fmt(v, w=6, plus=False):
    if v is None:
        return "-".rjust(w)
    return (("%+d" if plus else "%d") % round(v)).rjust(w)


def stats(name, vals):
    vals = [v for v in vals if v is not None]
    if not vals:
        return "  %-34s -" % name
    med = statistics.median(vals)
    return "  %-34s n=%-3d min %6.0f  median %6.0f  max %6.0f" % (name, len(vals), min(vals), med, max(vals))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("tab5", help="Tab5 console capture")
    ap.add_argument("relay", nargs="*", help="relay txlog file(s); none = Tab5-only summary")
    ap.add_argument("--usb", action="store_true", help="the Tab5 log is a direct-USB run (no relay expected)")
    a = ap.parse_args()

    t5 = [b for b in parse_tab5(a.tab5) if not b.get("sim")]
    rl = parse_relay(a.relay) if a.relay else []
    by_slot = {}
    for r in rl:
        by_slot.setdefault((r["period"], r["slot"]), []).append(r)

    print("Tab5 log : %s  (%d transmit bursts)" % (a.tab5, len(t5)))
    if a.relay:
        print("Relay log: %s  (%d bursts)" % (", ".join(a.relay), len(rl)))
    print()
    hdr = "%-20s %5s | %6s %7s | %6s %7s %7s %6s %6s %13s" % (
        "slot (local time)", "mode", "T5 key", "T5 on", "R key", "R RF on", "R TX-RX", "R gap", ">20ms", "R sym timing")
    print(hdr)
    print("-" * len(hdr))
    paired, used = [], set()
    for b in t5:
        rs = by_slot.get((b["period"], b["slot"]), [])
        r = rs[0] if len(rs) == 1 else None
        if r:
            used.add(id(r))
            paired.append((b, r))
        slot_txt = ("(no UTC in log)" if b["slot"] is None
                    else time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(b["slot"] * b["period"])))
        timing = "-"
        if r and r.get("late_min") is not None:
            timing = "%+d..%+d" % (r["late_min"], r["late_max"])
        if r and r.get("iq"):
            timing += "  IQ " + ("off" if r["iq"] == "paused" else "on")
        if r and r.get("timed") == "relay":
            timing += "  relay-timed"
        flag = "" if r or not a.relay else ("  (no relay burst in this slot)" if not rs else "  (2+ relay bursts in this slot)")
        if b["status"] != "complete":
            flag += "  ABORTED"
        print("%-20s %5s | %6s %7s | %6s %7s %7s %6s %6s %13s%s" % (
            slot_txt, b["proto"], fmt(b["key_ms"], plus=True), fmt(b["on_air"]),
            fmt(r and r.get("key_ms"), plus=True), fmt(r and r.get("rf_on_air")), fmt(r and r.get("tx_rx")),
            fmt(r and r.get("gap_max")), fmt(r and r.get("gaps_off")), timing, flag))
    for r in rl:
        if id(r) not in used:
            print("%-20s %5s | %6s %7s | %6s %7s %7s   relay burst with no Tab5 burst in this slot" % (
                time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(r["slot_t"])), "", "", "",
                fmt(r.get("key_ms"), plus=True), fmt(r.get("rf_on_air")), fmt(r.get("tx_rx"))))

    ft8 = [b for b in t5 if b["proto"] == "FT8" and b["status"] == "complete"]
    print()
    print("Columns: T5 = the Tab5's own numbers, R = the relay's (NAS clock). All in ms.")
    print("  key     key down, ms after the slot started (each on its own clock vs UTC via NTP)")
    print("  T5 on   Tab5 'on-air': key down -> RX; sent, including the post-burst power/SWR")
    print("          query, which waits for the radio's reply (one network round trip on NAS)")
    print("  R RF on what the QMX got: TX; -> key-up tone TA0; (FT8 ideal %d)" % FT8_ON_AIR_MS)
    print("  R gap   longest gap between two tone changes reaching the radio (FT8 ideal 160)")
    print("  >20ms   tone changes more than 20 ms off their 160 ms spacing")
    print("  R sym timing  earliest..latest symbol vs key down + i x 160 ms")
    print()
    print("Summary")
    print(stats("Tab5 key down (+ms into slot)", [b["key_ms"] for b in ft8]))
    print(stats("Tab5 on-air (ms)", [b["on_air"] for b in ft8]))
    pr = [(b, r) for b, r in paired if b["proto"] == "FT8"]
    if pr:
        print(stats("Relay RF on-air (ms)", [r.get("rf_on_air") for _, r in pr]))
        print(stats("Relay TX; -> RX; (ms)", [r.get("tx_rx") for _, r in pr]))
        print(stats("Relay longest tone gap (ms)", [r.get("gap_max") for _, r in pr]))
        print(stats("Relay latest symbol (ms late)", [r.get("late_max") for _, r in pr]))
        print(stats("Relay key down (+ms, NAS clock)", [r.get("key_ms") for _, r in pr]))
        bad = [r for _, r in pr if (r.get("gaps_off") or 0) > 0 or abs((r.get("rf_on_air") or FT8_ON_AIR_MS) - FT8_ON_AIR_MS) > 20]
        print()
        print("%d of %d paired FT8 bursts reached the radio with every tone within 20 ms of schedule"
              " and RF on-air within 20 ms of %d." % (len(pr) - len(bad), len(pr), FT8_ON_AIR_MS))
        groups = {}
        for b, r in pr:
            g = "tones timed by %-5s I/Q %s" % (r.get("timed", "Tab5"), r.get("iq") or "unknown")
            groups.setdefault(g, []).append((b, r))
        if len(groups) > 1 or any("paused" in g or "relay" in g for g in groups):
            print()
            print("By mode (relay flag files tab5-timed-tx and iq-during-tx):")
            for g, items in sorted(groups.items()):
                # A relay-timed burst's Tab5 on-air includes waiting for the
                # relay's report, so only the relay's own gap counts there.
                stalls = sum(1 for b, r in items if (r.get("gap_max") or 0) > 300 or
                             (r.get("timed") != "relay" and b["on_air"] > 12750))
                print("  %-30s %3d bursts  stalls: %d   median latest symbol %+.0f ms" % (
                      g, len(items), stalls, statistics.median([r.get("late_max") or 0 for _, r in items])))
            print("  (stall = a tone gap over 300 ms at the radio, or for Tab5-timed bursts a Tab5")
            print("   on-air time over 12750 ms)")
    elif a.relay:
        print("\nNo burst could be paired - check that both logs cover the same time and that the"
              " Mac and the NAS clocks are set by NTP.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

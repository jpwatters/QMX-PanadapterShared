# Transmit timing test: Tab5 console vs. NAS relay

Checks that a transmit burst sent through the NAS relay reaches the QMX on time.
It compares what the Tab5 *thinks* it sent against what the relay *actually wrote
to the radio's USB port*.

## The rule: one clock per number

Every number compared here is an interval whose two ends come from the same
clock:

| Where | Number | Clock |
|---|---|---|
| Tab5 log | `key down at +N ms into the slot` | Tab5 |
| Tab5 log | `TX burst ... (N ms on-air)` | Tab5 |
| Relay txlog | `RF on-air` (TX; → key-up TA0;), tone gaps, symbol timing | NAS (monotonic) |

The Tab5's and NAS's wall clocks are only used to work out **which slot** a
burst was in, so the same burst can be found in both logs. Never subtract a
Tab5 time from a NAS time: they are different clocks, and a stable difference
between them is not a measurement.

## Why both logs are needed

With Tab5 timing (the old way, or with the `tab5-timed-tx` flag file) the Tab5
schedules each tone change on its own timer. If the Wi-Fi or the relay
holds a few tone changes back and then delivers them together, the Tab5 never
notices. Its send call returns as soon as the bytes are in its TCP buffer, so its
`on-air` number stays at its usual value. Only the relay sees when each command
really went to the radio, which is what an on-air signal is made of.

The Tab5's `on-air` figure runs from key down until `RX;` has been sent. That
includes the post-burst power/SWR query, which waits for the radio's reply. Over
the NAS that reply makes one network round trip, so expect the Tab5 figure to be
somewhat longer than over direct USB even when every tone was on time. The
relay's `RF on-air` (key down → key-up tone) is the number that should be 12640
ms for FT8.

## Running it

1. **Relay:** the relay logs every transmit burst by itself, to `txlog/txlog-<date>.log`
   in its folder on the NAS (File Share/qmx-relay/txlog). There is nothing to
   switch on. Turn it off with `--txlog-dir ''`. Nothing is written during a
   burst; the burst is saved once `RX;` has gone out.
2. **Tab5 log:** use the Tab5's own log over Wi-Fi. It holds the same lines as
   the USB console, timed on the same Tab5 clock, and needs no cable. A cable
   matters because opening the USB console port restarts the Tab5, and after a
   restart without a full power-off the touch screen stops responding. So, with
   nothing plugged into the Tab5's USB-C:
   - power the Tab5 fully off and on, so touch works and the log starts fresh
     with its "SNTP sync: UTC ..." line;
   - after the last burst, open `http://qmx.local/api/log` (or the Tab5's IP)
     in the browser. This saves `qmx-log.txt`. Each download empties the
     Tab5's log, so download it once, at the end.

   The USB console capture (`capture-tab5-console.sh`) still works, but only if
   you can live with the restart it causes.
3. Let the Tab5 connect to the NAS, then make **ten consecutive FT8 transmissions**
   into a dummy load, or on air if you're licensed and the frequency is clear.
4. Copy `txlog-<date>.log` from the NAS to the Mac using File Station → Download,
   then compare:
   ```
   python3 tools/tx-test/tx_compare.py ~/Downloads/qmx-log.txt ~/Downloads/txlog-<date>.log
   ```
5. **Optional baseline:** do the same with the QMX plugged straight into the Tab5
   (Radio source: USB), and download the log again. Then compare the Tab5 numbers
   on their own:
   `python3 tools/tx-test/tx_compare.py --usb ~/Downloads/qmx-log-usb.txt`

## Reading the result

For each burst, `tx_compare.py` prints:

- the Tab5's key-down offset and on-air time;
- the relay's key-down offset, RF on-air time, and TX;→RX; time;
- the longest gap between two tone changes;
- how many tone changes were more than 20 ms off their 160 ms spacing;
- the earliest and latest symbol compared with its schedule.

It ends with medians and with how many bursts reached the radio cleanly.

A healthy FT8 burst through the relay looks like this: RF on-air 12640 ± a few
ms, tone gaps about 158–162 ms, none more than 20 ms off, and symbol timing
within a few ms of schedule. A relay or Wi-Fi stall shows up as a long gap
followed by short ones, and as a symbol arriving late. That can happen while the
Tab5's own figure looks normal.

Only transmissions from the Tab5 are logged. Transmissions from PC software on
port 7356 are not.

## Relay-timed bursts

With current Tab5 firmware and relay, the relay times the tones itself (see the
relay README), so the relay's tone gaps and symbol timing show only the NAS's
own timing and should stay within a few ms. The Tab5's `on-air` figure then
also includes waiting for the relay's end-of-burst report, so it is no longer
used to spot stalls for these bursts. The Tab5 log adds one line per burst,
`relay burst complete: 79/79 tones, RF on-air N ms, latest symbol +N ms (NAS
clock)`, which repeats the relay's own figures. To compare with Tab5 timing,
put a file named `tab5-timed-tx` in the relay folder, restart the Tab5's
connection, and run another batch; `tx_compare.py` reports the two modes
separately.

## Does pausing I/Q during transmit help?

The relay pauses I/Q to the Tab5 while it transmits (see the relay README). To
compare, run one batch of bursts with the pause (the default) and one with a
file named `iq-during-tx` in the relay folder. Stalls are rare, about 1 in 18
bursts so far, so use 40–50 bursts per batch. `tx_compare.py` splits the result
by mode and counts the stalls in each: a gap over 300 ms, or a Tab5 on-air time
over 12,750 ms.

#pragma once

/*
 * radio_relay - "Network radio" source for the QMX panadapter.
 *
 * Lets the Tab5 use a QMX that is NOT plugged into its own USB port but into
 * a Synology NAS. tools/nas-relay/qmx_nas_relay.py runs on the NAS (Docker /
 * Container Manager), owns the QMX through libusb, and streams the QMX's I/Q
 * audio and CAT bytes over one TCP connection using the small QMXR/1 framing:
 *
 *     u8 type | u8 flags | u16 len (LE) | payload
 *       1=HELLO 2=IQ 3=CAT 4=PING
 *       5=TERM_OPEN 6=TERM_STATUS 7=TERM_DATA 8=TERM_CLOSE   (relay says "term=1")
 *       9=TX_SCHED 10=TX_ABORT 11=TX_DONE                    (relay says "txsched=1")
 *       12=TX_LOCK                                           (relay says "txlock=1")
 *
 * IQ payloads are interleaved int16 LE I/Q pairs at 48 kHz, already scaled
 * exactly like the USB path's (s24 >> 8), and are pushed into the same audio
 * ring buffer the UAC driver feeds, so DSP/FFT/FT8 see no difference.
 * CAT payloads go to/from the same Kenwood parser cat.c uses for USB CDC.
 *
 * An open TCP session == "radio present": when the NAS loses the QMX it
 * closes the socket and cat.c handles it exactly like a USB unplug.
 *
 * TERM_* carry the QMX's SECOND serial port (the one qmx_term.c uses for the
 * radio's own menus, interface 5 on USB) as a separate byte stream, so a
 * terminal session over the network still never touches the CAT port.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"

#define RADIO_RELAY_DEFAULT_PORT 7355
#define RADIO_RELAY_HOST_LEN     64

/* CAT bytes from the radio. Same signature as the CDC-ACM data callback. */
typedef bool (*radio_relay_cat_rx_cb_t)(const uint8_t *data, size_t len, void *arg);
/* Called (from the relay RX task) when an established link drops on its own. */
typedef void (*radio_relay_gone_cb_t)(void);

/* Set the runtime relay target. Empty/NULL host disables the network source
 * (USB is used). Does not by itself drop an open link - see cat_reconnect(). */
void radio_relay_set_target(const char *host, uint16_t port);
void radio_relay_get_target(char *host, size_t cap, uint16_t *port);
bool radio_relay_enabled(void);

/* Connect + QMXR/1 handshake. Starts the RX task on success. */
esp_err_t radio_relay_connect(radio_relay_cat_rx_cb_t cat_cb,
                              radio_relay_gone_cb_t gone_cb,
                              uint32_t timeout_ms);
bool radio_relay_connected(void);

/* Send CAT bytes to the radio (thread-safe). */
esp_err_t radio_relay_send_cat(const uint8_t *data, size_t len, uint32_t timeout_ms);

/* Tear down the link (does NOT invoke gone_cb). Safe if not connected. */
void radio_relay_close(void);

/* ---- QMX second serial port (terminal) over the relay -------------------
 * true when the connected relay advertised "term=1" in its HELLO. */
bool radio_relay_term_supported(void);

/* Ask the relay to open the QMX's second serial port. data_cb gets the bytes
 * the radio sends on it (relay RX task context - must not block); gone_cb fires
 * if the port or the whole link goes away while open. Blocks up to timeout_ms
 * for the relay's answer. ESP_ERR_NOT_FOUND = the radio has no second port
 * (set to 1 USB serial port); radio_relay_term_error() has the relay's reason. */
esp_err_t radio_relay_term_open(radio_relay_cat_rx_cb_t data_cb,
                                radio_relay_gone_cb_t gone_cb,
                                uint32_t timeout_ms);
esp_err_t radio_relay_term_send(const uint8_t *data, size_t len, uint32_t timeout_ms);
/* Close the second port on the relay. Does NOT invoke gone_cb. */
void radio_relay_term_close(void);
const char *radio_relay_term_error(void);

/* ---- Discovery -------------------------------------------------------------
 * Broadcast "QMXR?" on UDP RADIO_RELAY_DEFAULT_PORT; every relay on this
 * network answers "QMXR! <ip> <tcp port>". Asks 3 times over timeout_ms and
 * collects distinct answers. BLOCKS for timeout_ms - never call it on the
 * LVGL task. Returns how many relays answered (0..max), or -1 if WiFi is down
 * or no socket could be opened. Broadcasts do not cross routers: the relay
 * must be on the Tab5's own network. */
typedef struct {
    char     ip[16];
    uint16_t port;
} radio_relay_found_t;
int radio_relay_discover(radio_relay_found_t *out, int max, uint32_t timeout_ms);

/* ---- Relay-timed transmit bursts (QMXR/1 "txsched=1") ----------------------
 * Over the network every tone change used to cross WiFi on its own, 160 ms
 * apart, and a lost packet or a stalled WiFi link (2026-10-14: 1.1-1.5 s)
 * delivered symbols late. Instead the whole burst goes to the relay in ONE
 * frame at key-down; the relay keys the QMX, sends each tone on the NAS's own
 * timer over its wired link and USB, sends the key-up tone, and reports back.
 * Only relays that announce "txsched=1" in their HELLO accept it. */
typedef struct {
    bool     done;            // a TX_DONE arrived (false: timed out / link lost)
    uint8_t  status;          // 0 complete, 1 aborted, 2 failed
    uint16_t tones_sent;
    uint32_t duration_ms;     // TX; -> key-up, NAS clock
    int32_t  latest_ms;       // latest symbol vs its schedule, NAS clock
} radio_relay_tx_result_t;

bool      radio_relay_txsched_supported(void);
/* Hand the burst to the relay: n tone frequencies (Hz), one every symbol_us.
 * The relay keys the radio on receipt. */
esp_err_t radio_relay_tx_schedule(const float *freq_hz, int n, uint32_t symbol_us);
/* Stop a relay-timed burst now (the relay sends the key-up tone). */
esp_err_t radio_relay_tx_abort(void);
/* Wait for the relay's report that the burst (including key-up) is done. */
bool      radio_relay_tx_wait_done(uint32_t timeout_ms, radio_relay_tx_result_t *out);

/* ---- Transmitter lock (QMXR/1 "txlock=1") ---------------------------------
 * The relay lets one device transmit at a time. While the Mac's TCI bridge is
 * connected with a program that can transmit (WS / WSJT-X), the relay drops the
 * Tab5's key-down (TX;, Tune, tones) and refuses its relay-timed bursts. It
 * tells the Tab5 so with a TX_LOCK frame (u8 locked [+ reason]) right after its
 * HELLO and whenever that changes, and every transmit path here refuses with
 * RADIO_RELAY_TX_LOCKED_MSG instead of keying a radio that will not key.
 * true while locked; why (optional) gets the relay's reason text. Always false
 * over USB, or with an older relay that never sends TX_LOCK. */
#define RADIO_RELAY_TX_LOCKED_MSG "TX locked: Another Device has the transmitter"
bool radio_relay_tx_locked(char *why, size_t cap);

/* Diagnostics for /api/relay. */
uint32_t radio_relay_iq_pairs_total(void);
const char *radio_relay_last_error(void);

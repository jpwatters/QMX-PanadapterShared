#include "radio_relay.h"

#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <fcntl.h>

#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "lwip/sockets.h"
#include "lwip/netdb.h"

#include "audio.h"
#include "wifi.h"           // wifi_is_connected(): no socket calls before the stack is up

static const char *TAG = "relay";

#define PROTO_HELLO 1
#define PROTO_IQ    2
#define PROTO_CAT   3
#define PROTO_PING  4
#define PROTO_TERM_OPEN   5   // Tab5 -> relay: open the QMX's second serial port
#define PROTO_TERM_STATUS 6   // relay -> Tab5: u8 ok (1/0) [+ reason text]
#define PROTO_TERM_DATA   7   // both ways: bytes on the second serial port
#define PROTO_TERM_CLOSE  8   // Tab5 -> relay: close it

#define RX_PAYLOAD_MAX   8192     // NAS relay sends <=1920-byte IQ frames; anything larger is skipped
#define RX_IDLE_TIMEOUT_S   3     // relay streams I/Q + 1 s PINGs; 3 s of silence == gone

static char     s_host[RADIO_RELAY_HOST_LEN] = {0};
static uint16_t s_port = RADIO_RELAY_DEFAULT_PORT;
static portMUX_TYPE s_cfg_mux = portMUX_INITIALIZER_UNLOCKED;

static int s_fd = -1;
static SemaphoreHandle_t s_tx_mutex = NULL;
static TaskHandle_t s_rx_task = NULL;
static volatile bool s_connected = false;
static volatile bool s_closing = false;
static radio_relay_cat_rx_cb_t s_cat_cb = NULL;
static radio_relay_gone_cb_t   s_gone_cb = NULL;
static volatile uint32_t s_iq_pairs_total = 0;
static char s_last_err[64] = "not configured";

// Second serial port (terminal) state.
static volatile bool s_term_supported = false;
static radio_relay_cat_rx_cb_t s_term_cb = NULL;
static radio_relay_gone_cb_t   s_term_gone_cb = NULL;
static SemaphoreHandle_t       s_term_sem = NULL;
static volatile int            s_term_result = 0;   // -1 waiting, 0 failed, 1 open
static char                    s_term_err[64] = "";
static int64_t s_last_fail_log_us = 0;

// ---- config ---------------------------------------------------------------

void radio_relay_set_target(const char *host, uint16_t port)
{
    portENTER_CRITICAL(&s_cfg_mux);
    // snprintf, not strncpy: IDF builds with -Werror=stringop-truncation.
    snprintf(s_host, sizeof(s_host), "%s", host ? host : "");
    s_port = port ? port : RADIO_RELAY_DEFAULT_PORT;
    portEXIT_CRITICAL(&s_cfg_mux);
    ESP_LOGI(TAG, "target: %s", s_host[0] ? s_host : "(none - USB)");
}

void radio_relay_get_target(char *host, size_t cap, uint16_t *port)
{
    portENTER_CRITICAL(&s_cfg_mux);
    if (host && cap) snprintf(host, cap, "%s", s_host);
    if (port) *port = s_port;
    portEXIT_CRITICAL(&s_cfg_mux);
}

bool radio_relay_enabled(void) { return s_host[0] != '\0'; }
bool radio_relay_connected(void) { return s_connected; }
uint32_t radio_relay_iq_pairs_total(void) { return s_iq_pairs_total; }
const char *radio_relay_last_error(void) { return s_last_err; }

// ---- socket helpers --------------------------------------------------------

static int recv_exact(int fd, void *buf, size_t n)
{
    uint8_t *p = (uint8_t *)buf;
    size_t got = 0;
    while (got < n) {
        int r = recv(fd, p + got, n - got, 0);
        if (r <= 0) return -1;
        got += (size_t)r;
    }
    return 0;
}

static esp_err_t send_frame(uint8_t type, const uint8_t *payload, size_t len, uint32_t timeout_ms)
{
    if (len > 0xFFFF) return ESP_ERR_INVALID_SIZE;
    /* ⛔ Never from lwIP's own thread ("tiT"): a socket send there waits on the
     * tcpip thread, i.e. on itself, and the whole network stack stops for good
     * (the SNTP callback did exactly this with the QMX time push, 2026-10-04 -
     * see wifi.c sntp_sync_cb). Refuse loudly instead of hanging silently. */
    if (strcmp(pcTaskGetName(NULL), "tiT") == 0) {
        ESP_LOGE(TAG, "send from the tcpip thread refused (would deadlock lwIP)");
        return ESP_ERR_INVALID_STATE;
    }
    if (!s_tx_mutex || xSemaphoreTake(s_tx_mutex, pdMS_TO_TICKS(timeout_ms)) != pdTRUE) {
        return ESP_ERR_TIMEOUT;
    }
    esp_err_t ret = ESP_OK;
    int fd = s_fd;
    if (fd < 0 || s_closing) {
        ret = ESP_ERR_INVALID_STATE;
    } else {
        uint8_t hdr[4] = { type, 0, (uint8_t)(len & 0xFF), (uint8_t)(len >> 8) };
        const uint8_t *parts[2] = { hdr, payload };
        size_t lens[2] = { sizeof(hdr), len };
        for (int i = 0; i < 2 && ret == ESP_OK; i++) {
            size_t off = 0;
            while (off < lens[i]) {
                int n = send(fd, parts[i] + off, lens[i] - off, 0);   // SO_SNDTIMEO bounds each
                if (n <= 0) { ret = (errno == EAGAIN) ? ESP_ERR_TIMEOUT : ESP_FAIL; break; }
                off += (size_t)n;
            }
        }
    }
    xSemaphoreGive(s_tx_mutex);
    return ret;
}

esp_err_t radio_relay_send_cat(const uint8_t *data, size_t len, uint32_t timeout_ms)
{
    if (!s_connected) return ESP_ERR_INVALID_STATE;
    return send_frame(PROTO_CAT, data, len, timeout_ms ? timeout_ms : 200);
}

// ---- RX task ---------------------------------------------------------------

static void rx_task(void *arg)
{
    (void)arg;
    // int16-aligned so IQ payloads can be handed to the audio ring directly.
    static int16_t payload16[RX_PAYLOAD_MAX / 2];
    uint8_t *payload = (uint8_t *)payload16;
    int fd = s_fd;

    while (!s_closing) {
        uint8_t hdr[4];
        if (recv_exact(fd, hdr, sizeof(hdr)) < 0) break;
        uint8_t type = hdr[0];
        size_t len = (size_t)hdr[2] | ((size_t)hdr[3] << 8);

        if (len > RX_PAYLOAD_MAX) {
            // Unknown/oversized frame: skip it in chunks to stay in sync.
            size_t left = len;
            bool ok = true;
            while (left && ok) {
                size_t n = left > RX_PAYLOAD_MAX ? RX_PAYLOAD_MAX : left;
                ok = recv_exact(fd, payload, n) == 0;
                left -= n;
            }
            if (!ok) break;
            continue;
        }
        if (len && recv_exact(fd, payload, len) < 0) break;

        switch (type) {
        case PROTO_IQ: {
            size_t pairs = len / 4;
            if (pairs) {
                audio_push_net_iq(payload16, pairs);
                s_iq_pairs_total += pairs;
            }
            break;
        }
        case PROTO_CAT:
            if (s_cat_cb && len) s_cat_cb(payload, len, NULL);
            break;
        case PROTO_TERM_DATA:
            if (s_term_cb && len) s_term_cb(payload, len, NULL);
            break;
        case PROTO_TERM_STATUS: {
            bool ok = len >= 1 && payload[0] == 1;
            if (len > 1) {
                size_t n = len - 1 < sizeof(s_term_err) - 1 ? len - 1 : sizeof(s_term_err) - 1;
                memcpy(s_term_err, payload + 1, n);
                s_term_err[n] = '\0';
            } else if (ok) {
                s_term_err[0] = '\0';
            }
            if (s_term_result == -1) {
                // The answer to our TERM_OPEN.
                s_term_result = ok ? 1 : 0;
                if (s_term_sem) xSemaphoreGive(s_term_sem);
            } else if (!ok && s_term_cb) {
                // Unsolicited "port gone" while a session is open.
                radio_relay_gone_cb_t g = s_term_gone_cb;
                s_term_cb = NULL;
                s_term_gone_cb = NULL;
                ESP_LOGW(TAG, "relay closed the terminal port: %s", s_term_err);
                if (g) g();
            }
            break;
        }
        default:   // HELLO / PING / unknown: nothing to do
            break;
        }
    }

    bool unexpected = !s_closing;
    s_connected = false;
    if (s_term_result == -1 && s_term_sem) {        // a TERM_OPEN still waiting
        s_term_result = 0;
        snprintf(s_term_err, sizeof(s_term_err), "network link dropped");
        xSemaphoreGive(s_term_sem);
    }
    if (s_term_cb) {                                // an open terminal loses its port too
        radio_relay_gone_cb_t g = s_term_gone_cb;
        s_term_cb = NULL;
        s_term_gone_cb = NULL;
        if (g) g();
    }
    if (unexpected) {
        snprintf(s_last_err, sizeof(s_last_err), "link dropped (errno %d)", errno);
        ESP_LOGW(TAG, "relay link dropped (errno %d)", errno);
    }
    s_rx_task = NULL;
    if (unexpected && s_gone_cb) s_gone_cb();
    vTaskDelete(NULL);
}

// ---- connect / close -------------------------------------------------------

static void note_fail(const char *what, int code)
{
    snprintf(s_last_err, sizeof(s_last_err), "%s (%d)", what, code);
    // link_task retries every ~2 s; don't flood the log.
    int64_t now = esp_timer_get_time();
    if (now - s_last_fail_log_us > 30LL * 1000 * 1000) {
        s_last_fail_log_us = now;
        ESP_LOGW(TAG, "connect to %s:%u failed: %s", s_host, s_port, s_last_err);
    }
}

esp_err_t radio_relay_connect(radio_relay_cat_rx_cb_t cat_cb,
                              radio_relay_gone_cb_t gone_cb,
                              uint32_t timeout_ms)
{
    if (s_connected || s_rx_task) return ESP_ERR_INVALID_STATE;
    if (!s_tx_mutex) {
        s_tx_mutex = xSemaphoreCreateMutex();
        if (!s_tx_mutex) return ESP_ERR_NO_MEM;
    }

    char host[RADIO_RELAY_HOST_LEN];
    uint16_t port;
    radio_relay_get_target(host, sizeof(host), &port);
    if (!host[0]) return ESP_ERR_INVALID_STATE;

    /* ⛔ No lwIP call until WiFi is up. link_task starts inside cat_init(),
     * seconds before wifi_init() has created the tcpip thread, and getaddrinfo()
     * on a stack that does not exist yet asserts in tcpip_send_msg_wait_sem
     * ("Invalid mbox") - a boot loop as soon as a NAS address is saved
     * (hardware-observed 2026-10-04, cat_link at 4.0 s uptime). Not connected
     * yet is an ordinary "try again": link_task retries every ~2 s. */
    if (!wifi_is_connected()) {
        note_fail("waiting for WiFi", 0);
        return ESP_ERR_INVALID_STATE;
    }

    char port_str[8];
    snprintf(port_str, sizeof(port_str), "%u", port);
    struct addrinfo hints = { .ai_family = AF_INET, .ai_socktype = SOCK_STREAM };
    struct addrinfo *res = NULL;
    int gai = getaddrinfo(host, port_str, &hints, &res);
    if (gai != 0 || !res) {
        note_fail("DNS/WiFi not ready", gai);
        if (res) freeaddrinfo(res);
        return ESP_ERR_NOT_FOUND;
    }

    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) {
        freeaddrinfo(res);
        note_fail("no free socket", errno);
        return ESP_ERR_NO_MEM;
    }

    // Non-blocking connect bounded by timeout_ms.
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    int rc = connect(fd, res->ai_addr, res->ai_addrlen);
    freeaddrinfo(res);
    if (rc != 0 && errno != EINPROGRESS) {
        note_fail("connect", errno);
        close(fd);
        return ESP_FAIL;
    }
    if (rc != 0) {
        fd_set wfds;
        FD_ZERO(&wfds);
        FD_SET(fd, &wfds);
        struct timeval tv = { .tv_sec = timeout_ms / 1000, .tv_usec = (timeout_ms % 1000) * 1000 };
        int sel = select(fd + 1, NULL, &wfds, NULL, &tv);
        int soerr = 0;
        socklen_t sl = sizeof(soerr);
        if (sel <= 0 || getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &sl) != 0 || soerr != 0) {
            note_fail(sel <= 0 ? "connect timeout" : "connect refused", soerr);
            close(fd);
            return ESP_ERR_TIMEOUT;
        }
    }
    fcntl(fd, F_SETFL, fl & ~O_NONBLOCK);

    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));
    struct timeval rto = { .tv_sec = RX_IDLE_TIMEOUT_S, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rto, sizeof(rto));
    struct timeval sto = { .tv_sec = 0, .tv_usec = 200 * 1000 };
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sto, sizeof(sto));

    s_fd = fd;
    s_closing = false;

    // Handshake: say hello, expect "QMXR/1 ..." back as the first frame. The
    // NAS relay only answers once it has actually opened the QMX, so a
    // completed handshake means the radio is there.
    static const char hello[] = "QMXR/1 tab5-qmx-panadapter";
    uint8_t hdr[4];
    char resp[96];
    size_t len;
    if (send_frame(PROTO_HELLO, (const uint8_t *)hello, sizeof(hello) - 1, 500) != ESP_OK) {
        note_fail("hello send", errno);
        goto fail;
    }
    if (recv_exact(fd, hdr, sizeof(hdr)) < 0) { note_fail("no hello (QMX not on NAS?)", errno); goto fail; }
    len = (size_t)hdr[2] | ((size_t)hdr[3] << 8);
    if (hdr[0] != PROTO_HELLO || len == 0 || len >= sizeof(resp)) {
        note_fail("not a QMXR/1 relay", hdr[0]);
        goto fail;
    }
    if (recv_exact(fd, resp, len) < 0) { note_fail("hello recv", errno); goto fail; }
    resp[len] = '\0';
    if (strncmp(resp, "QMXR/1", 6) != 0) { note_fail("bad protocol", 0); goto fail; }
    s_term_supported = strstr(resp, "term=1") != NULL;
    if (!strstr(resp, "rate=48000")) {
        ESP_LOGW(TAG, "relay rate is not 48000 Hz (%s) - spectrum scale will be off", resp);
    }

    s_cat_cb = cat_cb;
    s_gone_cb = gone_cb;
    s_connected = true;
    if (xTaskCreatePinnedToCore(rx_task, "relay_rx", 4096, NULL, 5, &s_rx_task, 1) != pdPASS) {
        s_connected = false;
        note_fail("rx task", 0);
        goto fail;
    }
    audio_request_reset();
    snprintf(s_last_err, sizeof(s_last_err), "ok");
    ESP_LOGI(TAG, "connected to %s:%u (%s)", host, port, resp);
    return ESP_OK;

fail:
    s_fd = -1;
    close(fd);
    return ESP_FAIL;
}

void radio_relay_close(void)
{
    s_closing = true;
    int fd = s_fd;
    if (fd >= 0) shutdown(fd, SHUT_RDWR);
    // Let the RX task notice and exit before the fd is released.
    for (int i = 0; i < 100 && s_rx_task != NULL; i++) vTaskDelay(pdMS_TO_TICKS(20));
    if (s_tx_mutex) xSemaphoreTake(s_tx_mutex, pdMS_TO_TICKS(500));
    if (s_fd >= 0) { close(s_fd); s_fd = -1; }
    if (s_tx_mutex) xSemaphoreGive(s_tx_mutex);
    s_connected = false;
    s_cat_cb = NULL;
    s_gone_cb = NULL;
    s_term_cb = NULL;
    s_term_gone_cb = NULL;
    s_term_supported = false;
    ESP_LOGI(TAG, "relay link closed");
}

// ---- second serial port (terminal) ------------------------------------------

bool radio_relay_term_supported(void) { return s_connected && s_term_supported; }
const char *radio_relay_term_error(void) { return s_term_err; }

esp_err_t radio_relay_term_open(radio_relay_cat_rx_cb_t data_cb,
                                radio_relay_gone_cb_t gone_cb,
                                uint32_t timeout_ms)
{
    if (!s_connected) return ESP_ERR_INVALID_STATE;
    if (!s_term_supported) {
        snprintf(s_term_err, sizeof(s_term_err), "NAS relay too old (no terminal support)");
        return ESP_ERR_NOT_SUPPORTED;
    }
    if (!s_term_sem) {
        s_term_sem = xSemaphoreCreateBinary();
        if (!s_term_sem) return ESP_ERR_NO_MEM;
    }
    xSemaphoreTake(s_term_sem, 0);          // clear any stale give
    // Install the data path FIRST: the radio repaints as soon as it is open.
    s_term_cb = data_cb;
    s_term_gone_cb = gone_cb;
    s_term_result = -1;
    esp_err_t e = send_frame(PROTO_TERM_OPEN, NULL, 0, 500);
    if (e == ESP_OK && xSemaphoreTake(s_term_sem, pdMS_TO_TICKS(timeout_ms)) != pdTRUE) {
        snprintf(s_term_err, sizeof(s_term_err), "no answer from the NAS relay");
        e = ESP_ERR_TIMEOUT;
    }
    if (e == ESP_OK && s_term_result != 1) e = ESP_ERR_NOT_FOUND;
    if (e != ESP_OK) {
        s_term_cb = NULL;
        s_term_gone_cb = NULL;
        if (s_term_result == -1) s_term_result = 0;
        ESP_LOGW(TAG, "terminal port over the network not available: %s", s_term_err);
        return e;
    }
    ESP_LOGI(TAG, "QMX second serial port open on the NAS relay");
    return ESP_OK;
}

esp_err_t radio_relay_term_send(const uint8_t *data, size_t len, uint32_t timeout_ms)
{
    if (!s_connected || !s_term_cb) return ESP_ERR_INVALID_STATE;
    return send_frame(PROTO_TERM_DATA, data, len, timeout_ms ? timeout_ms : 300);
}

void radio_relay_term_close(void)
{
    bool was_open = s_term_cb != NULL;
    s_term_cb = NULL;
    s_term_gone_cb = NULL;
    if (was_open && s_connected) send_frame(PROTO_TERM_CLOSE, NULL, 0, 300);
}

// ---- Discovery ---------------------------------------------------------------
// See radio_relay.h. One UDP socket, three broadcasts ~a third of the timeout
// apart (a single datagram on WiFi can be lost), replies collected until the
// timeout. The reply carries the relay's own idea of its address; the packet's
// source address is used if that does not parse.

int radio_relay_discover(radio_relay_found_t *out, int max, uint32_t timeout_ms)
{
    if (!out || max <= 0) return 0;
    if (!wifi_is_connected()) return -1;

    int s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s < 0) return -1;
    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_BROADCAST, &one, sizeof(one));
    struct timeval tv = { .tv_sec = 0, .tv_usec = 100 * 1000 };
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    struct sockaddr_in bc = { 0 };
    bc.sin_family      = AF_INET;
    bc.sin_port        = htons(RADIO_RELAY_DEFAULT_PORT);
    bc.sin_addr.s_addr = htonl(INADDR_BROADCAST);

    int n = 0, sent = 0;
    const int64_t start = esp_timer_get_time();
    const int64_t total = (int64_t)timeout_ms * 1000;
    while (esp_timer_get_time() - start < total) {
        if (sent < 3 && esp_timer_get_time() - start >= sent * total / 3) {
            if (sendto(s, "QMXR?", 5, 0, (struct sockaddr *)&bc, sizeof(bc)) < 0)
                ESP_LOGW(TAG, "discovery: broadcast failed (errno %d)", errno);
            sent++;
        }
        char buf[64];
        struct sockaddr_in from;
        socklen_t fl = sizeof(from);
        int r = recvfrom(s, buf, sizeof(buf) - 1, 0, (struct sockaddr *)&from, &fl);
        if (r <= 0) continue;
        buf[r] = '\0';
        if (strncmp(buf, "QMXR! ", 6) != 0) continue;

        char ip[16] = "";
        unsigned port = RADIO_RELAY_DEFAULT_PORT;
        struct in_addr chk;
        if (sscanf(buf + 6, "%15s %u", ip, &port) < 1 || inet_aton(ip, &chk) == 0)
            inet_ntoa_r(from.sin_addr, ip, sizeof(ip));
        if (port == 0 || port > 65535) port = RADIO_RELAY_DEFAULT_PORT;

        bool dup = false;
        for (int i = 0; i < n; i++)
            if (strcmp(out[i].ip, ip) == 0 && out[i].port == port) dup = true;
        if (!dup && n < max) {
            snprintf(out[n].ip, sizeof(out[n].ip), "%s", ip);
            out[n].port = (uint16_t)port;
            n++;
        }
    }
    close(s);
    ESP_LOGI(TAG, "discovery: %d relay(s) answered", n);
    return n;
}

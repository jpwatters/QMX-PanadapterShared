#pragma once

/*
 * eth_w5500 - wired Ethernet through the M5Stack W5500 PoE base on the Tab5's
 * M5-Bus (on the back of the Tab5).
 *
 * At boot the firmware looks for a W5500 on the M5-Bus. No base fitted: it
 * says so once in the log and nothing else changes - the Tab5 runs on Wi-Fi
 * exactly as before. Base fitted: Ethernet comes up NEXT TO Wi-Fi, not instead
 * of it, and is the preferred route while it has an address (its netif has a
 * higher route priority than the Wi-Fi station). So:
 *   - cable in, DHCP address: everything new (the NAS relay, the web page,
 *     spots, SNTP, OTA) goes over Ethernet;
 *   - cable pulled: traffic falls back to Wi-Fi by itself (connections that
 *     were open on Ethernet drop and reconnect over Wi-Fi - the NAS relay
 *     link reconnects on its own);
 *   - cable back: new connections use Ethernet again.
 * qmx.local is announced on both links.
 *
 * M5-Bus wiring (no soldering - the base plugs into the bus):
 *   W5500   M5-Bus pin   Tab5 GPIO
 *   MOSI        7          G18
 *   MISO        9          G19
 *   SCK        11          G5
 *   CS         10          G52   (also Port B's output: leave Port B unused)
 *   INT        26          G51
 *   RST        22          G48
 * SPI3 is used; SPI2 belongs to the SD card (m5stack_tab5.c).
 */

#include <stdbool.h>

/* Look for the W5500 and, if it is there, start Ethernet. Returns at once;
 * the probe and DHCP run on a task of their own. Safe to call before or after
 * panadapter_wifi_start(). */
void eth_w5500_start(void);

bool        eth_is_present(void);      // a W5500 answered on the M5-Bus
bool        eth_link_up(void);         // cable in and a link partner
bool        eth_is_connected(void);    // link up AND a DHCP address held
const char *eth_get_ip(void);          // "0.0.0.0" when no address
int         eth_get_speed_mbps(void);  // 10 or 100, 0 when no link
bool        eth_full_duplex(void);
const char *eth_get_mac_str(void);     // "aa:bb:cc:dd:ee:ff" - for the DHCP reservation

/* The network as a whole: Ethernet OR Wi-Fi has an address. Use this - not
 * wifi_is_connected() - wherever the question is "can I reach the network". */
bool        net_is_up(void);
/* The address to show / announce: Ethernet's while it has one, else Wi-Fi's. */
const char *net_get_ip(void);

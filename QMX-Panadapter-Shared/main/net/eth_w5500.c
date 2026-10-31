// See eth_w5500.h.

#include "eth_w5500.h"
#include "wifi.h"

#include <stdio.h>
#include <string.h>

#include "driver/gpio.h"
#include "driver/spi_master.h"
#include "esp_eth.h"
#include "esp_eth_mac_spi.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "eth";

#define ETH_SPI_HOST   SPI3_HOST     /* SPI2 is the SD card's */
#define ETH_PIN_MOSI   18
#define ETH_PIN_MISO   19
#define ETH_PIN_SCK    5
#define ETH_PIN_CS     52
#define ETH_PIN_INT    51
#define ETH_PIN_RST    48
#define ETH_SPI_MHZ    20            /* W5500 is rated to 80; 20 is ample (the
                                        NAS I/Q stream is ~1.6 Mbit/s) and kind
                                        to the M5-Bus connector */
/* Above the Wi-Fi station's 100, so Ethernet is the default route while it
 * has an address and Wi-Fi takes over when it loses it. */
#define ETH_ROUTE_PRIO 200

static esp_eth_handle_t s_eth;
static esp_netif_t     *s_netif;
static volatile bool    s_present;
static volatile bool    s_link;
static volatile bool    s_got_ip;
static volatile int     s_speed;
static volatile bool    s_full;
static char             s_ip[16] = "0.0.0.0";
static char             s_mac[18] = "";

static void on_eth_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg; (void)base; (void)data;
    switch (id) {
    case ETHERNET_EVENT_CONNECTED: {
        eth_speed_t sp = ETH_SPEED_10M;
        eth_duplex_t dx = ETH_DUPLEX_HALF;
        esp_eth_ioctl(s_eth, ETH_CMD_G_SPEED, &sp);
        esp_eth_ioctl(s_eth, ETH_CMD_G_DUPLEX_MODE, &dx);
        s_speed = sp == ETH_SPEED_100M ? 100 : 10;
        s_full  = dx == ETH_DUPLEX_FULL;
        s_link  = true;
        ESP_LOGI(TAG, "link up: %d Mbit/s %s duplex", s_speed, s_full ? "full" : "half");
        break;
    }
    case ETHERNET_EVENT_DISCONNECTED:
        s_link = false;
        s_got_ip = false;
        s_speed = 0;
        snprintf(s_ip, sizeof(s_ip), "0.0.0.0");
        ESP_LOGW(TAG, "link down (cable out?) - Wi-Fi carries the traffic until it is back");
        break;
    case ETHERNET_EVENT_START:
        ESP_LOGI(TAG, "started");
        break;
    case ETHERNET_EVENT_STOP:
        s_link = false;
        s_got_ip = false;
        ESP_LOGI(TAG, "stopped");
        break;
    default:
        break;
    }
}

static void on_ip_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg; (void)base;
    if (id == IP_EVENT_ETH_GOT_IP) {
        const ip_event_got_ip_t *e = (const ip_event_got_ip_t *)data;
        snprintf(s_ip, sizeof(s_ip), IPSTR, IP2STR(&e->ip_info.ip));
        s_got_ip = true;
        ESP_LOGI(TAG, "address %s (gateway " IPSTR ") - Ethernet is now the preferred route",
                 s_ip, IP2STR(&e->ip_info.gw));
        /* Same services the Wi-Fi got-IP path starts (all idempotent): the
         * name qmx.local, SNTP, the web server and rigctld. A Tab5 whose Wi-Fi
         * is switched off or never joins still gets all of them. */
        wifi_net_services_start();
    } else if (id == IP_EVENT_ETH_LOST_IP) {
        s_got_ip = false;
        snprintf(s_ip, sizeof(s_ip), "0.0.0.0");
        ESP_LOGW(TAG, "address lost");
    }
}

static void eth_task(void *arg)
{
    (void)arg;

    /* Both may already exist (wifi.c creates them too); either order is fine. */
    esp_err_t e = esp_netif_init();
    if (e != ESP_OK && e != ESP_ERR_INVALID_STATE) {
        ESP_LOGE(TAG, "esp_netif_init: %s - no Ethernet", esp_err_to_name(e));
        vTaskDelete(NULL);
    }
    e = esp_event_loop_create_default();
    if (e != ESP_OK && e != ESP_ERR_INVALID_STATE) {
        ESP_LOGE(TAG, "event loop: %s - no Ethernet", esp_err_to_name(e));
        vTaskDelete(NULL);
    }
    e = gpio_install_isr_service(0);
    if (e != ESP_OK && e != ESP_ERR_INVALID_STATE) {
        ESP_LOGE(TAG, "GPIO ISR service: %s - no Ethernet", esp_err_to_name(e));
        vTaskDelete(NULL);
    }

    spi_bus_config_t bus = {
        .mosi_io_num = ETH_PIN_MOSI,
        .miso_io_num = ETH_PIN_MISO,
        .sclk_io_num = ETH_PIN_SCK,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
    };
    e = spi_bus_initialize(ETH_SPI_HOST, &bus, SPI_DMA_CH_AUTO);
    if (e != ESP_OK) {
        ESP_LOGE(TAG, "SPI3 bus: %s - no Ethernet", esp_err_to_name(e));
        vTaskDelete(NULL);
    }

    spi_device_interface_config_t dev = {
        .mode = 0,
        .clock_speed_hz = ETH_SPI_MHZ * 1000 * 1000,
        .queue_size = 20,
        .spics_io_num = ETH_PIN_CS,
    };
    eth_w5500_config_t wcfg = ETH_W5500_DEFAULT_CONFIG(ETH_SPI_HOST, &dev);
    wcfg.int_gpio_num = ETH_PIN_INT;

    eth_mac_config_t mac_cfg = ETH_MAC_DEFAULT_CONFIG();
    eth_phy_config_t phy_cfg = ETH_PHY_DEFAULT_CONFIG();
    phy_cfg.reset_gpio_num = ETH_PIN_RST;   /* ⛔ the default is GPIO 5 - our SCK */
    phy_cfg.phy_addr = 1;

    esp_eth_mac_t *mac = esp_eth_mac_new_w5500(&wcfg, &mac_cfg);
    esp_eth_phy_t *phy = esp_eth_phy_new_w5500(&phy_cfg);
    if (!mac || !phy) {
        ESP_LOGE(TAG, "W5500 driver could not be created");
        goto absent;
    }
    esp_eth_config_t cfg = ETH_DEFAULT_CONFIG(mac, phy);
    /* The version-register check inside this call is the probe: with no base
     * fitted nothing answers and it fails cleanly. */
    e = esp_eth_driver_install(&cfg, &s_eth);
    if (e != ESP_OK) {
        ESP_LOGI(TAG, "no W5500 PoE base on the M5-Bus (%s) - Wi-Fi only", esp_err_to_name(e));
        goto absent;
    }
    s_present = true;

    /* The W5500 has no MAC address of its own: use the chip's Ethernet MAC,
     * which is unique and different from the Wi-Fi one - so a DHCP
     * reservation for the wired link needs THIS address. */
    uint8_t m[6];
    if (esp_read_mac(m, ESP_MAC_ETH) == ESP_OK) {
        esp_eth_ioctl(s_eth, ETH_CMD_S_MAC_ADDR, m);
        snprintf(s_mac, sizeof(s_mac), "%02x:%02x:%02x:%02x:%02x:%02x",
                 m[0], m[1], m[2], m[3], m[4], m[5]);
    }

    esp_netif_inherent_config_t base = ESP_NETIF_INHERENT_DEFAULT_ETH();
    base.route_prio = ETH_ROUTE_PRIO;
    esp_netif_config_t ncfg = { .base = &base, .stack = ESP_NETIF_NETSTACK_DEFAULT_ETH };
    s_netif = esp_netif_new(&ncfg);
    if (!s_netif) {
        ESP_LOGE(TAG, "netif could not be created");
        vTaskDelete(NULL);
    }
    esp_netif_attach(s_netif, esp_eth_new_netif_glue(s_eth));

    esp_event_handler_register(ETH_EVENT, ESP_EVENT_ANY_ID, on_eth_event, NULL);
    esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP, on_ip_event, NULL);
    esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_LOST_IP, on_ip_event, NULL);

    e = esp_eth_start(s_eth);
    ESP_LOGI(TAG, "W5500 PoE base found on the M5-Bus, MAC %s - %s", s_mac,
             e == ESP_OK ? "waiting for the link and DHCP" : esp_err_to_name(e));
    vTaskDelete(NULL);

absent:
    if (mac) mac->del(mac);
    if (phy) phy->del(phy);
    spi_bus_free(ETH_SPI_HOST);
    vTaskDelete(NULL);
}

void eth_w5500_start(void)
{
    static bool started;
    if (started) return;
    started = true;
    xTaskCreate(eth_task, "eth_probe", 4096, NULL, 5, NULL);
}

bool        eth_is_present(void)     { return s_present; }
bool        eth_link_up(void)        { return s_link; }
bool        eth_is_connected(void)   { return s_link && s_got_ip; }
const char *eth_get_ip(void)         { return s_ip; }
int         eth_get_speed_mbps(void) { return s_link ? s_speed : 0; }
bool        eth_full_duplex(void)    { return s_full; }
const char *eth_get_mac_str(void)    { return s_mac; }

bool net_is_up(void)
{
    return eth_is_connected() || wifi_is_connected();
}

const char *net_get_ip(void)
{
    return eth_is_connected() ? s_ip : wifi_get_ip();
}

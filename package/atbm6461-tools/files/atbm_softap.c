/* atbm_softap <ssid> [channel] [wpa_password]
 * Bring up the ATBM6441 firmware-internal SoftAP via /dev/atbm_ioctl (WEXT/IOT driver;
 * this driver has no mac80211/nl80211, so hostapd cannot be used). Proven sequence:
 *   CLEAR_WIFI_CFG -> WIFI_MODE=AP -> SET_COUNTRY -> WIFI_CHANNEL -> AP_CFG.
 * The WiFi core then beacons AND runs its own gateway+DHCP on 192.168.43.1
 * (associated clients get 192.168.43.200). The host portal must sit on 192.168.43.2.
 * MIPS ioctls _IOW(121,nr): WIFI_MODE 7, AP_CFG 8, CHANNEL 9, SET_COUNTRY 10, CLEAR _IO 36. */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
#include <stdint.h>
#include <sys/ioctl.h>

#define ATBM_WIFI_MODE      0x80017907u
#define ATBM_AP_CFG         0x80047908u
#define ATBM_WIFI_CHANNEL   0x80017909u
#define ATBM_SET_COUNTRY    0x8001790Au
#define ATBM_CLEAR_WIFI_CFG 0x20007924u
#define KEY_MGMT_NONE 0
#define KEY_MGMT_WPA2 4
#define DEVP "/dev/atbm_ioctl"

struct wsm_join {                 /* 108 bytes, matches driver wsm.h */
    uint8_t flags; uint8_t bssid[6]; uint8_t ssidLength; uint8_t ssid[32];
    uint8_t keyMgmt; uint8_t keyLength; uint8_t keyId; uint8_t reserved; uint8_t key[64];
};
struct wsm_ap_cfg_req { uint32_t status; struct wsm_join join; };  /* 112 bytes */

int main(int argc, char **argv)
{
    if (argc < 2) { fprintf(stderr, "usage: %s <ssid> [channel] [wpa_password]\n", argv[0]); return 2; }
    const char *ssid = argv[1];
    int chan = (argc > 2) ? atoi(argv[2]) : 6;
    const char *pass = (argc > 3 && argv[3][0]) ? argv[3] : NULL;
    if (chan < 1 || chan > 14) chan = 6;

    int fd = open(DEVP, O_RDWR);
    if (fd < 0) { fprintf(stderr, "open %s: %s\n", DEVP, strerror(errno)); return 1; }

    printf("CLEAR_WIFI_CFG  rc=%d\n", ioctl(fd, ATBM_CLEAR_WIFI_CFG));
    printf("WIFI_MODE(AP)   rc=%d\n", ioctl(fd, ATBM_WIFI_MODE, 1));
    printf("SET_COUNTRY(2)  rc=%d\n", ioctl(fd, ATBM_SET_COUNTRY, 2));
    printf("WIFI_CHANNEL(%d) rc=%d\n", chan, ioctl(fd, ATBM_WIFI_CHANNEL, chan));

    struct wsm_ap_cfg_req req; memset(&req, 0, sizeof(req));
    size_t sl = strlen(ssid); if (sl > 32) sl = 32;
    req.join.ssidLength = (uint8_t)sl; memcpy(req.join.ssid, ssid, sl);
    if (pass) {
        req.join.keyMgmt = KEY_MGMT_WPA2;
        size_t pl = strlen(pass); if (pl > 64) pl = 64;
        req.join.keyLength = (uint8_t)pl; memcpy(req.join.key, pass, pl);
    } else {
        req.join.keyMgmt = KEY_MGMT_NONE;
    }
    int rc = ioctl(fd, ATBM_AP_CFG, &req);
    printf("AP_CFG(ssid=%s chan=%d %s) rc=%d\n", ssid, chan, pass ? "wpa2" : "open", rc);
    close(fd);
    return rc ? 1 : 0;
}

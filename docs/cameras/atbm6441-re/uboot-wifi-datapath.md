# ATBM6441 WiFi data path for U-Boot (recovery WiFi mode) — RE + LIVE proof

**2026-07-27: PROVEN LIVE.** Bringing the AP up the VENDOR plane-A way makes U-Boot
the 802.11 endpoint that receives client data. `atbm apA s2` -> phone joined ->
**51 x WSM 0x0804 client data frames** arrived at the host (QoS-Data, ToDS). The
firmware runs the AP+DHCP+gateway autonomously (client gets 192.168.43.200, host=.2).

## Frame model: softMAC (host builds/parses full 802.11 + LLC/SNAP)
- TX data = WSM id 0x0004 (+28-byte wsm_tx header, then 802.11 MPDU).
- RX data = WSM id 0x0804 / 0x0814 (+16-byte descriptor, 802.11 MPDU @ buf offset 20;
  0x0811 = aggregated multi). Classify: id&0x0400=confirm, 0x0805=event, 0x080x=ind.

## Plane-A OPEN AP bring-up (atbm_softap.c order), all via cycling wsm_send_raw():
  CLEAR_WIFI_CFG 0x2C -> WIFI_MODE 0x0D (wsm_wifi_set_req{u32 status;u8 is_ap=1;u8 ch;u8 country;u8 rsv})
  -> AP_CFG 0x0E (wsm_ap_cfg_req{u32 status; wsm_join{u8 flags;u8 bssid[6];u8 ssidLen;u8 ssid[32];u8 keyMgmt=0 open;...}})
  (optional SET_COUNTRY 0x10, CHANNEL 0x0F). plane-B 0x40 is the ROM standalone AP -> host blind.

Full agent findings (TX/RX byte offsets, queueId/aid, eth driver skeleton) archived in
the session workflow wy9vrd0s9 output.

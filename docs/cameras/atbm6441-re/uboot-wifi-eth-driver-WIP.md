# U-Boot WiFi eth driver over ATBM6441 - WORK IN PROGRESS (shelved 2026-07-27)
Goal: RST-held-<10s at boot -> U-Boot WiFi recovery mode (open AP + NetConsole over
UDP). SHELVED to ship a clean RST+LED bootloader first. This file preserves the driver
and the crucial runtime finding so the work can be resumed. The data-path RE (softMAC,
TX=WSM 0x0004 / RX=WSM 0x0804, plane-A AP sequence) is in uboot-wifi-datapath.md.

## CRITICAL eth-driver finding (2026-07-27): association requires continuous host draining

When a client associates to the ATBM AP in plane-A (softMAC) mode, the firmware pushes
connect events to the T23 host over SDIO via LMACtoUMAC_EventSdio (0xc4228). If the host
does NOT drain the SDIO output ring fast enough, that event channel OVERFLOWS -> the
firmware logs "LMACtoUMAC_EventSdio too many bug 5" and then DEAUTHS the associating STA
("[ap]:rx ASSOC_REQ ... hostapd deauth ... sta_del"). LIVE-captured on COM11.

=> For the U-Boot WiFi eth driver, the host MUST drain continuously while a client is
associating/associated. Proven: a tight `atbm rx` loop (250ms) -> phone associates + HOLDS.
Idle U-Boot (no drain) -> phone auths+assocs then gets kicked.

Implications:
- U-Boot only runs its IP stack (ARP/ICMP replies) DURING a NetLoop (ping/dhcp/netconsole).
  A bare `atbm rx` drain keeps the link up but does NOT answer the phone's ping.
- The natural fix is NetConsole: its receive loop drains continuously (assoc holds) AND
  processes packets (answers). Or: U-Boot initiates `ping 192.168.43.200` (its NetLoop
  drains + does ARP+ICMP round-trip).
- The eth recv() should drain aggressively (multiple frames/call) to stay ahead of events.

State at checkpoint: TX proven (phone received U-Boot's ping over the air); RX drain +
BSSID-learn-from-addr1 implemented; join.bssid=fixed was a regression (reverted to efuse).
Builds: ub_eth3.bin (d72729e8 was eth2 w/ join.bssid; 6d9b4409 = eth3 join.bssid reverted).

## What WORKS (live-proven)
- Plane-A open-AP bring-up (`atbm apA`): CLEAR_WIFI_CFG 0x2C -> WIFI_MODE 0x0D is_ap=1
  -> AP_CFG 0x0E (open) -> host receives client **0x0804 data frames** (51 captured).
- **eth TX**: U-Boot built an 802.11 frame, sent it as WSM 0x0004, the phone RECEIVED
  the ping (verified live). The send path works end-to-end.
- **Association HOLDS** while the host drains continuously (tight `atbm rx` loop).

## NOT yet done / next step
- Full ping ROUND-TRIP in U-Boot: needs the host to drain continuously AND run its IP
  stack, which only happens inside a NetLoop (ping/dhcp) or **NetConsole**. Go straight
  to NetConsole next (`CONFIG_NETCONSOLE=y`; netconsole.c is present) - its receive loop
  drains (assoc holds) and answers packets.
- Gotchas: `join.bssid` MUST be 0 (firmware efuse MAC; forcing a fixed MAC broke assoc);
  do NOT send WSM_CONFIG 0x0002 while the AP is up (tears the AP down - learn BSSID from
  RX addr1 instead); the whole atbm_wdt.c body must stay behind
  `#if !defined(CONFIG_XPL_BUILD)` (SPL .bss is tiny, ~1.6KB headroom).
- Registration was: `device_bind_driver(dm_root(), "eth_atbm_wifi", "atbm_wifi", NULL)`
  in board_late_init (non-DT DM_ETH; MAC via read_rom_hwaddr).

## The eth driver + AP bring-up + TX/RX code (built as ub_eth3)
```c
/* ================= ATBM WiFi pseudo-Ethernet (DM_ETH) ========================
 * softMAC: the host builds/parses 802.11. TX=WSM 0x0004, RX=WSM 0x0804. The AP is
 * raised the vendor plane-A way (CLEAR/WIFI_MODE=AP/AP_CFG) so the HOST is the
 * 802.11 endpoint. Gives U-Boot dhcp/ping/tftpboot/NetConsole over the ATBM WiFi
 * for RST-hold recovery. Firmware runs the AP+DHCP+gateway autonomously at
 * 192.168.43.1 (client=.200); the host sits static at 192.168.43.2. */

/* our fixed L2 address (locally-administered): U-Boot MAC + addr3(SA)/DA */
static const u8 atbm_eth_mac[6] = { 0x02, 0xba, 0xbe, 0x00, 0x64, 0x41 };
/* AP BSSID = real firmware MAC; addr2 in TX. Read from the chip in ap_up(). */
static u8  atbm_bssid[6] = { 0x02, 0xba, 0xbe, 0x00, 0x64, 0x41 };
static u16 atbm_tx11seq = 0;
static int atbm_ap_is_up = 0;
static int atbm_bssid_learned = 0;

/* read the device MAC (BSSID) via WSM_CONFIG 0x0002 -> confirm 0x0402 (mac @ off 8) */
static void atbm_read_bssid(void)
{
	static u8 b[2048]; u16 ctrl, id; u32 nl, alloc; int i, t;
	wsm_send_raw(0x0002, (const u8 *)"", 0);
	for (t = 0; t < 30; t++) {
		for (i = 0; i < 200 && !(hif_r16(HIF_CONTROL) & 0xCFFF); i++) udelay(1000);
		ctrl = hif_r16(HIF_CONTROL);
		nl = ((u32)(ctrl & 0x0FFF) | ((u32)(ctrl & 0xC000) >> 2)) * 2;
		if (!nl || nl > 1600) break;
		alloc = (nl + 2 + 255) & ~255u; if (alloc > sizeof(b)) break;
		if (cmd53_block(0, ((u32)((m3_bufrx & 3) + 1) << 6) | HIF_QUEUE, b, alloc)) break;
		m3_bufrx = (u8)((m3_bufrx + 1) & 3);
		id = (u16)((b[2] | (b[3] << 8)) & 0x0FFF);
		if (id == 0x0402) {
			for (i = 0; i < 6; i++) atbm_bssid[i] = b[8 + i];
			printf("atbm eth: BSSID %02x:%02x:%02x:%02x:%02x:%02x\n",
			       atbm_bssid[0],atbm_bssid[1],atbm_bssid[2],atbm_bssid[3],atbm_bssid[4],atbm_bssid[5]);
			return;
		}
	}
	printf("atbm eth: BSSID read failed (fallback)\n");
}

/* bring up the OPEN AP the vendor plane-A way + read the BSSID */
static void atbm_wifi_ap_up(const char *ssid, int ch)
{
	int n = (int)strlen(ssid), i; static u8 wm[8], ap[112]; u8 z4[4];
	if (n > 32) n = 32; if (n < 1) n = 1;
	z4[0]=z4[1]=z4[2]=z4[3]=0;
	wsm_send_raw(0x002C, z4, 4);  mdelay(15); (void)atbm_rx_drain(0,NULL,8,0);   /* CLEAR */
	for (i=0;i<8;i++) wm[i]=0; wm[4]=1; wm[5]=(u8)ch; wm[6]=2;
	wsm_send_raw(0x000D, wm, 8);  mdelay(15); (void)atbm_rx_drain(0,NULL,8,0);   /* WIFI_MODE=AP */
	for (i=0;i<112;i++) ap[i]=0; ap[11]=(u8)n;
	for (i=0;i<n;i++) ap[12+i]=(u8)ssid[i]; ap[44]=0;                             /* keyMgmt=open */
	/* join.bssid left 0 -> firmware uses its own efuse MAC as BSSID (assoc works) */
	wsm_send_raw(0x000E, ap, 112); mdelay(30); (void)atbm_rx_drain(0,NULL,12,0); /* AP_CFG */
	/* Do NOT send WSM_CONFIG 0x0002 here: it tears the AP down (phone can't
	 * associate). We learn the real BSSID from RX addr1 instead. */
	atbm_ap_is_up = 1;
}

/* TX: 802.3 {DA[6] SA[6] ethtype[2] payload} -> 802.11 FromDS data + wsm_tx (0x0004) */
static int atbm_eth_tx(const u8 *pkt, int len)
{
	static u8 pl[1800]; int p, i; u16 seq;
	if (len < 14) return -1;
	p = 0;
	pl[p++]=1; pl[p++]=0; pl[p++]=0; pl[p++]=0;         /* wsm_tx: packetID */
	pl[p++]=3;                                          /* maxTxRate 11M */
	pl[p++]=0; pl[p++]=0; pl[p++]=0;                    /* queueId(aid0|BE), more, flags */
	pl[p++]=0; pl[p++]=0; pl[p++]=0; pl[p++]=0;         /* reserved */
	pl[p++]=0; pl[p++]=0; pl[p++]=0; pl[p++]=0;         /* expireTime */
	pl[p++]=0x00; pl[p++]=0x02; pl[p++]=0x00; pl[p++]=0x00; /* htTxParameters=LINUX_HOST */
	pl[p++]=0x08; pl[p++]=0x02;                         /* fc: data, FromDS */
	pl[p++]=0x00; pl[p++]=0x00;                         /* duration */
	for (i=0;i<6;i++) pl[p++]=pkt[i];                   /* addr1 = RA = DA */
	for (i=0;i<6;i++) pl[p++]=atbm_bssid[i];            /* addr2 = BSSID */
	for (i=0;i<6;i++) pl[p++]=pkt[6+i];                 /* addr3 = SA */
	seq = (u16)((atbm_tx11seq++ & 0xFFF) << 4);
	pl[p++]=(u8)(seq & 0xff); pl[p++]=(u8)((seq>>8)&0xff);
	pl[p++]=0xAA; pl[p++]=0xAA; pl[p++]=0x03; pl[p++]=0x00; pl[p++]=0x00; pl[p++]=0x00; /* SNAP */
	pl[p++]=pkt[12]; pl[p++]=pkt[13];                   /* ethertype */
	for (i=14;i<len;i++) pl[p++]=pkt[i];
	wsm_send_raw(0x0004, pl, p);
	(void)atbm_rx_drain(0, NULL, 2, 0);                 /* pump credit recovery */
	return 0;
}

/* RX: drain one 0x0804 data frame -> reconstruct 802.3 into out[]. Return len or 0. */
static int atbm_eth_rx(u8 *out, int outmax)
{
	static u8 b[2048]; u16 ctrl, id; u32 nl, alloc, wl; int hlen, l3, mlen, ethlen, i;
	ctrl = hif_r16(HIF_CONTROL);
	nl = ((u32)(ctrl & 0x0FFF) | ((u32)(ctrl & 0xC000) >> 2)) * 2;
	while (nl) {
		if (nl < 4 || nl > 1600) return 0;
		alloc = (nl + 2 + 255) & ~255u; if (alloc > sizeof(b)) return 0;
		if (cmd53_block(0, ((u32)((m3_bufrx & 3) + 1) << 6) | HIF_QUEUE, b, alloc)) return 0;
		m3_bufrx = (u8)((m3_bufrx + 1) & 3);
		id = (u16)((b[2] | (b[3] << 8)) & 0x0FFF);
		ctrl = (u16)(b[alloc-2] | (b[alloc-1] << 8));
		nl = ((u32)(ctrl & 0x0FFF) | ((u32)(ctrl & 0xC000) >> 2)) * 2;
		if (id == 0x0804 || id == 0x0814) {
			u8 *m = b + 20;                            /* 802.11 MPDU (4 hdr + 16 desc) */
			if (!atbm_bssid_learned) {                 /* ToDS addr1 = BSSID */
				for (i=0;i<6;i++) atbm_bssid[i]=m[4+i]; atbm_bssid_learned=1;
				printf("atbm eth: BSSID(rx) %02x:%02x:%02x:%02x:%02x:%02x\n",
				       m[4],m[5],m[6],m[7],m[8],m[9]);
			}
			wl = (u32)(b[0] | (b[1] << 8));            /* wsm len */
			mlen = (int)wl - 20;                       /* MPDU length */
			hlen = 24;
			if (((m[0] >> 2) & 3) == 2 && (m[0] & 0x80)) hlen = 26;  /* QoS-Data */
			l3 = hlen + 8;                             /* + LLC/SNAP */
			if (mlen < l3 + 1) continue;
			ethlen = mlen - l3;
			if (14 + ethlen > outmax || ethlen <= 0) continue;
			for (i=0;i<6;i++) out[i]     = m[16 + i];  /* DA = addr3 (ToDS) */
			for (i=0;i<6;i++) out[6 + i] = m[10 + i];  /* SA = addr2 */
			out[12] = m[l3 - 2]; out[13] = m[l3 - 1];  /* ethertype (after SNAP) */
			for (i=0;i<ethlen;i++) out[14 + i] = m[l3 + i];
			return 14 + ethlen;
		}
		/* confirm/event/etc -> keep draining */
	}
	return 0;
}

/* ---- DM_ETH glue ---- */
struct atbm_eth_priv { int up; uchar rx[PKTSIZE_ALIGN]; };

static int atbm_eth_start(struct udevice *dev)
{
	struct atbm_eth_priv *pv = dev_get_priv(dev);
	if (atbm_ensure_linked()) { printf("atbm eth: link-up failed\n"); return -1; }
	m3_frame(MCU_WDT_DISABLE, 0, 0); mdelay(5);       /* keep the wdt off */
	if (!atbm_ap_is_up) atbm_wifi_ap_up("s2", 6);
	pv->up = 1;
	printf("atbm eth: up (host 192.168.43.2, client .200)\n");
	return 0;
}
static int atbm_eth_do_send(struct udevice *dev, void *packet, int length)
{ return atbm_eth_tx((const u8 *)packet, length) ? -1 : 0; }
static int atbm_eth_do_recv(struct udevice *dev, int flags, uchar **packetp)
{
	struct atbm_eth_priv *pv = dev_get_priv(dev);
	int l = atbm_eth_rx(pv->rx, (int)sizeof(pv->rx));
	if (l <= 0) return -EAGAIN;
	*packetp = pv->rx;
	return l;
}
static int atbm_eth_free_pkt(struct udevice *dev, uchar *packet, int length) { return 0; }
static void atbm_eth_do_stop(struct udevice *dev)
{ struct atbm_eth_priv *pv = dev_get_priv(dev); pv->up = 0; }
static int atbm_eth_read_hwaddr(struct udevice *dev)
{ struct eth_pdata *pd = dev_get_plat(dev); memcpy(pd->enetaddr, atbm_eth_mac, 6); return 0; }

static const struct eth_ops atbm_eth_ops = {
	.start           = atbm_eth_start,
	.send            = atbm_eth_do_send,
	.recv            = atbm_eth_do_recv,
	.free_pkt        = atbm_eth_free_pkt,
	.stop            = atbm_eth_do_stop,
	.read_rom_hwaddr = atbm_eth_read_hwaddr,
};
U_BOOT_DRIVER(eth_atbm_wifi) = {
	.name      = "eth_atbm_wifi",
	.id        = UCLASS_ETH,
	.ops       = &atbm_eth_ops,
	.priv_auto = sizeof(struct atbm_eth_priv),
	.plat_auto = sizeof(struct eth_pdata),
};
```

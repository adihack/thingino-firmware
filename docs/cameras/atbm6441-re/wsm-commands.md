# ATBM6441 host↔firmware WSM command layer (T23 → ATBM over SDIO)

This documents the **WSM host-command layer** — the messages the T23 driver
(`hal_apollo`, `/dev/atbm_ioctl`) sends to the ATBM firmware over SDIO. It sits
*above* the raw SDIO/HIF transport and *beside* (not below) the Z7682
message_mgr. Understanding it is what let us build a T23-only stop-scan for the
~56 s reset.

> **Why this matters:** the `atbm mcu`/message_mgr commands in
> [msgid-reference.md](msgid-reference.md) are all sub-commands of ONE WSM id
> (`0x003A` general-cmd, ACACCACA-framed). Peripheral WiFi control (mode switch,
> reconnect, scan) uses *different, first-class WSM ids* — a separate space.
> They ride the exact same SDIO transport, so anything that can send `0x003A`
> (our U-Boot `atbm` command) can send them too.

## Two command planes, one transport

```
T23 driver (hal_apollo)  ── SDIO CMD53 to HIF queue (force addr 0x28) ──►  ATBM fw WSM dispatcher
                                                                              │
   wsm_cmd_send(hw_priv, buf, arg, REQ_ID, ...)                              ├─ id 0x000D → wifimode
        REQ_ID = 0x000D  wifimode        (8B struct)   ── plane A ──────────►├─ id 0x000E → ap_cfg
        REQ_ID = 0x0036  auto_reconnect  (8B struct)                         ├─ id 0x0036 → auto_reconnect
        REQ_ID = 0x002C  clear_wifi_cfg  (4B struct)                         ├─ id 0x002C → clear cfg
        REQ_ID = 0x003A  general-cmd     (532B ACAC..)  ── plane B ──────────►└─ id 0x003A → Z7682 message_mgr
                                                                                     └─ msg_id 0x01..0x45 (see msgid-reference.md)
```

Both planes go through the **same** `wsm_cmd_send()` → `wsm_cmd_hif_ximt()` →
SDIO block-write. The *only* differences between a wifimode command and a
general-cmd are the 16-bit **id** and the **payload** bytes.

## Exact TX frame format  `[RE — certain, from driver source]`

`struct wsm_hdr_tx` (this build: `ATBM_WSM_SDIO_TX_MULT` **off**, `SPI_BUS`
**off**, so it is exactly 8 bytes) followed by the WSM payload:

| offset | size | field | value |
|---|---|---|---|
| 0 | 4 | `flag` | `len \| (checksum << 24)` (see below) |
| 4 | 2 | `len`  | `8 + payload_len` (little-endian) |
| 6 | 2 | `id`   | `REQ_ID \| (if_id << 6)` — if_id=0 here |
| 8 | N | payload | the WSM struct |

* `len` **includes** the 8-byte header. General-cmd: `8 + 532 = 540 = 0x021C` ✓
  (matches the value our U-Boot `m3_frame` already writes).
* `flag` (from `bh_sdio.c`, `PROJ_TYPE>=ARES_A`):
  ```
  lo = len & 0xff ;  hi = (len>>8) & 0xff ;  sum = lo + hi
  chk = (sum & 0x100) ? (sum+1)&0xff : sum&0xff
  flag = len | (chk << 24)          # bytes: lo hi 00 chk
  ```
  For `len=0x021C`: `0x1C+0x02 = 0x1E` → `flag = 0x1E00021C` ✓ (proven working
  general-cmd value). For `len=0x0010` (an 8-byte-payload cmd): `chk=0x10` →
  `flag = 0x10000010`.
* SDIO transfer length is **block-rounded to 256** (func1 block size = 256).
  A 16-byte frame is sent as one 256-byte block; the fw reads `len` for the
  real size and ignores the padding.
* The firmware reads **id from offset 6** and the **payload from offset 8**
  (verified: the 0x003A general-cmd's ACACCACA magic sits at offset 8 and is
  found correctly, so a plane-A payload starts at offset 8 too).

Sender reference (matches U-Boot `board/ingenic/isvp-t23/atbm_wdt.c :: m3_wsm_raw`):
```
txlen = 8 + paylen
f[0]=lo; f[1]=hi; f[2]=0; f[3]=chk          # flag
f[4]=lo; f[5]=hi                            # len
f[6]=id&0xff; f[7]=id>>8                     # id
f[8..]=payload
cmd53_block(WRITE, HIF_QUEUE_FORCE(0x28), f, round_up_256(txlen))
```

## Customer WSM id table (the set THIS firmware/driver uses)

From `hal_apollo/wsm.h`. IDs marked ⚠ collide numerically with a legacy
mac80211 `*_REQ_ID` of the same value; on this firmware the **customer**
meaning is the live one (the `.ko`'s mac80211 host path is unused — WiFi is
driven only through `/dev/atbm_ioctl`). Confirm any ⚠ empirically.

| id | name | resp | payload struct | size | notes |
|---|---|---|---|---|---|
| 0x000D ⚠ | **wifimode** | 0x040D | `wsm_wifi_set_req` | 8 | `{u32 status; u8 is_ap; u8 channel; u8 countryId; u8 rsvd}` — is_ap=1 ⇒ AP |
| 0x000E | ap_cfg | 0x040E | `wsm_ap_cfg_req` | big | SSID/key/channel — starts the AP (needs SSID) |
| 0x000F | wifi channel | 0x040F | — | | |
| 0x0010 | set country | 0x0410 | — | | (also SET_PM in legacy set) |
| 0x0026 | fw_sleep | 0x0426 | `wsm_generic_req` | 4 | `{u32 status}` |
| 0x002C | clear_wifi_cfg | 0x042C | `wsm_generic_req` | 4 | wipes STA target |
| 0x0034 | set wakeup ssid | 0x0434 | | | |
| 0x0035 | clear wakeup ssid | 0x0435 | | | |
| 0x0036 | **auto_reconnect** | 0x0436 | `wsm_auto_reconnect_req` | 8 | `{u32 status; u8 auto_enable; u8 rsvd[3]}` — 0 ⇒ disable |
| 0x0038 | customer_cmd | 0x0438 | | | |
| 0x003A | **general-cmd** | 0x043A | 532B ACACCACA | 532 | → Z7682 message_mgr (msgid-reference.md) |
| 0x003C | check_alive | 0x043C | | | SDIO keep-alive channel |

Full list: `grep _REQ_ID hal_apollo/wsm.h`.

## The ~56 s reset stop-scan  `[TBC — U-Boot live test pending]`

Root cause (see main doc §14.4c): booted as STA with no saved AP, the ATBM
scans forever, asserts `LMACtoUMAC_ScanComplete` after ~25 scans, HW-WDT resets,
and `master_power_on` power-cycles the T23 at ~56 s. **Fix = stop the STA scan
from the T23** (the ATBM AT-UART is a lab tool for one camera only).

`msg_id 0x37` (SPICMD_SET_WIFI_STOP, a *plane-B* general-cmd sub-command) was
tested and does **NOT** stop the scan (scan_cnt kept climbing → crash). The scan
is a MAC-layer STA activity, so the lever is a **plane-A** WSM command:

Candidates, sendable from U-Boot as `atbm wsm <id> <bytes…>`:

| try | command | why | id collision? |
|---|---|---|---|
| 1 | `atbm wsm d 00 00 00 00 01 00 00 00` | wifimode is_ap=1 (STA→AP). Boot log proves Linux `WIFI_MODE=AP` → "bcreate_ap" stops the scan; fw string *"not support disconnect in AP mode!"* ⇒ AP mode has no STA | ⚠ 0x000D |
| 2 | `atbm wsm 36 00 00 00 00 00 00 00 00` | auto_reconnect disable — kills the reconnect loop directly, stays "wifi off" | no |
| 3 | `atbm wsm 2c 00 00 00 00` | clear_wifi_cfg — removes the STA target | no |

The winner gets baked into `atbm_wdt_console_entry()` (single link-up, then the
WSM frame) so idle-U-Boot / recovery flashing is crash-proof. Update this
section with the confirmed command + scan_cnt evidence once the live test runs.

## U-Boot test harness

`atbm_wdt.c` now exposes:
* `atbm wsm <id_hex> [byte_hex …]` — inject any raw WSM command (plane A or B).
* Console-entry does a **single** `atbm_ensure_linked()` (a 2nd `atbm_link_up`
  CMD0s the live card = fatal), so multiple `atbm wsm` calls reuse one link.

This makes the SDIO/WSM transport a general-purpose T23→ATBM poke tool for any
future peripheral work (floodlight, PIR, IR — once their planes are mapped).

---

## LIVE 2026-07-26 — bare-U-Boot WSM injects are DROPPED (`Rx No Descriptor`)  `[LIVE]`

Flashed a U-Boot with `atbm wsm` + a **0x13-only** console-entry (dropped the
crash-causing 0x37) and tested the stop-scan candidates at a **stable** idle
U-Boot (no reboot-loop — confirming 0x37 was what crashed the ATBM). Results:

| plane-A WSM sent from U-Boot | scan stopped? | ATBM reaction |
|---|---|---|
| `atbm wsm d ..01..` wifimode=AP (0x0D) | NO (scan kept climbing) | `HIF HW ERR6: Rx No Descriptor (Host tries to send data with no hif input queue set)!` |
| `atbm wsm 36 ..` auto_reconnect off (0x36) | NO | dropped |
| `atbm wsm 2c ..` clear_wifi_cfg (0x2C) | NO | dropped |

**Root cause:** the ATBM WiFi-MAC HIF input queue has no descriptors
(`numInpChBufs = 0`) until the driver completes the STARTUP handshake
(`HI_SDIO_StartUp_Indication` then host configures the input channel). Bare
U-Boot never does that handshake, so every plane-A WSM frame the host injects is
discarded — the commands are correct, they just never reach the WSM dispatcher.
(Confirms the earlier `numInpChBufs=0 until STARTUP_IND` prediction.)

### Two-plane consequence (important)
- Plane B (message_mgr, WSM 0x003A to Z7682 MCU): REACHES the ATBM from bare
  U-Boot. The console-entry 0x13 (MCU wdt-disable) went in with NO `Rx No
  Descriptor`, and v2 shows no ~14s MCU-wdt reset, so the MCU accepts plane-B
  frames without the WiFi-MAC input queue. The MCU has its own always-on path.
- Plane A (direct WiFi-MAC WSM: 0x0D wifimode, 0x36 reconnect, 0x2C clear):
  BLOCKED from bare U-Boot (`Rx No Descriptor`) until the STARTUP handshake.

### Therefore the U-Boot stop-scan must be a plane-B (MCU) command, not plane-A
The scan is a WiFi-MAC activity, but the MCU can command the MAC. Try via
`atbm mcu <id> [arg]` (plane B, reaches the ATBM):
- msg_id 0x40 `wifi_start_ap` (to internal 0x1031): MCU brings up AP, tears down
  STA, scan stops. May need an SSID payload or may reuse the saved `thinginoAP`
  NVRAM config; TBD from the 0x40 handler disasm.
- msg_id 0x41 `wifi_stop_ap`; re-examine 0x37 `wifi_stop` (0x37 already tested =
  did NOT stop scan).
- If no plane-B command stops the scan, the only remaining route is to implement
  the STARTUP handshake in U-Boot (set up numInpChBufs) so plane-A 0x0D works;
  big, but it would unlock ALL ATBM control from U-Boot (floodlight/PIR too).

### v2 status (this build)
- Idle U-Boot is stable (no reboot-loop; survives ~26-64s to the eventual
  scan-crash, vs 6.6s for the 0x37 build). Enough of a window for recovery flashing.
- Recovery flashing from Thingino Linux WORKS: login `root`/`adrian`
  (older-build password; current build config = `root`), push image over UART
  (raw stty + chunked base64), `flashcp -v ub.bin /dev/mtd0`. mtd0="boot" 0x50000.
  This is the reliable install path (the SD can't be mounted; kernel has no FAT).

---

## LIVE+RE 2026-07-26 (cont.) — the reconnect loop + the REAL stop lever  `[RE high-confidence, live-test PENDING]`

Multi-agent RE of `sta_reconnect_config` (the scan loop) + the message_mgr wifi
handlers. Corrects the earlier premature `master_mode=0` claim.

### The scan/reconnect loop (why it crashes)
- `sta_reconnect_config` @ VMA `0xa029a` (prints the `scan_cnt/cust_cnt/scan_expire`
  line). Driven by reconnect timer-tick `0xa3580`, which only issues a scan
  (`0xa34da`) while `ctx->state@+0x38 == 3` (STA).
- The loop rate is gated by **`ctx[0x374]`** (ctx = `*(gp-632)` = `*0x807708`):
  `0`=rapid rescan (`scan_expire` stuck at 1, `cust_cnt` 0) → hits
  `LMACtoUMAC_ScanComplete` assert + HW-WDT reset (~26 s); nonzero=exponential
  backoff (`scan_expire` 30/60/120/300/600 by `cust_cnt` bucket) → effective stop.
- `ctx[0x374]` is set to 1 **only on real AP association** (`0xa28ac`) → with no AP
  it stays 0 forever → permanent rapid loop. **NOT host-settable.** (This is why
  the earlier "scan_expire=30/cust_cnt=2 stopped" state was a red herring — it
  needs association we can't fake.)

### master_mode (msg `0x2b`) is NOT the lever  `[corrects earlier claim]`
`0x2b` → internal `0x1017` → `set_master_mode` writes `primary_vif[0x99]` (a
per-VIF power-mgmt tag carried into TX descriptors on the *associated* path). It
is read by exactly 3 sites (all TX-frame builders), **never by the scan/reconnect
logic**. And `0x2b`=0 doesn't even write the byte. So `master_mode=0` does
nothing to the scan. The v5 "stop" earlier was a state coincidence + a malformed
frame (see CRC bug below). **Do not use 0x2b for stop-scan.**

### THE reliable host lever = tear down the STA → AP mode = msg `0x40` (start_ap)
- `0x40` handler `0xab070`: logs `wifi_start_ap:%s`, memcpy's the SSID into the
  36-byte AP-cfg buffer `0x8099b8` (gp+0x2038), posts internal event `0x1031`.
- event task `0xab4ac` → dispatcher `0xab15c` → table `0xab184` idx 0x30 →
  `0xab49a` → `lp_wifi_start_ap 0xacee6` → sets **`master_ctx[0xa1]=1`** (AP-active,
  `master_ctx=*(gp-628)=*0x80770c`), **deauths the STA**, flips vif STA→AP.
- AP mode ⇒ `ctx->state != 3` ⇒ tick `0xa3580` never calls the scan work ⇒ scan
  never re-issued ⇒ assert never reached. **This is exactly the proven driver
  `/dev/atbm_ioctl WIFI_MODE=AP` fix (atbm_softap.c).** Confidence HIGH.
- Payload: a SHORT non-empty ASCII SSID (e.g. `"s2"`), 1..32 bytes; channel/sec
  default (buffer pre-zeroed = open/default). **Empty SSID can abort AP bring-up.**
- Side effect: an AP beacon comes up (WiFi in AP mode, not "off"). That is the
  normal Thingino stable state anyway, and matches the future "recovery-AP for
  U-Boot" goal.

### msg `0x37` (wifi_stop) is NOT reliable (guarded no-op when unassociated)
`0x37` → internal `0x1023` → `0xab40a` → `0xace0c`, a disconnect that
`beqz→return`s if the connected-handle is 0. During the boot scan the STA is not
associated → handle 0 → **no-op**. (One agent thought 0x37 hits the full
`atbmwifi_stop`/timer-delete; the synthesis trace shows the guarded path. Verify
live, but do not rely on 0x37.)

### CRITICAL BUG FOUND + FIXED in our U-Boot `m3_frame`  `[fixed in v6]`
The message_mgr message (starts at frame off 8) is:
`magic@8  msg_id@12  crc32@16  len@20  payload@24`, and the dispatcher `0xaa954`
**CRC-checks `crc32(payload,len)` at `0xaa97e` and REJECTS a bad CRC.** The old
`m3_frame` hardcoded `crc=0xFFFFFFFF`, left `len@20`=0, and put the payload at the
wrong offset — so it only ever worked for EMPTY payloads (`crc32(empty)=0xFFFFFFFF`).
Every non-empty command (incl. `2b 0/1`, `40` with SSID) was **malformed/rejected**.
Fixed: new `m3_msg(cmd,payload,paylen)` sets `len@20`, `payload@24`, and
`crc@16 = atbm_crc32(payload,paylen)` (reflected poly 0xEDB88320, init 0xFFFFFFFF,
**no final inversion**). `m3_frame` is now a thin 0/4-byte wrapper.

### v6 test harness (flashed, md5 fc8c568a) — verify at next cold boot
- console-entry reverted to minimal (link-up + `0x13` wdt-off only) → fast prompt.
- `atbm ap <ssid>`  = msg `0x40` start_ap + SSID + real CRC  ← **primary lever**
- `atbm mcu 37`     = msg `0x37` wifi_stop (empty payload)   ← secondary (likely no-op)
- **Test plan:** cold power-cycle → catch v6 U-Boot (ATBM scanning) → `atbm ap s2`
  → scan_cnt should freeze (STA→AP), stable past ~26 s. If good, bake
  `m3_msg(0x40,"s2",2)` into the console-entry (spaced ~a few s after 0x13, so the
  ATBM has a STA vif to tear down and we avoid the rapid-double-inject HIF flood
  that crashed v4). CANNOT be tested via sysrq-b (that leaves the ATBM warm in AP
  mode with a torn-down HIF — needs a real cold power cycle).

---

## SOLVED + LIVE-VERIFIED 2026-07-26 — crash-proof idle U-Boot  `[LIVE PASS]`

Idle U-Boot now holds **stable for 110s+ with 0 resets** (past both the ~14s MCU-wdt
and the ~26s scan-crash). The console-entry does the stop-scan itself. This is the
shippable recovery-bootloader fix (patch `0002-cmd-atbm-wdt.patch`).

### The working recipe (console-entry `atbm_wdt_console_entry`)
```
ensure_linked();                 // one SDIO enum + wake (msc1 + WUP + msg-mode)
m3_frame(MCU_WDT_DISABLE,0,0);   // msg 0x13, empty payload  -> kills the ~14s MCU wdt
mdelay(5);
m3_msg(0x40, "s2", 2);           // msg 0x40 wifi_start_ap SSID "s2" (+ real CRC)
mdelay(30);
m3_read_confirm();               // drain the 0x043A confirm off the output ring
```
`0x40` flips the scanning STA vif to AP (`message_mgr wifi_start_ap:s2 -> bcreate_ap
ssid:s2`), so the reconnect tick (gated on state==STA) stops → no
LMACtoUMAC_ScanComplete assert. `0x13` kills the MCU watchdog. Both are needed —
either one alone still leaves the other reset firing.

### The transport that actually works: FORCE bit + buf_id CYCLING
Two independent facts had to combine:
- **FORCE bit** (SDIO addr `(buf_id<<6)|0x20|reg0x08`) — bypasses the device
  ready-handshake. Required because bare U-Boot never completes the STARTUP
  handshake (`sdio_state` stays 0), so the *normal* write path's ready-gate never
  opens. A normal (non-force) write from U-Boot fails even the 1st frame.
- **buf_id CYCLING** (0,1,2,…) — each frame must target a FRESH input descriptor.
  The device boot-arms `numInpChBufs`=24 descriptors; a fixed force buf_id 0
  delivers exactly ONE frame, the 2nd hits `Rx No Descriptor` → HifIntCauses flood
  → OS_Exception. Cycling buf_id spends a different armed descriptor per frame.
So: `cmd53_block(WRITE, ((m3_bufid++ & 0x3f)<<6)|0x28, frame, 768)` per command.

### Bounds (important, per design review)
- Descriptors are **bounded to ~24 per U-Boot session and do NOT auto-recover**
  (real recovery needs the STARTUP handshake, which we could not get to arm the
  input ring from a mid-life enum — see the v8/v9 attempts + numInpChBufs=24 read).
  The console-entry sends only **2** frames, so this is fine.
- Every **cold boot re-arms all 24** (the ATBM re-boots + re-arms). And **booting
  Linux from U-Boot re-enumerates the SDIO** (fresh 24 + the real credit-managed
  handshake), so U-Boot's 2 used descriptors never starve Linux.
- >24 interactive commands in one U-Boot session would run dry — that (and general
  device→host flow) is what the full STARTUP handshake would unlock (future work).

### Message frame layout + CRC (also fixed here)
message_mgr packet starts at frame off 8: `magic@8 msg_id@12 crc32@16 len@20
payload@24`; dispatcher (0xaa954) CRC-checks `crc32(payload,len)` at 0xaa97e and
REJECTS a bad CRC. `atbm_crc32` = reflected poly 0xEDB88320, init 0xFFFFFFFF, **no
final XOR** (so crc32(empty)=0xFFFFFFFF, which is why the old hardcoded-0xFFFFFFFF
worked for empty-payload cmds only). WSM id = `0x003A | (tx_seq<<13)`, tx_seq 3-bit.

### Recovery install path (unchanged, still the fallback)
Flash from Thingino Linux: login `root`/`adrian`, push image over UART (raw stty +
chunk-verified base64: scratchpad/xr.ps1), `flashcp -v ub.bin /dev/mtd0`. mtd0="boot".

---

## The full host<->device handshake, DECODED 2026-07-27  `[RE + LIVE]`

Goal: let U-Boot issue UNLIMITED commands (not the ~24 bound of the recovery
console) and receive device->host replies/indications. Multi-agent RE + live
AT-console diagnosis on a stable v11 board resolved the exact mechanism.

### It was never a device-state we were failing to reach
Read the ATBM's own memory live via the AT-console in BOTH idle-U-Boot(v11) and
full Linux (gp=0x807980; `sdio_state` = BYTE at gp-24160 = **0x801B20**):
- `sdio_state == 2` in **both** — stable. Not 0, not the "3" the old notes chased.
- Input-descriptor buffer array (0x801B4C, 24 ptrs `0900c878 + n*0x668`) armed in both.
- The only U-Boot-vs-Linux deltas are TRAFFIC COUNTERS + WiFi-MAC config words.

There is **no device-side handshake flag Linux sets that U-Boot doesn't**. The
state machine (`StateMachine` @0xA9BB8, byte state, jumptable @0xA9BFC) advances
0->1 autonomously at ATBM boot (`SdioReset` @0xA9F1E); 1->2 when the first inbound
msg is processed (`CheckInitDone` @0xA9D98 sets gp+0x1c19=0x809599); 2->3 needs
`0xAB000138 bit12 == 0`. **State >= 1 already un-gates the input drain+re-arm**
(`HiSdio_ProcessInputReady` @0xC4BA0 bails only on state==0), so reaching 3 is NOT
required.

### The real gate: credits are recovered ONLY by device->host completions
- Input descriptors are re-armed exclusively by leaf `c4788` (writes the
  descriptor-status ring at 0xAB000000+slot*4 with bit17=armed, bumps tail
  gp-22804=0x80206C, `depth<0x19`=25 guard => the ~24 pool = numInpChBufs).
- **`c4788`'s ONLY caller is `c49bc`, the device->host output-COMPLETION handler
  (event 0x4000), which itself gates on sdio_state!=0.**
- => A fire-and-forget host write that elicits no reply consumes one input
  descriptor and never triggers a completion, so the pool bleeds to 0 after ~24 —
  EXACTLY the observed bound. A reply-eliciting command self-sustains (1 in ->
  1 out -> 1 re-arm). Confirmed live: driving version-reads grew the ring tail
  past its boot value; blind fire-and-forget froze + crashed the ATBM.

### The deployable fix (host-side, no firmware download, no AHB SMU init)
The ATBM self-boots its 2MB flash firmware, so the three `after_load_firmware`
AHB SMU writes (0x161000ac / 0x1610102c+poll / 0x16100074) are ALREADY satisfied —
skip them (they exist only for the fw-DOWNLOAD path, done with the CPU held in
reset). NEVER assert CONFIG CPU_RESET(bit14) — it halts the running firmware.

Host must simply, over SDIO func1 (block size 256):
1. Enter message mode: CONTROL |= WUP(bit12); CONFIG &= ~ACCESS_MODE(bit10); dummy
   read CONFIG (arms the IRQ). (v11's `wake_light` already does this; state=2 proves it.)
2. **Service the device->host direction** = the actual unlimited-commands fix:
   read CONTROL(reg1) NEXT_LEN `((c&0x0FFF)|((c&0xC000)>>2))*2`; while nonzero,
   size-validate (>= wsm_hdr(4), <= EFFECTIVE_BUF_SIZE) then CMD53-read
   `roundup(len+2,256)` bytes from the IN_OUT queue (reg2 = SDIO addr 0x08); take
   the piggybacked next-len from the last 2 bytes; loop. **The read buf_id MUST be
   a PERSISTENT counter cycling 1,2,3,4 across the whole session** (driver
   `hw_priv->buf_id_rx`, addr uses buf_id_rx+1) — resetting it per call desyncs the
   HIF and crashes the ATBM at ~5 reads (the bug in the old confirm reader).

Addressing: `SDIO_addr17 = (buf_id<<6)|(force<<5)|((reg_id<<2)&0x1F)`. CONFIG=reg0
(0x00), CONTROL=reg1 (0x04), IN_OUT_QUEUE=reg2 (0x08), AHB_DPORT=reg3 (0x0C),
SRAM_BASE=reg4 (0x10).

### Live diagnostic map (AT+rmem, ATBM side; gp=0x807980)
| addr | what | note |
|------|------|------|
| 0x801B20 (u8) | sdio_state | 2=running; !=0 ungates drain/re-arm |
| 0x809599 (u8) | 1->2 flag | set by CheckInitDone on first inbound msg |
| 0x80206C (u32) | ring tail (produced) | bumped by c4788 re-arm; watch it advance |
| 0x802070 (u32) | ring head (consumed) | |
| 0x802074 (u32) | ring modulus | 0x40 |
| 0x802078 (u32) | input ring base | 0x0AB00000 (DRAM) |
| 0x0AB00000 | INPUT desc ring | `[len/flags:16][buf_lo:16]` x N, bit17=armed |
| 0x0AB00100 | OUTPUT ring | device->host `[buf_ptr][len]` pairs |
NB: 0xAB000000 (peripheral HIF regs, bit12 gate @0x138) reads 0 via AT+rmem; probe
those from the T23/CMD52 side. 0x0AB00000 (DRAM rings) IS AT+rmem-readable.

### U-Boot implementation + LIVE PROOF (2026-07-27)  `[LIVE PASS]`

Implemented in `board/ingenic/isvp-t23/atbm_wdt.c` (patch 0002-cmd-atbm-wdt.patch):
- `atbm_rx_drain(want_id, *rc, max, verbose)` — the device->host output-ring drain.
  Persistent `m3_bufrx` (cycles 1,2,3,4 across the whole session; the OLD confirm
  reader reset it per-call -> HIF desync -> ATBM crash at ~5 reads), driver
  size-validity guard (`nl < 4 || nl > 1600 -> stop`), CMD53-read `roundup(nl+2,256)`
  from the IN_OUT queue, piggyback next-len from the last 2 bytes, loop.
- `m3_read_confirm()` now wraps `atbm_rx_drain`; buf-id counters reset in `atbm_link_up`.
- New U-Boot cmds: `atbm ping [n]` (send 0x13 n times + drain each reply — the
  unlimited-commands proof) and `atbm rx` (one-shot verbose drain).

**LIVE-VERIFIED on the camera:**
```
atbm ping DONE: 34/40 confirmed -> credit-recovery WORKS (>24)
FINAL ring: tail=0x3b(59) head=0x2a(42) sdio_state=0x2 ; U-Boot prompt alive
```
40 commands issued from U-Boot, board survived (old fire-and-forget crashed at ~24 /
the un-drained reader crashed at ~5). The ring HEAD reached 42 and TAIL 59 — input
descriptors re-armed far past the 24 boot pool, exactly because each drained reply
fired the fw output-completion -> `c4788` re-arm. `sdio_state` stayed 2 throughout;
no crash. This is UNLIMITED bidirectional U-Boot<->ATBM messaging.

Note: "34/40 confirmed" is the simple per-command confirm-MATCH heuristic (a 0x043A
reply sometimes lands in the next command's drain window); ALL 40 were delivered
(head=42) and the ring never starved. A stricter transport would tag/track confirms
per command — polish, not a transport limit.

Build gotcha (recorded): `make uboot-rebuild` HANGS forever with no output because
board.mk runs the interactive `select_camera.sh` (2>/dev/tty) at parse time when >1
camera defconfig exists and no tty is attached. Always build headless with
`make CAMERA=cinnado_s2_t23zn_os02g10_atbm6441 uboot-rebuild`.

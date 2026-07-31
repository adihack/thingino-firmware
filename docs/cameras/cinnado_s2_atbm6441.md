# Cinnado S2 — hardware & firmware reference

Ingenic **T23ZN** + OmniVision **OS02G10** + AltoBeam **ATBM6441** (with an on-package
**Z7682** MCU) + **GD25Q128** 16 MB SPI-NOR.

> **This file is the single source of truth for this board.** Every hardware/firmware fact we
> establish goes here — do not leave findings scattered in session notes. If you are about to
> re-derive something, search this file first.
>
> **Every claim carries a status tag:**
> * **[LIVE]** — observed on real hardware, with the observation quoted or summarised.
> * **[RE]** — from static reverse engineering (disassembly, strings, driver source). Believed
>   true but never exercised.
> * **[TBC]** — unknown, contradictory, or believed-but-unverified. **Do not build on these
>   without testing.** All of them are collected in §12.
>
> When you promote a fact from [TBC]/[RE] to [LIVE], update it *here* and say what you ran.

---

## 1. Board at a glance

| Part | Detail | Status |
|---|---|---|
| SoC | Ingenic T23ZN (XBurst1, MIPS32r2, single core, 1188 MHz; `Ingenic T23 (XBurst1)`, board `ISVP-T23ZN (SFC NOR)`) | [LIVE] |
| DRAM | 64 MiB total; Linux gets `mem=46M@0x0`, ISP `rmem=18M@0x2E00000` | [LIVE] |
| Sensor | OmniVision OS02G10, I²C bus 0 addr `0x3c`, 2304×1296 | [LIVE] |
| WiFi + MCU | AltoBeam ATBM6441 over SDIO (MSC1); contains the Z7682 MCU | [LIVE] |
| Flash | SPI-NOR 16 MB. U-Boot: `SF: Detected gd25q128`; Linux: `the id code = c84018, the flash name is GD25Q127C` | [LIVE] |
| Console | **ttyS1** @ 115200 8N1 (`serial@10031000`). **Not ttyS0.** | [LIVE] |
| Power | Permanent USB 5 V in this project. Battery + IP5209-class charger present but unused | [LIVE] |
| Pan/tilt | none (`ptz=0` in vendor config) | [RE] |

Vendor SDK path string: `lp_T23_OS02G10_S_sdk`. Vendor identifiers: `device_id=WVCE9JIMTHHEFOWI`,
`vendor_code=CND`, `product_name=S2`. [RE]

**Flash chip ID discrepancy [TBC]:** U-Boot and Linux both report GigaDevice `c84018`
(GD25Q128/127C). An early CH341A read reported `ef4017` (Winbond W25Q128). Probably a
programmer misread or a different unit; treat `c84018` as authoritative.

---

## 2. What the ATBM6441 actually is

### 2.1 Two independent cores behind one SDIO interface [RE]

* **WiFi core** — AltoBeam Athena/Hare generation RF+MAC, runs `ATHENA_BX` LMAC/HMAC firmware
  from on-chip ICCM/DCCM. Chip version register `0x0acc017c & 0x3f` reads `0x25` = AthenaBX
  (`fwio.c`, `atbm_HwGetChipFw`).
* **Z7682 MCU** — always-on power/offload controller: watchdogs, PIR, battery/ADC, floodlight
  power accounting, buttons, and an autonomous cloud-keepalive TCP client that runs while the
  host sleeps.

Both cores use the same AltoBeam proprietary 32-bit RISC ISA (both images open with an
identical `0x48`-prefixed vector table). The exact ISA is **unidentified** — ruled out
MIPS/ARM/PPC/Xtensa/SH/m68k/RISC-V/LM32/Nios2/8051; untested candidates ARC/ARCompact or
C-SKY. Not blocking for the port. [RE]

Live firmware banner: `=IOT+SDIO=RF=ATHENA_BX 2GHZ Jan 19 2024 15:25:31`, api **15043**,
build `patch15043_20240119_Timer32Int_APscan_NoDataAfterTIMtoReconn`, cap `0x0005`,
MCU version string **`1.2.5u1`**. [LIVE]

### 2.2 The firmware is RESIDENT — the host never downloads it

This is the single most misunderstood thing about this chip, and it has cost us time twice.

* The module has its **own writable non-volatile flash** and boots autonomously at power-on.
  Proof: the MCU watchdog resets the SoC while sitting at the **U-Boot prompt**, where no SDIO
  driver exists at all — so nothing on the host could have fed it firmware. [LIVE]
* Our driver is built `PROJ_TYPE=HERA`. In `fwio.c` `atbm_load_firmware()`, the actual download
  pair (`atbm_before_load_firmware` / `atbm_start_load_firmware`) is inside
  `#if (PROJ_TYPE==ARES_B)` and is **compiled out** — the symbol is not even in our `.ko`.
  Only `atbm_after_load_firmware()` runs: clear the WiFi-CPU reset bit, enable IRQ, switch to
  message mode. It *wakes* firmware that is already in TCM. [RE]
* Timing corroborates: SDIO enumeration → `wsm_startup_done` in **~24 ms**, far too fast to
  push ~1 MB over SDIO. [LIVE]
* `hal_apollo/firmware.h` in the gtxaspec tree is a *different architecture* (bare LMAC
  `=MODEM=RF=Ares_AX`, zero AP strings) and is **never loaded** on HERA. Ignore it. [RE]

**Consequence: you cannot avoid the MCU watchdog by "not loading firmware".** It is already
running when the SoC comes out of reset. The only lever is a runtime command over SDIO.

### 2.3 `mcu_fw.bin` is an OTA payload, not a per-boot load [RE]

`extracted/system/mcu_fw/mcu_fw.bin` (339 480 B) is applied by `lp_mgr` **only when the INI
version differs** from the running module version, via ioctl
`ATBM_MCU_FW_UPDATE = 0x8004791A` in 512-byte chunks (START → chunks → END).

Container (arithmetic verified: 512 + 0x26800 + 0x2c418 = 339480):

| Region | Offset | Content |
|---|---|---|
| Header | `0x000` | magic `5A 47 F2 10`; `+0x14` = seg1 padded size `0x26800`; `+0x18` = seg2 padded `0x2c418` |
| zlib seg1 | `0x200` | 196 608 B MCU CODE (entropy ~7.0, stringless, vector table) |
| zlib seg2 | `0x26A00` | 785 944 B — **the resident offload app** (watchdog/PIR/battery/`mingwei_light`/`lp_keeplive`, plus its own WiFi stack) |
| Footer | `0x52E00` | three 16-bit checksums, then the exact compressed sizes |

### 2.4 Crypto / secure boot: none that blocks us [RE]

* Both firmware images are **unencrypted, unsigned, swappable**; plain zlib streams.
* The WiFi `firmware.h` 16-bit checksum is declared but never verified.
* RSA (`/etc/rsa_pub.txt`, mbedtls) is used **only** by the vendor `upgrade`/`sd_upgrade` OTA
  binary, over whole partitions — bypassed entirely by a programmer or by U-Boot `sf write`.
* T23 SPL header is the stock Ingenic `06 05 04 03 02 55 aa 55`; no efuse/OTP lock. **No hardware
  secure boot.**
* The vendor TAG partition (plaintext bootargs) is flashed by `sd_upgrade` with **no** RSA check
  — that is the unsigned door we originally used to get a root shell.

---

## 3. Host ↔ chip link (SDIO)

### 3.1 Physical / pinmux [LIVE]

MSC1, 4-bit. Pins **PB8–PB14** (mux mask `0x6F00`), set to function 1:

```
pb08 F1 D2    pb09 F1 D1    pb10 F1 D1    pb11 F1 D1    pb13 F1 D1    pb14 F1 D1
```
Card-detect GPIO for the *SD card* slot is **gpio61** (`jzmmc_v12 cd_gpio_pin=61`); the ATBM is
on MSC1 and is brought up with `Send INSERT to MMC1`. SDIO host IRQ = **IRQ 44**
(`jzmmc_v1.2.1` in `/proc/interrupts`); IRQ 45 is `jzmmc_v1.2.0` (the SD slot).

### 3.2 SDIO reliability: the CMD53 root cause and its fix [LIVE]

A single marginal CMD53 carrying `WSM STARTUP_IND` was intermittently timed out by the jzmmc
PIO path, and two driver amplifiers turned that into a hard reboot loop. Fixed and validated
over 5/5 clean cold boots:

* **kernel** `all-patches/linux/0100-jzmmc-cinnado-s2-cmd53.patch` — 24 MHz + `RESTO`
  (response timeout) instead of an edge-clocked no-retry path.
* **driver** `0100-cinnado-s2-t23zn-atbm6441-compat.patch` part 1 (`hwio_sdio.c`,
  `apollo_sdio.c`) — replace `mdelay(1000)*MAX_RETRY(=10)` (which blocked ~10 s in one
  transfer and overshot the ~14.5 s watchdog) with a millisecond back-off, and stop ignoring
  the ctrl-register read return code that silently dropped the one-shot `STARTUP_IND`.
* **driver** part 3 (`bh_sdio.c`) — the 3-bit WSM RX sequence check used to `WARN_ON` and
  hard-drop **every** later frame after a single desync, wedging the confirm plane forever
  (send worked, every read hung 60 s). Now it resyncs and keeps the frame.

Verified stable: 10 h uptime, 113/113 MCU reads, 0 resyncs. [LIVE]

### 3.3 Bare-metal inject from U-Boot (no driver, no handshake) [LIVE]

U-Boot has no MSC1 node/clock/pinctrl for T23, so `board/ingenic/isvp-t23/atbm_wdt.c` drives
the controller from raw registers with zero conflict. Two non-obvious requirements — both were
bugs that made earlier attempts fail silently:

1. **TX SDIO address must be `0x28`, not `0x08`.** The first TX has `buf_force_rx=1`, so
   `SDIO_ADDR17BIT(buf_id=0, force=1, reg_id_ofs=IN_OUT_QUEUE_REG_ID(2)<<2=0x08)`
   = `(0<<6)|(1<<5)|0x08` = **0x28**. The force bit (bit 5) makes the firmware accept the
   buffer regardless of expected buf_id/seq — that is what allows injecting mid-stream.
2. **SDIO func1 block size must be 256, not 512** (the driver sets 256 for normal WSM
   operation). Blob enum must set FBR func1 block size via CMD52 `0x110=0x00`, `0x111=0x01`;
   CMD53 block mode with `MSC_BLKLEN=256`, `NOB=3` for the 768-byte frame
   (`round_up(540,256)`). At 512 the write is misaligned and the command arrives corrupt.

The WSM **credit gate** (`hw_bufs_free`, normally seeded by `STARTUP_IND`) is host-side
bookkeeping only, **not** a wire requirement — which is why fire-and-forget injection works
without any handshake. There is also **no** host-over-SDIO way to reboot the resident firmware
(every reset path is a stub or ARES_B-only), so a fresh `STARTUP_IND` from U-Boot is impossible.

### 3.4 WSM frame layout and ID map

Frame as injected (540 B, little-endian, zero-padded to 768) [LIVE]:

```
@0x00  flag        0x1E00021C   (len 0x021C in low 16 bits + carry-checksum 0x1E in high byte)
@0x04  len         540
@0x06  id          0x003A       (WSM message id)
@0x08  magic       0xACACCACA   (MCU general-command magic)
@0x0C  cmd         0x13         (MCU opcode)
@0x10  crc         0xFFFFFFFF   (accepted as-is; see §4.1)
@0x14  retcode     0            (filled by the device in the confirm)
@0x18  payload_len 0
@0x1C  data[512]   0
```

A real confirm captured in U-Boot [LIVE]:
```
atbm 0x043A raw: 18 02 3a c4  ca ca ac ac  13 00 00 00  ff ff ff ff  00 00 00 00
  -> len 0x0218=536, id 0x043a (+flags), magic ACACCACA, cmd 0x13, retcode 0
```

WSM IDs used on this board (from our shipped `wsm.h`) — **request / confirm**:

| ID | Name | Purpose | Status |
|---|---|---|---|
| `0x000D` / — | `WSM_WIFIMODE_REQ` | set WiFi mode (STA/AP). **Must precede 0x000E** | [RE] |
| `0x000E` / — | `WSM_AP_CFG_REQ` | SoftAP config (ssid/psk/channel/bssid) | [RE] |
| `0x0038` / `0x0438` | `WSM_CUSTOMER_CMD` | gtxaspec "customer command" channel (send-only in upstream) | [RE] |
| `0x003A` / `0x043A` | `WSM_GENERAL_CMD` | **the Z7682 MCU channel** (all MCU opcodes) | [LIVE] |
| `0x003C` / `0x043C` | `WSM_CHECK_ALIVE` | host-alive keepalive configure+refresh (§7.3) | [RE] |
| — / `0x0802` | WSM TRACE | firmware trace stream | [LIVE] |
| — / `0x0805` | `WSM_EVENT_INDICATION` | async events incl. buttons/PIR (§5) | [LIVE] |

> **Trap [LIVE]:** pristine gtxaspec defines `WSM_CHECK_ALIVE_REQ_ID = 0x003A`, which
> **collides** with the MCU general-command channel. The vendor uses `0x3c`. We moved it to
> `0x003C/0x043C` in our patch. If MCU replies ever come back garbled, check this first.

### 3.5 Userspace surface: `/dev/atbm_ioctl`

Char device, **major 249** (no mdev rule creates the node on a bare initramfs — `mknod
/dev/atbm_ioctl c 249 0`). [LIVE]

| ioctl | Value | Handler | Status |
|---|---|---|---|
| `ATBM_CUSTOMER_CMD` | `_IOW(121,50)` | customer cmd → WSM 0x0038 | [RE] |
| `ATBM_CHECK_ALIVE` | `_IOW(121,52)` = `0x80047934` | `atbm_wsm_start_check_alive` → WSM 0x003C | [RE] |
| `ATBM_MCU_GENERAL_CMD` | `_IOW(121,70)` = `0x80047946` | `atbm_wsm_send_general_cmd` → WSM 0x003A | [LIVE] |
| `ATBM_MCU_FW_UPDATE` | `0x8004791A` | MCU firmware OTA streaming | [RE] |
| `ATBM_PS_SET` | `0x80017900` | power-save mode | [RE] |

Our source-built `package/wifi-atbm6441/files/librtos.c` uses **`0x80047946`**. The *vendor*
`librtos.so` hardcodes **`0x80047934`**, i.e. what is `ATBM_CHECK_ALIVE` in our driver.
**Footgun [LIVE]:** any old tool of ours built against `0x80047934` (e.g. `mcu_cmd.c` in the
project dir) will arm the host-alive monitor with a 532-byte MCU packet reinterpreted as
`{status, alive_notify, period, tmo_cnt}` — garbage parameters. Fix the constant before use.

`read()` on the device returns the async status record; `fcntl(FASYNC)` + `SIGIO` notifies.
See §5.

---

## 4. Z7682 MCU command protocol

### 4.1 Packet [LIVE]

532 bytes, sent as the body of WSM `0x003A`, confirmed by `0x043A`:

```c
struct { u32 magic;      /* 0xACACCACA                        */
         u32 cmd_id;     /* opcode, see catalog               */
         u32 crc;        /* crc32(payload) poly EDB88320;
                            0xFFFFFFFF is accepted for empty  */
         u32 retcode;    /* device fills this in the confirm  */
         u32 payload_len;
         u8  data[512]; };
```
Arguments go at `data[0..]` with `payload_len` set (e.g. watchdog period = 4-byte LE seconds).

### 4.2 Command catalog

Decimal / hex opcodes. Names come from the vendor `mcu_test` `.rodata` (~70 strings); IDs were
pinned from `mcu_test`/`lp_mgr` disassembly and, where marked [LIVE], exercised on hardware.

| dec | hex | Name | Notes | Status |
|---|---|---|---|---|
| 2 | 0x02 | `wifi_connect` | | [RE] |
| 9 | 0x09 | `pir_enable` | required before PIR events flow | [LIVE] |
| 10 | 0x0A | `pir_disable` | | [RE] |
| 12 | 0x0C | ~~`wifi_set_ap_open`~~ **BOGUS** | opcode 12 is UNDEFINED in the jump table; old `--send-raw=12` was a no-op returning zeros. Real AP beacon = msg `0x40`, see §4.3 | [LIVE] |
| 13 | 0x0D | `set_detect_range` | PIR sensitivity/threshold | [RE] |
| 18 | 0x12 | `wdt_enable` | powers the WDT block; does **not** arm | [LIVE] |
| 19 | 0x13 | `wdt_disable` | no arg. **The recovery-critical opcode.** | [LIVE] |
| 20 | 0x14 | `wdt_set_period` | 4-byte LE seconds — **this arms the countdown** (vendor uses 12) | [LIVE] |
| 21 | 0x15 | `wdt_feed` | no arg; vendor feeds every 6 s | [RE] |
| 26 | 0x1A | `get_battery_status` | returns voltage/capacity/charge_status | [LIVE] |
| 27 | 0x1B | `get_battery_voltage` | e.g. `4b100000` = 4171 mV | [LIVE] |
| 36 | 0x24 | `version` | returns `1.2.5u1` | [LIVE] |
| 52 | 0x34 | `factory_reset` | **destructive** | [RE] |
| 59 | 0x3B | `set_rtc_mode` | | [RE] |
| 64 | 0x40 | `wifi_start_ap` | **starts + beacons the AP** — MUST be sent WITH a non-empty SSID payload (empty aborts). THE config-portal trigger, see §4.3 | [LIVE] |
| 65 | 0x41 | `wifi_stop_ap` | stops the AP beacon | [LIVE] |
| 67 | 0x43 | floodlight power *notification* | accounting only — does **not** drive the LED | [LIVE] |
| 68/69 | | `get/set_bat_inc_interval` | | [RE] |
| — | | `master_poweroff`, `wifi_master_poweroff`, `ble_start/stop`, `upgrade_fw`, `set_pir_type` | wired in `mcu_test`; **poweroff/upgrade are destructive** | [RE] |
| — | | `key_enable`, `key_disable`, `get_key`, `mcu_pin_status`, `mcu_int_status`, `keep_alive`, `enable_alive` | present as `mcu_test` getopt strings but **dead**: no dispatch branch, no recoverable opcode. lp_mgr's equivalents (`ZRT_CAM_WIFI_GetWakeupFlag`, `ClearAllWakeupFlag`) are compiled-out stubs (`memset(a0,0,4); return 0`) | [RE] |

**There is no synchronous "read a key/pin" command.** Buttons are only readable as async events
(§5). Verified by exhausting `mcu_test`, `lp_mgr` and `seg2.dec`. [RE]

Sending an MCU command from Linux:
```sh
mcu_test --version                 # or --get_battery_status, --pir_enable, --wdt_disable
mcu_test --send-raw=36             # raw opcode, DECIMAL, no payload
```
From U-Boot: `atbm mcu <cmd_hex> [arg_hex]`, and `atbm wdt on|off`.

---

### 4.3 Config-portal SoftAP — the real bring-up [LIVE CONFIRMED 2026-07-31]

The ATBM6441 runs its AP inside its own firmware (beacon + DHCP + gateway on `192.168.43.1`;
associated clients get `192.168.43.200`; the host portal sits at `192.168.43.2`). Bringing it up
needs BOTH planes:

1. **Configure** the SSID/channel over the WiFi-core (plane A / WSM ioctls) with
   `atbm_softap <ssid> <chan>`: `CLEAR_WIFI_CFG → WIFI_MODE=AP → SET_COUNTRY → WIFI_CHANNEL →
   AP_CFG(ssid)`. All return 0, but this **alone does not beacon**.
2. **Start the beacon** over the MCU (plane B / `message_mgr` general-cmd `0x003A`) with **msg
   `0x40` (`wifi_start_ap`) carrying the SSID as its payload**. Handler `0xab070` memcpy's the
   payload into its 36-byte AP-cfg buffer, deauths the STA, flips the vif STA→AP and beacons.
   `msg 0x41` = `wifi_stop_ap`.

**The bug (fixed in commit `a7e6f1e`):** `start_atbm_softap` fired `mcu_test --send-raw=12` as the
"open AP" step. **Opcode 12 does not exist** in the firmware jump table (§14.3: …`0x0a`
PIR-disable, then unlabelled/`set_detect_range`), so it was a no-op returning 256 zero bytes. And
`--send-raw=64` (the *right* opcode) also fails, because `--send-raw` carries **no payload** and
the `0x40` handler treats an empty payload as an empty SSID — which **aborts** the bring-up. So
the AP was configured but never beaconed (`wlan0` stayed `NO-CARRIER`, `hostevent bssid
00:00:00:00:00:00`).

**The fix:** `mcu_test --wifi_start_ap="<ssid>"` sends msg `0x40` *with* the SSID payload; the frame
CRC is computed by `librtos rtos_cmd_send` (same path `--wifi_connect` uses — which is why
STA-with-payload always worked). `--wifi_stop_ap` sends `0x41`. `S38wpa_supplicant`'s
`start_atbm_softap` now calls `--wifi_start_ap="$ssid"`.

**Live proof:** `--wifi_start_ap="THINGINO-TESTAP"` made the AP visible + connectable on a phone
(the broadcast SSID matched the payload); driving the real S38 path brought `wlan0` to `LOWER_UP`
(carrier up — was `NO-CARRIER` under op12) with the portal at `http://192.168.43.2`. It fails
**identically on every unit** → a wrong-command bug, **not** per-camera ATBM/MCU state, so the
no-open stock→Thingino conversion path is unaffected.

> Signal caveat: the beacon is generated inside the ATBM firmware, *below* the Linux netdev, so
> `wlan0` TX counters and `bssid` are NOT reliable "is it beaconing" signals from the T23 side.
> `LOWER_UP`/`carrier` after the full S38 path is a good signal; a scan from another device is
> definitive.

---

## 5. Asynchronous events — buttons, PIR, tamper

**Transport [LIVE]:** the MCU pushes a WSM **event indication `0x0805`** with
**`eventId = 16`**. Payload **word0 (first u32, LE) is a bitmask**. Bytes after word0 are stale
WSM-buffer junk (the driver does not zero them) — *only word0 is meaningful*.

| word0 bit | Value | Meaning | Status |
|---|---|---|---|
| 0 | `0x0001` | KEY0 (RST) **press** | [LIVE] |
| 1 | `0x0002` | KEY0 (RST) **release** | [LIVE] |
| 3 | `0x0008` | PIR motion (needs `pir_enable` first) | [LIVE] |
| 14 | `0x4000` | tamper alarm | [RE] |
| 22 | | Power-On reason | [RE] |
| 26 | | Reset reason | [RE] |

The bit numbers are wakeup-reason **codes** from a 27-entry `{code,name}` table in `lp_mgr`
(vaddr `0x0085E060`), which independently matches every live observation. It also reconciles an
older note that recorded "MCU codes 0x00/0x01 = Key0 down/up" — those are codes 0 and 1, i.e.
bits 0 and 1. [RE]

**A 6-second RST hold produced `word0=1` at t=184.34 s and `word0=2` at t=190.50 s (Δ6.16 s)** —
press and release are two separate events, and long-press/click timing is therefore a
**host-side** decision, exactly as the vendor does it (`lp_mgr` times 2 s → keyValue=3, ~6 s →
Factory Command). The MCU emits no "hold" event. [LIVE]

**No enable command is needed** for KEY/RING/TAMPER — they are unconditional. Only PIR is
gated (opcode 9). Three independent sources agree, and live testing confirms. [LIVE]
This supersedes an older note claiming short presses produced no event and that `key_enable`
was required — that observation was made with the event path broken (see below).

**Why these events were invisible until 2026-07-25** (all three had to be fixed):
1. `#define wsm_printk(...) // printk` — wsm.c logging is a **no-op**, so both arrivals and
   drops were silent.
2. `wsm_event_indication()` (wsm.c) and `atbm_event_handler()` (main.c) **vif-gate** any
   eventId not in {10,11,12,13,14}: they look up a vif and drop the event if there is none.
   eventId 16 needs the exclusion-list bypass.
3. `atbm_event_handler()` had **no `case 16`** at all (only up to 15), so it fell through.

Proof the MCU really was emitting all along: `/proc/interrupts` IRQ 44 rose **+51** during
button/PIR activity versus **flat 0** while idle. [LIVE]

**Forwarding to userspace (our implementation, commit `e6cbd10`):** a new
`atbm_ioctl_customer_async(code)` pushes word0 into a 16-deep ring buffer and fires
`kill_fasync(SIGIO)`; `atbm_ioctl_read()` drains one event per `read()` as a
`struct status_async` with **`type = 6`** and the bitmask at **offset 4**. Userspace listener:
`/usr/bin/mcu_evt` (source `package/wifi-atbm6441/files/mcu_evt.c`). Validated with zero loss:
rapid taps gave 10 press + 10 release in both the driver log and the tool. [LIVE]

`status_async.type` legend: `0` connect, `1` driver, `2` consumed/scan-complete, `3` wakeup,
`4` disconnect, `5` connect-fail, **`6` MCU customer event (ours)**.

eventId **15** (`WSM_EVENT_HOST_CUSTOMER_CMD_REQ`) is a *different* channel carrying
`struct sdio_customer_cmd_req { int cmd_id; char data[96]; }`. Not used by buttons. [RE]

---

## 6. GPIO map — CONFIRMED

All of the following were validated on hardware (audible clicks, visible light, sysfs toggles).

| GPIO | Function | Notes | Status |
|---|---|---|---|
| **60** | **Floodlight (white)** | on/off + software-PWM brightness. MCU opcode 0x43 is only power accounting, it does **not** drive the light | [LIVE] |
| **58 + 64** | **IR-cut filter** | H-bridge pair; two audible clicks confirmed | [LIVE] |
| **62** | **IR LED** | faint red glow visible | [LIVE] |
| **49** | Status LED — blue | bi-colour with 50 | [LIVE] |
| **50** | Status LED — red | vendor recovery `app_init.sh` lights this at start | [LIVE] |
| **63** | Speaker amp enable (`gpio_spk_en`) | thingino loads audio with `spk_gpio=63 spk_level=1` | [LIVE] |
| **18** | Sensor reset (`sensor_reset`) | driven high by the ISP driver | [LIVE] |
| **61** | SD-card detect (`mmc_detect`) | input | [LIVE] |
| PB8–PB14 | MSC1 SDIO to ATBM6441 | function 1, see §3.1 | [LIVE] |

**What thingino currently claims** (`/sys/kernel/debug/gpio`, live): only `18 sensor_reset`,
`58 sysfs`, `61 mmc_detect`, `62 sysfs`, `63 gpio_spk_en`, `64 sysfs`.
**`gpio60` (floodlight) and `gpio49`/`gpio50` (LEDs) are completely unclaimed** — nobody
declares or drives them. That is the remaining integration work for manual light control, and
it is plain GPIO work, **not** MCU work. [LIVE]

**The second physical LED is a hardware charge indicator**, not host-controllable. [LIVE]

---

## 7. Watchdogs — the messiest area, read carefully

There are **at least two** independent reset mechanisms, both owned by the ATBM/Z7682, plus an
unused SoC one. Getting this wrong costs a bricked or reboot-looping camera.

### 7.1 The SoC watchdog is NOT involved [LIVE]

* U-Boot prints `WDT: Not starting watchdog@0`. `CONFIG_WDT=y` and `CONFIG_WDT_INGENIC=y` are
  set (driver built, DT node `watchdog@0` inside `tcu: timer@10002000`, compatible
  `ingenic,t23-watchdog`/`ingenic,jz4780-watchdog`), but **`CONFIG_WATCHDOG` and
  `CONFIG_WATCHDOG_AUTOSTART` are unset**, so it is bound and never armed. It exists mainly to
  serve `sysreset` for the `reset` command (`CONFIG_SYSRESET_WATCHDOG=y`,
  `CONFIG_SYSRESET_WATCHDOG_AUTO=y`).
* `CONFIG_WATCHDOG_TIMEOUT_MSECS=60000` is therefore **inert**. Its numeric similarity to the
  observed ~56 s window is a coincidence — do not be fooled by it (we were, once).
* Linux does load `jz-wdt` (`jz-wdt: watchdog initialized`) and thingino starts a watchdog
  service; that is a separate, host-side concern.

### 7.2 Mechanism A — the ATBM/MCU startup watchdog (~14.5 s) [LIVE]

Self-armed by the resident firmware at power-on; **no host command arms it**. It resets the SoC
~14.5 s after power-on unless disabled. **`wdt_disable` (opcode `0x13`) genuinely disables it**
— confirmed both from U-Boot (bare-metal inject, `retcode=0`) and in Linux, where
`S09mmc` runs `/usr/bin/z7682_disable_wdt` once and the board then ran **10 h** with no reset.

Vendor arming pattern for its own app watchdog: `enable(0x12)` → `set_period(0x14, 12 s)` →
`feed(0x15)` every 6 s. Our `atbm wdt on` reproduces `0x12`+`0x14(12)` and the board does reset
(~6 s observed), so the arm path works too.

### 7.3 Mechanism B — a second reset at ~56 s [RESOLVED 2026-07-25, see §14.4]

**PARTLY EXPLAINED by the firmware dump (§14), then CORRECTED live (§14.4): the app-level lp_mgr `master_wdt` is DORMANT and is NOT this reset.**
The ATBM is the SoC power-master; `master_wdt_timer_cb` power-cycles the T23 when the host
stops kicking it. It is controllable from the T23 over SDIO via `message_mgr` msg_id 0x12
(STOP) / 0x13 (DELETE) / 0x14 (set period) / 0x15 (kick). The historical notes below are kept
for the measured numbers; the mechanism they puzzle over is now identified.

**Measured 2026-07-25, single variable, nothing typed after the prompt:**

```
18.8 s  T23 TPL (cold boot)
19.5 s  autoboot interrupted -> console-entry hook starts 'atbm wdt off'
30.6 s  confirm: cmd=0x13 retcode=0        <-- the sequence costs ~11.8 s
30.6 s  U-Boot prompt, then IDLE
75.0 s  *** RESET ***
        = 56.2 s after power-on  /  44.4 s after the prompt
```

So a successful `0x13` does **not** buy unlimited time in U-Boot. What fires at ~56 s is
unidentified. Candidates:

* the `WSM_CHECK_ALIVE` (0x003C) "host-alive" monitor — **but** see below: it appears to be
  arm-on-send, and nothing in thingino ever arms it;
* another timer in the 18/19/20/21 family with a default period;
* a boot-supervision deadline ("the host never completed WSM startup"), which would be
  **power-on relative and unfixable by feeding**.

**Whether the deadline is power-on-relative (56 s) or last-contact-relative (44 s) is
UNRESOLVED.** It decides whether feeding can work at all, and it cannot be measured with the
tools we have today (see the next point).

**The `check_alive` keepalive, fully specified but apparently unused [RE]:**
`check_alive_work()` in `atbm_ioctl.c` re-sends WSM `0x003C` every `period`:
```c
struct wsm_check_alive_req { u32 status; u32 alive_notify; u32 period /*s*/; u32 tmo_cnt; };
req.alive_notify = 1212;      /* host->6441; 6441->host uses 2121 */
```
The MCU-side timeout is `period × tmo_cnt`; `sdio_alive_check_cb()` re-arms the timer and prints
`check alive fail over` after `tmo_cnt` misses. The whole machinery also exists in the stock
vendor `.ko` (`wsm_check_alive`, `check_alive_work`, `sdio_alive_check_cb`,
`wsm_confirm_for_sdio_alive`). **But `is_start` is only ever set by the `ATBM_CHECK_ALIVE`
ioctl, and a grep of the entire thingino `package/` tree finds no caller** — yet Linux survives
indefinitely. Therefore this monitor is **armed by sending the frame**, and sending it from
U-Boot would *create* a watchdog we must then feed forever. Do not use it as a feed. [RE]

### 7.3b Feed experiments — measured, and why feeding is harder than it looks (2026-07-25)

Method: a bare-metal test blob (`scratchpad/ubootblob/feedblob_*.c`, sharing the low-level half
of `atbm_wdt.c`) XMODEM-loaded with `loadx 0x80600000` and started with `go`. It deliberately
does **no** enumeration and **no** wake, reusing the link the console-entry hook already brought
up, so it isolates one question: can U-Boot keep the watchdog fed?

| Run | What the blob did | Reset (after power-on) | Where it died |
|---|---|---|---|
| baseline | nothing (idle at the prompt) | **56.2 s** | — |
| A | 10 × inject `0x13`, 5 s apart, no RX drain | **65.5 s** | after feed #10 |
| B | same, with real status printed | **74.1 s** | **hung on inject #4** |
| C | inject + drain RX (buffer id starting at 1) | **19.3 s** | **hung inside the FIRST read** |

What this establishes [LIVE]:

* **Injects land without re-enumerating.** `cmd53_block()` to the force-bit TX address returned 0
  every time from a blob that never issued CMD0. This validates the planned `link_ready` split:
  bring the link up once, then only inject.
* **Feeding does move the deadline** (56 s → 65 s → 74 s), so the reset is at least partly tied to
  host activity rather than being a pure power-on timer.
* **But inject-only feeding wedges the link.** Every `0x13` makes the device queue a `0x043A`
  confirm. Nothing drained them and `HIF_CONTROL` read **`0x3100`** on every tick — bits 12/13 are
  WUP|CONT_RDY and the low bits are the pending-RX length (`nl = ((ctl & 0x0FFF) |
  ((ctl & 0xC000) >> 2)) * 2` = **512 bytes waiting**). Inject #4 then hung for ~50 s and the MCU
  reset the SoC.
* **Naively draining wedges it even faster.** Run C hung inside its very first
  `cmd53_block()` read and died 6 s later. The console-entry hook's own read works, and the
  difference is the **rotating HIF RX buffer id**: the hook consumed one frame with `bid=1` so the
  next expected id is 2, while the blob asked for 1 again. The host must track the device's
  expected buffer id (and, on the WSM level, the rx sequence — the same class of bug as the
  driver-side rx-seq desync in §3.2).

**Verdict [LIVE]: a correct U-Boot feed is not a one-liner.** It needs the HIF queue bookkeeping
(buffer-id rotation + a drained RX path), i.e. a small port of the driver's bottom-half logic —
not just a periodic `m3_frame()`. Before investing in that, note that **the chunked flash design
does not need feeding at all**: a 1 MB chunk takes ~10 s, which fits in the ~44 s that remain at
the prompt, and each `reset` starts a fresh window (§8.2, and the `au_os` env in the camera
config). Linux-side updates have no watchdog constraint whatsoever, because the running driver
already does all of this bookkeeping correctly — proven by a 10 h soak.

**Unexplained contradiction [TBC]:** in one run the XMODEM transfer did not complete, `go` never
ran, and the CPU wedged inside U-Boot's `loadx` (the console answered neither CR nor `version`).
It then survived **200 s with no reset**. A wedged CPU cannot feed anything, so a pure
elapsed-time deadline should have fired at ~56 s. So the ~56 s reset condition probably depends
on SDIO/HIF state, not only on time. Do not treat ~56 s as a simple timer until this is resolved.

### 7.3c Feeding WORKS and triples the window — and exactly where it stops (2026-07-25)

**A prerequisite discovered the hard way:** the power button does **not** reset the ATBM6441. The
Z7682 is always powered (it *is* the power controller), so an SoC power-button cycle leaves the
module's HIF queue, buffer-id rotation and WSM sequence state intact. Leftovers from one test
therefore poison the next, which is why an earlier series appeared to degrade (10 → 3 → 0 feeds).
**Every watchdog measurement must start from a real power cut** (pull the USB), not a button
off/on. Runs before this was understood should be treated as unreliable.

With that method fixed, and a blob that reuses the console hook's link (no CMD0), drains RX with
the **correct continuing buffer id** (the hook consumed `bid=1`, so the blob starts at `bid=2`):

| Run | Feed detail | Result |
|---|---|---|
| baseline | no feeding | reset **56.2 s** after power-on |
| D | inject `0x13` + drain, same WSM seq every frame | **31 feeds, reset 171.4 s** |
| E | same, but incrementing the WSM tx sequence | **25 feeds, reset 139.8 s** |

* **Feeding from U-Boot works: the window goes from ~56 s to ~140–170 s (about 3×).** [LIVE]
* **`bid=2` was the fix for draining.** With the right rotation each read returned `rc=0` and the
  queue went back to empty (`ctl=0x3000`, `nl=0`); the first drained frame was even an event
  indication (`id=0x0805`) left over from bring-up. The earlier "draining wedges the link" result
  was purely a wrong starting buffer id. [LIVE]
* **The WSM tx sequence is NOT the limiter.** Incrementing it (id bits 13-15, as the confirm's
  `0xc43a` shows) changed nothing — 4 responses either way. [LIVE]
* **Where it stops: the device answers exactly 4 injects, then goes silent** (`drained=0`,
  `nl=0` forever) and resets us ~2 min later. That count matches the device's **input-buffer
  credits**: the driver tracks `hw_bufs_free = wsm_caps.numInpChBufs - hw_bufs_used`, charges one
  per TX (`++hw_bufs_used`, bh_sdio.c:670) and releases one only when a confirm arrives
  (`wsm_release_tx_buffer()`, bh_sdio.c:120/341/344/502) — while it rotates `buf_id_tx` per frame.
  Our blob always writes buffer id 0 with the force bit (address `0x28`). So the remaining work is
  **TX buffer-id rotation plus credit accounting**, not anything mysterious. [STRONG_INFERENCE]
* Note the fragility if anyone implements that: `numInpChBufs` normally comes from `STARTUP_IND`,
  which U-Boot never receives, so the credit count would have to be assumed (4 by observation).

**Practical conclusion — this is already enough for field work.** ~140–170 s comfortably covers a
4.5 MB rootfs write (~41 s at the measured ~179 KB/s) or even all of kernel+rootfs (5.9 MB, ~55 s)
in a single pass, and the committed chunked `au_os` (1 MB ≈ 10 s per boot) needs no feeding at all.
Implementing full credit accounting would buy an *unbounded* window; it is a bounded, well-located
task (bh_sdio.c) but not required for a trustworthy flash.

### 7.3d The actual bug in our feeder, and two more ruled-out ideas (2026-07-25)

Continued experiments (each after a real power cut). Two more hypotheses died, and then a
re-read of the raw logs found the real defect — in our own code, not in the protocol.

| # | Change under test | Result |
|---|---|---|
| E | incrementing the WSM tx sequence (id bits 13-15) | reset 139.8 s — no effect |
| F | rotating the 6-bit TX `buf_id` per frame, as `hwio_sdio.c:344-355` does | reset 139.7 s — no effect |
| G | the vendor's real host-alive frame, WSM `0x003C` `{status, 1212, period=600, tmo_cnt=2}` | reset 108.6 s — no effect |
| H | full WSM startup handshake: halt+restart the WiFi core via `CONFIG` `CPU_RESET` | **kills the link**, see below |

**H, the STARTUP_IND handshake, does NOT work from U-Boot [LIVE].** The driver restarts the WiFi
CPU on every module load and that is what makes the firmware emit `WSM_STARTUP_IND (0x0801)`
carrying `numInpChBufs` (`atbm_before_load_firmware` sets `CONFIG |= CPU_RESET|ACCESS_MODE`,
hwio_sdio.c:1105; `atbm_after_load_firmware` then `|= IRQ_RDY(BIT16|BIT17)`, `&= ~CPU_RESET`
— comment *"clear cpu reset, cpu will run"* — `&= ~CLEAR_INT`, hwio_sdio.c:1216-1220; `main.c:624`
waits for `firmwareReady`, set only by `wsm_startup_indication()`; the count is the first u16 of
the body, wsm.c:617). Reproducing that sequence from U-Boot writes cleanly (`CONFIG` went
`0x04001200` → `0x04031200`, IRQ_RDY set) but **no indication ever arrives and the board resets
~6 s later** — the same signature as issuing a second link-up. Restarting the WiFi core from
U-Boot leaves it dead, presumably because on HERA the image sits in TCM and only the driver's
full sequence brings it up from its entry point. So a fresh credit count is not obtainable here.

**THE REAL DEFECT (found by re-reading the logs, not by theorising) [VERIFIED in our own code]:
every HIF output-queue read we ever issued was 256 bytes short.** `HIF_CONTROL` reported `0x3100`
on every read, i.e. `next_len = 512`; the driver-correct transfer is `round_up(512+2, 256) = 768`.
But both readers clamped it:

```c
alloc = (nl + 2 + 255) & ~255u;  if (alloc > 512) alloc = 512;   /* WRONG */
static u8 b[512];
```
(`atbm_wdt.c` `m3_read_confirm()` and the test blob's `drain_rx()`.)

The tell-tale was in the logs all along and was missed: reads #2, #3 and #4 returned
**`id=0x00000000`** while `HIF_CONTROL` still claimed 512 bytes pending — the stream was already
desynchronised immediately after the FIRST short read. Four short reads leave four output buffers
un-released, and the output ring is exactly 4 deep (`buf_id_rx & 3`, read id = `buf_id_rx + 1`,
i.e. 1..4 — the only "4" in this protocol), after which the device goes permanently silent. That
also explains why TX never looked broken: every inject returned `rc = 0` and the reset still moved
out to 139-171 s. **The limit correlated with READS, not injects** — and the pre-drain read, which
happens before any inject at all, is one of the four.

Confidence: the buffer-release semantics live in firmware we do not have, so this is a strong
INFERENCE rather than a proof — but it is the only explanation consistent with all of: correct
rx-id phase, `id=0` on reads 2-4, TX still succeeding, and the count being exactly 4.

**…but fixing it did NOT help either [LIVE].** Tested in isolation (full-length reads, 2048 B
buffer, no handshake): reset at **55.9 s** — i.e. exactly the do-nothing baseline — and the reads
*still* returned `id=0x00000000`. So the short read was a genuine defect worth fixing, but it is
not what limits the feed.

### 7.3e Bottom line after nine experiments: we could not make the feed sustainable [LIVE]

| Variant | Reset, after power-on |
|---|---|
| idle, no feeding (baseline) | 56.2 s |
| full-length RX reads, isolated | **55.9 s** |
| inject `0x13`, no drain | 65.5 / 74.1 s |
| inject `0x13` + drain (simplest working blob) | **171.4 s** |
| + WSM tx-sequence increment | 139.8 s |
| + rotating 6-bit TX `buf_id` | 139.7 s |
| vendor host-alive frame WSM `0x003C` | 108.6 s |
| WSM startup handshake (CPU_RESET restart) | 19.8 s (kills the link) |

**The results do not correlate with protocol correctness.** The best result came from the
*simplest* blob and every subsequent "more correct" variant did the same or worse; the spread
(56–171 s) tracks something we are not controlling. The reasonable reading is that SDIO bus
activity perturbs the deadline, and that none of our frames are being accepted as a keepalive —
consistent with the device never having granted us credits (no STARTUP_IND, and no way to obtain
one from U-Boot, per H above).

**Engineering conclusion: do not build the bootloader around a feed.** Make every flash operation
fit the window that is guaranteed without one. A 1 MB chunk is ~10 s against a 56 s floor, and
`reset` between chunks restarts the window — that is the committed `au_os` design, and it depends
on none of the unknowns above. Linux remains unaffected (10 h soak, one `0x13` at boot).

Anything further here should start by explaining the 56→171 s spread, because until that is
understood no feed result is interpretable.

### 7.4 Hard-won operational rules [LIVE]

* **A second `atbm wdt off` right after the first is FATAL — reset ~6 s later.** The second call
  prints `CONTROL=0x00003100` instead of `0x00003000`: it re-runs the whole link-up (MSC1 reset
  + enumeration) on an already-up link and wedges it. **Any U-Boot feed must be inject-only:**
  `atbm_link_up()` exactly once, then bare `m3_frame()` pokes. Never loop the existing command.
* Therefore the recipe `setenv f 'atbm wdt off; sleep 5; run f'` is **not** a valid feed test —
  it kills the board instead of measuring anything.
* `atbm wdt off` costs **~11.8 s** of the window, leaving only ~44 s at the prompt.
* In Linux the problem does not exist: one `0x13` at boot plus the running driver is enough
  (10 h proven). **Flashing from Linux has no watchdog constraint** — that is the preferred
  field-update path.
* Idle Linux shows one SDIO RX interrupt every **~28.6 s** (IRQ 44: +1176 over 33 614 s), i.e.
  something periodic exists on the link. Its identity is [TBC] and it may or may not be what
  keeps mechanism B satisfied.

### 7.5 U-Boot feeding infrastructure (design, not yet built)

U-Boot 2026.07 already has everything needed; `wdt_start()` itself registers the servicing
cyclic when `CONFIG_WATCHDOG` is on:
```c
/* drivers/watchdog/wdt-uclass.c, wdt_start() */
if (IS_ENABLED(CONFIG_WATCHDOG))
        cyclic_register(&priv->cyclic, wdt_cyclic, priv->reset_period * 1000, dev->name);
```
And `schedule()` (which runs cyclics) is called **inside the flash loops**:
`drivers/mtd/spi/spi-nor-core.c:1131` is the first statement of the per-erase-sector loop and
`:2006` of the per-page write loop; with 4 KiB sectors at the measured ~179 KB/s that is a feed
roughly every 23 ms during erase. So a `UCLASS_WDT` driver whose `.reset` injects the MCU frame
gets serviced automatically, including during a long `sf erase`. [LIVE — read in our build tree]

Two cautions: **do not** enable `CONFIG_WATCHDOG_AUTOSTART` (it would also arm the SoC TCU
watchdog, since `initr_watchdog()` walks every WDT device) — call `wdt_start()` on our device
explicitly instead; and be aware `CONFIG_SYSRESET_WATCHDOG_AUTO=y` binds a `wdt_reboot`
sysreset child per WDT device, and `sysreset_walk()` takes the first `-EINPROGRESS` in bind
order, so a new WDT device could hijack `reset` [TBC — check on first boot; trivial fallback is
`.expire_now` returning `-ENOSYS`].

**Gap in `spi_nor_wait_till_ready_with_timeout()`** (`spi-nor-core.c:892-911`): its poll loop
has **no** `schedule()`. Harmless per 4 KiB sector, but fatal for a whole-chip erase — see §11.

---

## 8. Flash layout

### 8.1 Vendor (stock) [RE]

```
boot     0x000000-0x040000  (256K)  Ingenic SPL + U-Boot
tag      0x040000-0x098000  (352K)  plaintext bootargs (CMDL) + ENVI + USR0 config, 2 copies
                                    at 0x42000 and 0x49000; no checksum; UNSIGNED
kernel   0x098000-0x318000  (2560K) uImage "Linux-3.10.14-Archon"
rootfs   0x318000-0x818000  (5M)    Zeratul RTOS app (custom format)
recovery 0x818000-0xA98000  (2560K) uImage "Linux-3.10.14-Immortal" + initramfs
common   0xA98000-0xB40000  (672K)  squashfs: curl + libcurl/mbedtls
system   0xB40000-0xF40000  (4M)    squashfs: ajcloud, mcu_test, sounds, mcu_fw
config   0xF40000-0x1000000 (768K)  jffs2: IBT_Profiles.ini, P2P creds, alarm.info
```
Vendor bootargs: `console=ttyS1,115200n8 mem=46M@0x0 rmem=18M@0x2E00000 root=/dev/ram0 rw
rdinit=/linuxrc mtdparts=jz_sfc:... lpj=6955008 quiet`.

### 8.2 Thingino (ours) [LIVE]

As currently flashed:
```
mtd0 boot   0x000000-0x050000   320K
mtd1 env    0x050000-0x060000    64K   single sector, CONFIG_ENV_REDUNDANT is NOT set
mtd2 kernel 0x060000-0x1C0000  1408K
mtd3 rootfs 0x1C0000-0x630000  4544K
mtd4 data   0x630000-0x1000000 10048K  jffs2 -> /overlay (overlayfs upper over /rom squashfs)
mtd5 all    0x000000-0x1000000   16M
```
**Partition sizes are computed per build from the actual rootfs size**, so they move between
builds. A freshly built image had `rootfs 4608k` / `data @0x640000` while the flashed unit had
`4544k` / `0x630000`, and the new `rootfs.squashfs` (4 665 344 B) does **not fit** the old
4 653 056 B partition. **Consequence: flashing kernel+rootfs without also updating the env
(which carries `mtdparts`) truncates the rootfs and the camera will not mount root.** [LIVE]

`/rom` is the squashfs, `/overlay` is mtd4 jffs2, `/` is the overlayfs union — so a file dropped
into `/overlay/...` **shadows** the flashed rootfs and survives a rootfs reflash. Remember to
clear overrides after flashing. [LIVE]

**Factory reset = wipe mtd4 (`data`/overlay).** The clean U-Boot's RST-hold-10s gesture runs
`overlay_wipe` (chunked `sf erase` of the `data` partition); a running Linux does it reliably with
`flash_erase /dev/mtd4 0 0`. Because the offset is size-fragile (above), the hardcoded
`overlay_wipe` offset is only correct when the **full image is flashed together** (U-Boot env +
kernel + rootfs consistent). See [`atbm6441-re/uboot-clean-recovery.md`](atbm6441-re/uboot-clean-recovery.md)
for the clean-bootloader design, the AP-SSID ownership fix (the "s2" AP was a U-Boot artifact —
Linux owns the name via `atbm_softap`), and the on-hardware verify checklist. [2026-07-27]

---

## 9. Imaging, day/night, audio

* Sensor OS02G10 on i2c0 `0x3c`; thingino modules `tx_isp_t23` + `sensor_os02g10_t23`. [LIVE]
* **Day/night switching is SOFTWARE, not a photo sensor.** The vendor `ThreadSoftPhotosens`
  reads `IMP_ISP_Tuning_GetAeLuma` and compares against `night_ev`/`day_ev` thresholds, then
  flips gpio58/64 (IR-cut) and gpio62 (IR LED). `/dev/jz_adc_aux_0` (SADC AUX0) reads a flat
  ~44 and does **not** track light — it is *not* a light sensor. For thingino: use the standard
  AE/gain autonight, no photo-resistor integration. [LIVE]
* Factory tuning values: `night_ev=128890`, `day_ev=11000`, `day_rgain=237`, `day_bgain=196`.
  Audio: `mic_gain=25`, `mic_vol=75`, `spk_gain=28`. Floodlight present (`flt=1`,
  `flt_bright=1`). [RE]
* **Never `cat > /dev/dsp`** — it hangs the shell in D-state; audio needs IMP init first. [LIVE]

---

## 10. Buttons and the power domain

**Two physical buttons, both on the Z7682 MCU, neither is a T23 GPIO** [LIVE]:

* **Power** — MCU-autonomous. Manual: hold ~6 s = power on, ~5 s = power off. Because the T23
  is fully off when the camera is off, power-on must be owned by the always-on MCU.
* **RST** — short press = wake; hold ~6 s = factory reset (settings) in stock firmware. This is
  the one we forward to Linux (§5).

Evidence they are not SoC GPIOs: the `gpio-keys` input device is a stub (`EV=1`, no `EV_KEY`,
no keys in the DT), and a debounced compare of every GPIO PIN register
(`PA=0x10010000 PB=0x10011000 PC=0x10012000`, `+0x00` = PXPIN) shows no stable bit change on a
press. **Trap:** an early compare "found" PB4/PB8 changing — those oscillate constantly from
live SDIO traffic (PB8 is an MSC1 pin) and had nothing to do with the button. [LIVE]

---

## 11. Known footguns

1. **`sf erase 0 <full-chip-size>` in U-Boot is a brick.** When `len == mtd->size` U-Boot takes
   the `spi_nor_erase_chip()` branch (0xC7), whose status poll has **no `schedule()`** and runs
   up to 320 s. The MCU resets the SoC mid-erase with the chip **already blank** — programmer-only
   recovery. Always split the erase so the length never equals the chip size. [LIVE/RE]
2. **Any single `sf erase` larger than ~5 MB overruns the window** (~179 KB/s measured), leaving
   a half-erased kernel/rootfs. Flash in ~1 MB chunks with a `reset` between them. [LIVE]
3. **Never erase `0x0..0x60000` (boot+env) in the field.** Then every interruption is retryable.
4. **The vendor recovery-OTA can wipe the flash.** U-Boot counts boot failures
   (`Recovery mode. goto normal boot. count > 10.`); enough interrupted boots select the
   recovery kernel, whose `app_init.sh` → `net_upgrade.sh` fetches
   `http://fw.ajcloud.net/<ver>/latest.bin` and runs `upgrade`, which `flash_eraseall`s the
   firmware partitions before writing. We interrupted that once and ended up with a blank
   0x0–0xF40000 (config spared). **Neuter this path; never leave the board reboot-looping.** [LIVE]
5. **`reboot` from full Linux hangs** on atbm teardown — use `echo b > /proc/sysrq-trigger`.
   And a warm reboot leaves the MCU/WSM in a state where WSM startup can hang
   (`mdelay wait wsm_startup_done`) — **module changes need a COLD power cycle**. [LIVE]
6. **Do not `rmmod` the atbm driver** — it hangs in D-state. [LIVE]
7. **SoftAP needs BOTH planes; the beacon-start is an MCU command.** [CORRECTED 2026-07-31 — see
   §4.3] Configure the SSID/channel over the WiFi-core (`atbm_softap`: WSM `0x000D`
   set_wifimode=AP → `0x000E` ap_cfg, in that order — `0x000E` without `0x000D` hangs), THEN
   start the beacon over the MCU with `mcu_test --wifi_start_ap="<ssid>"` (msg `0x40`, **SSID as
   payload**). The earlier "route AP through MCU opcode 12" advice was wrong twice over: opcode 12
   doesn't exist, and a payload-less send leaves the SSID empty (aborts the bring-up). The
   resident firmware *is* the hostapd — do not run upstream hostapd. [LIVE]
8. **Autoboot is only ~2 s** (`Hit any key to stop autoboot: 1` → `0`) — a serial catcher must
   trigger on the boot banner, not on a wall-clock guess. [LIVE]

---

## 12. Open questions ([TBC] register)

| # | Question | Why it matters |
|---|---|---|
| 1 | ~~power-on/last-contact? what fires at 56 s?~~ **ANSWERED (§14.4):** it is the lp_mgr `master_wdt` host-alive timer; the host kicks it with msg_id 0x15 or disables it with 0x12/0x13. | Was the whole U-Boot feed question |
| 2 | Does a **properly-framed** msg_id 0x13 (DELETE master_wdt) sent from the T23 actually stop the ~56 s reset? Our earlier U-Boot 0x13 did not — likely a malformed message_mgr frame dropped on CRC. | Confirms the clean bootloader fix vs bounded-chunk fallback |
| 3 | ~~Does an inject-only feed extend the window?~~ **ANSWERED (§7.3b/c):** yes, ~3x, once RX is drained with the correct rotating buffer id. Stops after 4 injects for lack of TX buffer-credit accounting. | The whole U-Boot feed design |
| 4 | What is the ~28.6 s periodic SDIO RX in idle Linux? | May be the thing that satisfies mechanism B |
| 5 | Can `wdt_set_period` (0x14) be given a very long period, or 0/0xFFFFFFFF for "never"? | Would be a clean one-shot fix |
| 6 | Does a long `check_alive` period set from Linux persist across an SoC reset into U-Boot? | Would make U-Boot windows irrelevant |
| 7 | Does adding a `UCLASS_WDT` device hijack `reset` via `SYSRESET_WATCHDOG_AUTO`? | Chunked flashing depends on `reset` |
| 8 | Is a button press held through power-on latched by the MCU, or dropped? (`seg2.dec` has `sdio not init but use sdio tx event,event drop`) | Boot-time recovery trigger UX |
| 9 | Does WiFi **STA** work at all on our source-built gtxaspec driver (`CONFIG_MAC80211=y`)? | Gates any LAN-based update path |
| 10 | Is the microSD slot reachable without opening the case? | Decides whether the SD `stop.txt` recovery trigger is enough and the button is optional |
| 11 | Does the Z7682 boot ROM validate the `mcu_fw.bin` footer checksums? | Whether MCU firmware can be repacked |
| 12 | ISA is NDS32 (§14.1) - deep-firmware convenience only | Only needed for deep firmware work |
| 13 | Exact CRC algorithm at `message_mgr` fn `0xaa4b4` (host must reproduce it over the payload or the command is dropped). Linux vendor-driver framing already passes it. | Needed to send master_wdt commands from bare-metal U-Boot |
| 14 | Does `master_mode=0` (msg_id 0x2b) persist across reboot and permanently stop the host-alive reboot? `gp+0x20fc` is read-only in the app image. | Cleanest one-shot fix for a mains-powered cam |
| 15 | ~~WSM read-register/peek command for RST?~~ **ANSWERED (§14.6): NO** - the message_mgr command set has no arbitrary-memory-read handler (the `rmem` strings are AT-console-only). RST (ATBM gpio17) is reachable from the T23 ONLY via the eventId-16 indication, so a U-Boot RST poll would need the event plane up, not a single register read. | RST-button-at-boot is event-plane-only |

---

## 13. How to verify things yourself

**Serial console:** ttyS1, 115200 8N1, DTR/RTS asserted. Login `root`. A fresh flash resets the
password to `root`/`root` with a forced change.

**On the camera (Linux):**
```sh
cat /proc/mtd                       # partition layout actually in use
cat /sys/kernel/debug/gpio          # claimed GPIOs (mount -t debugfs none /sys/kernel/debug first)
grep -E '^ *4[45]:' /proc/interrupts # 44 = ATBM SDIO, 45 = SD slot
mcu_test --version ; mcu_test --get_battery_status
mcu_evt &                           # then press RST / wave at the PIR
dmesg | grep -iE 'atbm|mcuevt|rxseq'
```

**From U-Boot:**
```
atbm wdt off            # MCU opcode 0x13 (the recovery-critical one)
atbm mcu 24             # raw opcode, HEX here (0x24 = 36 = version)
printenv                # au_os / au_stop / WDT_DISABLE / mtdparts
```

**Source of truth for the driver:** `package/all-patches/wifi-atbm6441/0100-cinnado-s2-t23zn-atbm6441-compat.patch`
over gtxaspec `atbm6441` @ `8cf3606`. U-Boot MCU code:
`package/all-patches/uboot/2026.07/0002-cmd-atbm-wdt.patch` →
`board/ingenic/isvp-t23/atbm_wdt.c`.

**Reverse-engineering material** (paths as used during this port): vendor flash `dump.bin`
(16 MB), `extracted/` (unsquashfs of the vendor `system`/`common`), `extracted/lp_mgr`,
`extracted/librtos.so`, `extracted/system/bin/mcu_test`,
`extracted/system/mcu_fw/{mcu_fw.bin,seg1.dec,seg2.dec}` (seg2 is the interesting one —
`grep -a` it for strings), and the stock driver `atbm6041_wifi_sdio.ko`.

## 14. ATBM6441 firmware — full dump and static analysis (2026-07-25) [RE/LIVE]

The ATBM6441 has its **own UART** (separate from the T23 console). On this board it exposes an
interactive **AT command console** at 115200 8N1. Two of its commands — `AT+rmem` (read any
address) and `AT+wmem` (write any address) — gave us the whole internal firmware. This section is
the result. **The soldered ATBM UART is a lab instrument for THIS one camera; it is not a
deployment channel. Everything that must ship has a T23-side (SDIO) path, called out below.**

### 14.1 How the image was obtained [LIVE]

* Console: `AT+HELP` lists ~180 commands. `AT+DEFAULT_DEBUG_ENABLE=0` mutes async printk so it
  cannot corrupt a hexdump.
* `AT+rmem=<addr_hex>,<len_dec>` dumps memory, little-endian words, **max 160 B/reply** — but a
  reply longer than 8 lines overruns the chip's UART TX buffer and corrupts bytes, so use
  **128 B chunks** (measured 0/40 corrupt at 128 vs 14/40 at 160).
* The SPI-NOR of the ATBM is memory-mapped (XIP) at **`0x400000–0x5FFFFF` (2 MB)**. A resumable
  128-B dumper (`scratchpad/at_dump2.ps1`) pulled all 2 MB in ~18 min at ~2 kB/s; verified by
  re-reading 48 random chunks (48/48) and by a second independent dump being byte-identical.
  `atbm_flash2.bin`, md5 `5e9e017e915eea70cf816c8b49b34a82`.
* Firmware is **unencrypted** (`no-enc` in the boot banner). Architecture is **Andes NDS32
  (little-endian)** — proven by the exception handler printing `IVB/PSW/IPSW/EDMSW/ITYPE`.
  No off-the-shelf disassembler supports it (not radare2, not capstone); we built
  **`nds32le-elf-objdump` from binutils-2.38 source** (`--target=nds32le-elf`).

### 14.2 Flash and runtime address model [RE]

| Flash (XIP window) | Content |
|---|---|
| `0x400000` | image header: magics `0x0000ab45 0x0000ab47`, then `img1@0x401000 len 0xaf00`, `img2@0x560000 len 0xaf00` = the two ~44 KB **bootloader** copies (A/B), `map 0x560000` |
| `0x400000–0x47ffff` | main application (bootloader front + app text + rodata/strings) |
| `0x480000–0x4fffff` | zeros |
| `0x558000–0x5affff` | second dense image (OTA/B copy) |

**Runtime link base:** the application is linked to run at a VMA where **`flash_addr = VMA +
0x380000`** (recovered by brute-forcing the offset that makes 3542 reconstructed `sethi/ori`
pointers land exactly on string addresses). So to disassemble the app correctly:
```
nds32le-elf-objdump -D -b binary -m nds32 -EL --adjust-vma=0x80000 atbm_flash2.bin
```
(the bootloader front is a separate blob that runs XIP at VMA `0x400000`, and there is an
in-ROM helper region based at `0x1400000` not present in the dump). Tooling used:
`scratchpad/nds32_analyze2.py` → `atbm_annotated.txt` (full annotated disasm, every constant
load resolved to its string/MMIO), `atbm_xref.txt`, `atbm_mmio.txt`.

### 14.3 The message_mgr command interface — THE T23 control surface [RE, CONFIRMED]

The T23 host controls the ATBM by posting fixed-layout messages to the `message_mgr` task over
SDIO/WSM. **This is the same interface as our reversed "MCU command protocol".** Dispatcher at
VMA `0xaa956`.

**Wire format** (each field a 32-bit word):
```
word0 = header
word1 = msg_id           <-- the command selector
word2 = crc              <-- CRC over the payload; message_mgr recomputes (fn 0xaa4b4) and
word3 = length                DROPS the frame silently on mismatch ("crc(%x) error")
payload @ byte 0x10
```
Dispatch: `index = msg_id - 1`, range `1..0x45`, jump table at `0xaa9d4`; out of range →
`unsupported msg_id:0x%x`. A subset of commands translate into an **internal event**
`0x1001..0x1032` consumed by a second dispatcher at `0xab15c` (table `0xab184`).

**msg_id map (authoritative, from the jump table):**

| msg_id | action |
|---|---|
| 0x01 | post internal event 0x1003 |
| 0x02 / 0x04 / 0x3f | network / P2P send (ip, port, did, payload) |
| 0x05 | cloud connect (ip, port, did, mode, code) |
| 0x09 / 0x0a | **PIR enable / disable** |
| 0x0b | PIR cooldown timer |
| **0x12 (18)** | **STOP master_wdt (host-alive) timer** — no payload |
| **0x13 (19)** | **DELETE master_wdt timer** — no payload |
| **0x14 (20)** | **SET-PERIOD + START master_wdt** — payload word0 = period **seconds** (×1000 ms) |
| **0x15 (21)** | **RESTART / KICK master_wdt** — the periodic keepalive |
| 0x16 / 0x17 | set_mcu_alarm / _b |
| 0x23 (35) | get version (`1.2.5u1`) |
| **0x2b (43)** | **set master_mode** — payload word0 ∈ {0,1}; → internal 0x1017 → setter `0xdc638` writes WSM-context byte[0x99] and pushes it to MAC firmware |
| 0x34 | MCU factory reset |
| 0x37 / 0x38 | wifi stop / set static IP |
| 0x39 / 0x3a | get / set wifi DCXO |
| 0x3b | set RTC mode |
| 0x3d / 0x3e / 0x45 | set / get battery params |
| 0x40 / 0x41 | wifi start_ap / stop_ap |

(msg_id 0x11 is explicitly *unsupported* — the wdt family starts at 0x12.)

This cross-checks our older reversed catalog: `pir=9/10` ✓, `wdt family 18–21` ✓. **Note the
numbering is the message_mgr msg_id, and message_mgr CRC-checks the payload before dispatch** —
a frame with a wrong/absent CRC is dropped without error. Our working Linux GETs (version,
battery) prove the vendor-driver framing (with correct CRC) is accepted; a hand-rolled U-Boot
frame must reproduce the CRC (fn `0xaa4b4`, not yet byte-reversed) or it is ignored.

> **DEFINITIVE ANSWER in §14.4c below: the ~56 s reset is an ATBM WiFi-scan CRASH, not any watchdog.** 14.4/14.4b remain valid (they rule out the master_wdt and give the CRC), but 14.4c is the actual mechanism.

### 14.4 The master_wdt is DORMANT — it is NOT the ~56 s reset [LIVE 2026-07-25, CORRECTS an earlier claim]

An earlier version of this section claimed the ~56 s idle-U-Boot reset **is** the lp_mgr
`master_wdt` and is stopped by msg_id 0x13. **Live inspection of the running chip disproves that.**

The ATBM *is* the SoC power-master and it *does* contain a `master_wdt` timer (object at
`0x809298`, callback `master_wdt_timer_cb` @VMA `0xa9ffe`, handle at `gp+0x202c = 0x8099ac`).
But that timer is **created dormant** and only armed when the host sends msg_id `0x14`
(SET-PERIOD, payload = seconds). Evidence it is dormant in our setup:

* The timer object at `0x809298` is **byte-for-byte identical across repeated reads seconds
  apart** — it is not counting and not in the active list (`xTimerListItem.xItemValue` = 0).
* Decisive logic: if it were armed, the host would have to feed it (msg_id `0x15`) or be rebooted
  at its period. Our Thingino driver never sends `0x14`/`0x15`, yet **Linux runs for hours with
  zero resets** (10 h soak). An armed-and-unfed timer cannot coexist with that. Therefore it is
  dormant.

So the `master_wdt` is a **vendor power-management feature** (arm it so the WiFi chip duty-cycles
the main SoC on a battery product). On our mains-powered board nothing arms it. Consequences:

* **msg_id 0x13 (DELETE master_wdt) does NOT stop the ~56 s reset** — it deletes a dormant timer.
  This explains §7.3: the U-Boot `0x13` was a *valid, accepted* frame (its `0xFFFFFFFF` is the
  correct CRC of an empty payload, see §14.4b) yet the reset still fired — because `0x13` was
  never the lever.
* The reboot *path* (`master_power_off` → `host alive failed... reboot two devices` →
  `HI_SDIO_Host_Reboot`, VMA `0xaa1c4`/`0xa87d0`/`0xa9560`) is real and is the **master-power
  state machine**, but it is driven by lp_mgr **events**, not by the dormant timer.

**What the ~56 s reset actually is: still open, but bounded.** It is SDIO-activity related — §7.3b/c
showed that injecting SDIO traffic from U-Boot pushes the deadline out (56 s → ~170 s), so it is a
**host-alive / SDIO-keepalive** mechanism, not a fixed power-on timer. It is NOT the app-level
`master_wdt`, and it is NOT reached by the message_mgr msg_ids reversed here. The most likely home
is a lower layer (the ATHENA_BX MAC firmware or the HIF block) that is **not in this 2 MB XIP
dump**. Do not claim it is solved.

**Engineering consequence (unchanged and now better-justified):** build the bootloader around
**bounded-time flash** (`au_os`, each `sf` op < the ~56 s floor, `reset` between chunks) — it needs
no ATBM cooperation and is immune to whatever the real mechanism is. A sustainable U-Boot feed was
not achievable (§7.3e). The one thing that *did* change: we can now build byte-correct SDIO command
frames from U-Boot (§14.4b), so any future host-side control that turns out to help is craftable.

**Candidates for the real mechanism (for a future session):** the reboot is issued by the
master-power state machine (`master_power_off` @0xaa1d4 -> `host alive failed` @0xa87d0), so
something posts a master event when SDIO goes quiet. The `LMAC_WDT`/`HMAC_WDT`/`CUSTOMER_WDT`
"restart CPU" watchdogs in this image restart the *ATBM* core (not the T23) so are probably a
separate concern. The next step is to dump the running MAC-firmware RAM over `AT+rmem` and look
for the SDIO-idle host-alive timer there.

### 14.4b Message framing and the CRC — fully reversed, reproducible [LIVE + RE, CONFIRMED]

Every message_mgr command is a **532-byte packet** (`memset 0x214` in the dispatcher `0xaa956`):

```
offset 0x00  u32  header / magic (0xACACCACA on the general-cmd path)
offset 0x04  u32  msg_id            (the command selector; dispatch table §14.3)
offset 0x08  u32  crc               (checked BEFORE dispatch; mismatch -> silently dropped)
offset 0x0c  u32  length            (byte length of the payload, used by the CRC)
offset 0x10  ...  payload[ ]        (up to 512 B)
```

The dispatcher computes `crc = crc32(payload@0x10, length@0x0c)` (fn `0xaa4b4`) and requires it to
equal `word[2]`; otherwise it prints `crc(%x) error` and drops the frame.

**The CRC is the standard reflected CRC-32** (the zlib/PKZIP one, poly `0xEDB88320`): the 256-entry
lookup table lives at `gp+0x2124 = 0x809aa4` and reads `00000000 77073096 EE0E612C 990951BA …`
(verified live). The routine is:

```c
uint32_t crc = 0xFFFFFFFF;                       /* init */
for (i = 0; i < length; i++)
    crc = table[(crc ^ payload[i]) & 0xFF] ^ (crc >> 8);
return crc;                                      /* NOTE: NO final XOR / inversion */
```

Two practical points:
* It is **not** finalised with `^ 0xFFFFFFFF`, so it is the raw LFSR value, not the usual zlib
  output. For an **empty payload it returns `0xFFFFFFFF`** — which is exactly the value the U-Boot
  `atbm wdt off` frame carried, i.e. that frame's CRC was correct all along.
* Our working Linux GETs (version, battery) pass this check, confirming the algorithm. Any U-Boot /
  bare-metal sender can now reproduce it with the standard CRC-32 table and no final inversion.

`gp = 0x807980` (proven by the CRC-table location; an earlier note had it wrong at `0x90052c8`).
Useful gp-relative globals: `g_master_wdt_timer @ gp+0x202c (0x8099ac)`,
`master_wdt period_ms @ gp-0x7968 (0x800018)`, `master_mode flag @ gp+0x20fc`,
`master power-state @ gp+0x2034`, `crc32 table @ gp+0x2124 (0x809aa4)`.

### 14.4c THE ~56 s reset, finally identified: an ATBM WiFi-scan CRASH [LIVE 2026-07-25, CORRECTS 14.4/7.3]

Every earlier theory (master_wdt, check_alive host-alive, HIF wdt) was wrong. We captured the
**ATBM's own debug console at the instant it resets the T23**, and the mechanism is an ATBM
firmware crash, not any watchdog on the host. Exact chain from the dual-console log:

```
ATBM boots STA mode with no valid AP (bssid=NULL ssid_len=0)
   ↓  repeatedly scans/reconnects: "sta_reconnect_config scan_cnt 2,3,…25" / "WiFi: connect failed"
~55 s  Assert LMACtoUMAC_ScanComplete ErrCode 3        ← firmware bug in the scan-complete path
   ↓  ERROR: OS_Exception 7 (General Exception, PC 0x3f6b6) — firmware wedges in the crash handler
~2 s   ERROR: OS_Exception 2019 / "Hardware WDT Exception"  ← the 0x16600000 wdt fires (no longer fed)
   ↓  "?flashstatus / bootloader.flashIotBoot"          ← the ATBM reboots ITSELF
   ↓  "######## WDT 1 0 / WDT reset OK"
   ↓  ATBM re-init: master_set_status(2) → "master_power_on."
   →  the T23 is power-cycled → "T23 TPL"
```

The T23 reset is **collateral damage from the ATBM crashing and rebooting** (the ATBM is the SoC
power-master, so its re-init power-cycles the host). One captured crash → exactly one T23 reset.

This finally explains every prior observation:
- **Idle U-Boot dies at ~56 s** — the ATBM scan-crashes on its own timeline; host state is irrelevant.
- **Linux "survives"** — a successful boot ends in **AP mode** (`thinginoAP` SoftAP); AP mode has no
  STA scan loop, so no assert, no crash.
- **"Feeding extended it" (§7.3)** — SDIO traffic perturbed the scan cadence, delaying the crash.
- **Neither master_wdt nor check_alive was armed** — correct, because neither was ever the cause.
- **It wasn't in the app disasm** — the crash PC `0x3f6b6` and the assert are in the **LMAC/MAC
  firmware** (runtime `0x30000`, from flash `0x410000`), outside the app link base (`0x80000`). The
  assert string `LMACtoUMAC_ScanComplete` is at `0xef500` and appears in the crash call-trace.

It is also a **field reliability risk**, not just a flashing nuisance: any camera whose configured
AP becomes unreachable will fall into the same STA-scan → ~56 s crash → reboot loop. And normal boot
is a **race** — Linux must reconfigure the ATBM (AP mode / stop scan) within ~55 s of ATBM power-up
or the ATBM crashes mid-boot and resets the T23 (observed: a slow first boot got reset at ~99 s).

### 14.4d Fixing it — T23-only [LIVE 2026-07-25]

Root cause = the ATBM auto-connecting STA on boot. What the live experiments established:

* **The boot STA-connect IS config-gated** — not truly hardcoded (the user was right to push on this).
  `fw_atbmwifi_init` calls the connect at `0xa3742`; the gate at `0xa385a` is
  `lbi $r1,[$r10+0x6b]; beqz38 $r1,skip` — if that config byte is 0, the STA connect is skipped
  entirely. But the persistent knob is **not reachable except via the ATBM UART (lab-only)**:
  - `AT+WIFI_SET_MODE=AP_MODE` is **runtime-only** — its "save" (`0xcdc8c`) writes RF register
    `0x16101030`, not flash. Live-proven: after setting it, the next boot still scanned STA.
  - `wifi_off` is battery-management-driven (`0xaa7fa`), not a user setting.
  - `WIFI_JOIN_AP_AUTO` takes an SSID (it *adds* an AP to join, doesn't disable joining).
  - The real config lives in ATBM NVRAM (sectors `0x500000`/`0x502000` = AP profile, IP
    `192.168.43.1`, `thinginoAP`, encrypted PSK; small items at `0x504000`/`0x505000`). The
    STA-profile slot (`+0x50`) is empty yet still triggers STA-connect. Writing this needs the ATBM
    UART or reversing the vendor SDIO provisioning-persist path — **not deployable as-is.**

* **The T23 already fixes NORMAL boot.** The Linux SoftAP bring-up (`atbm_softap.c` over
  `/dev/atbm_ioctl`: `CLEAR_WIFI_CFG`=nr36 → `WIFI_MODE=AP`=nr7 → `SET_COUNTRY` → `WIFI_CHANNEL` →
  `AP_CFG`) stops the STA scan at ~72 s — before the ~105 s crash. Live-confirmed: one boot, no
  crash. So the camera is already stable in normal operation via a **T23-side** action.

* **The only gap is idle U-Boot during a recovery flash** (no Linux → nothing stops the scan). The
  deployable, T23-only fix: **U-Boot sends the same stop-scan command over SDIO before the flash.**
  - `WIFI_MODE=AP` is the *proven* command (it stabilises every boot). It rides the WEXT/WSM path the
    driver uses (`/dev/atbm_ioctl` nr 7).
  - `msg_id 0x37` (`SPICMD_SET_WIFI_STOP` → internal `0x1023` → `0xace0c`) is the simpler message_mgr
    general-cmd path U-Boot can already frame (CRC reversed, §14.4b) — pending a check that it halts
    the STA scan, not just the AP.
  - Zero-ATBM-interaction fallback: **bounded-chunk flash** (`au_os`, each `sf` op < the ~56 s floor,
    `reset` between chunks). Immune to the crash, needs no SDIO from U-Boot.

**Bottom line:** the ~56 s reset is fully explained (ATBM scan-crash), normal boot is already stable
via the T23 driver, and the recovery-flash gap is closed T23-only by having U-Boot issue the
driver's proven stop-scan over SDIO (or by bounded-chunk flashing).

### 14.5 Hardware watchdog register map — `0x16600000` (startup WDT) [RE, CONFIRMED]

Key-protected: every control write must be immediately preceded by writing the key to `+0x18`.

| Register | Meaning |
|---|---|
| `0x16600018` | KEY / unlock ← `0x00005AA5` (before every protected write) |
| `0x16600010` | CONTROL, bit0 = enable (set = arm, clear = disable) |
| `0x16600014` | FEED ← `0x0000CAFE` (kick, after key) |
| `0x16600020 / 24` | timeout / prescaler reload |
| `0x16600028` | current count / status (read-only) |
| `0x16100080 ← 3`, `0x16100090` | WDT module clock gate |
| `0x1660001c` | software-reset trigger (magics `0x5AA5`/`0xCAFE`) |

In-blob driver at VMA `0xce44c–0xce57c`. To disable by raw poke: `0x16600018 ← 0x5AA5` then
`0x16600010 ← 0` (clears enable). **Live-read confirms this wdt is idle in normal operation**
(count `0x16600028 = 0`, control `0x03002001`, stable) — it only runs during the ~14.5 s startup
and is what WSM opcode `0x13`/the firmware turns off. **Caveat:** `0x16600000` is on the ATBM's
internal AHB, reachable from the T23 only through the SDIO→AHB direct-access window (the same
bridge firmware-download uses); it is NOT a plain SDIO-addressable register.

### 14.6 ATBM GPIO controller — `0x16800000` — and the RST button [RE, CONFIRMED + LIVE]

The ATBM has its own GPIO controller, **internal to the NDS32 core, not visible on the SDIO bus**.
Pin number = bit index in each 32-bit register. HAL at `0xcee30–0xcf05e`.

| Register | Meaning |
|---|---|
| `0x16800020` | INPUT level — read a pin as `(reg >> pin) & 1` |
| `0x16800024` | OUTPUT data (set/clr/toggle) |
| `0x16800028` | OUTPUT-ENABLE / direction (1 = output) |
| `0x16800034` | INPUT / interrupt-enable |
| `0x16800050 / 54` | per-pin interrupt enable / 4-bit trigger config |
| `0x16800064` | interrupt pending (write to clear); ISR at `0x93a16`, per-pin handler table `gp-0x795c` |

**Pin assignment (live-validated on hardware):**

| Pin | Function | Live read |
|---|---|---|
| **17** | **KEY0 = RST button**, active-low (pressed = 0) | `0x16800020` bit17 = 1 (not pressed) ✓ |
| **16** | **PIR**, active-high | bit16 = 0 (idle) ✓ |
| **22** | **host-wake** output to T23 | OUT-ENABLE bit22 set, OUTPUT bit22 = high ✓ |
| 19, 25 | interrupt inputs (charge / USB / etc.) | IN/INT-EN = `0x020b0000` (16,17,19,25) ✓ |
| 20, 21, 23 | outputs | OUT-ENABLE = `0x00f00000` (20–23) ✓ |

**RST button from T23:** you **cannot** memory-map or bit-bang KEY0 from the host — pin 17 is on
the ATBM private bus. Two routes: (1) the stock path — the ATBM GPIO ISR forwards the press as a
WSM event indication (eventId 16, word0 bit `0x01` press / `0x02` release, per §5), which the host
consumes; (2) IF the firmware exposes a WSM read-register/peek command, U-Boot could poll
`(0x16800020 >> 17) & 1` directly (single 32-bit load, no credit-gate) — this is the clean
"RST-poll at boot" and depends on such an opcode existing (open question). Floodlight / IR / status
LEDs are **not** on this controller — they are T23 SoC GPIOs (floodlight gpio60, IR-cut 58/64,
IR-LED 62, LEDs 49/50) and need no ATBM cooperation.

### 14.7 Bricked-ATBM recovery over the same UART [RE]

The ATBM bootloader (`bootloader.flashIotBoot`, banner strings `FLASH BIN received`,
`HI_UartReceiveHandler`, `flash_page_program`, `check device id success!!` with flash-controller
regs `0x16a00080/94/98`) has a **UART firmware-download mode**. So a mis-flashed ATBM is
recoverable over this same UART without a chip clip — the ingredient for treating ATBM
experiments as reversible.

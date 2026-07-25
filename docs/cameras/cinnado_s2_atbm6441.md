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
| 12 | 0x0C | `wifi_set_ap_open` | **wrong channel for AP** — see §11 | [RE] |
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

### 7.3 Mechanism B — a second reset at ~56 s that we do NOT understand [TBC]

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
7. **AP config must go over the WiFi-core channel, not the MCU channel.** SoftAP is
   `WSM 0x000D (set_wifimode AP)` → `WSM 0x000E (ap_cfg)`, in that order. Sending `0x000E`
   without `0x000D` hangs; routing AP through MCU opcode 12 / WSM `0x003A` hangs (wrong
   subsystem). The resident firmware *is* the hostapd — do not run upstream hostapd. [RE]
8. **Autoboot is only ~2 s** (`Hit any key to stop autoboot: 1` → `0`) — a serial catcher must
   trigger on the boot banner, not on a wall-clock guess. [LIVE]

---

## 12. Open questions ([TBC] register)

| # | Question | Why it matters |
|---|---|---|
| 1 | Is the ~56 s reset (§7.3) power-on-relative or last-contact-relative? | Decides whether feeding from U-Boot can work at all |
| 2 | What actually fires at ~56 s? | Same |
| 3 | Does an **inject-only** feed (link-up once, then bare frames) extend the window? | The whole U-Boot feed design |
| 4 | What is the ~28.6 s periodic SDIO RX in idle Linux? | May be the thing that satisfies mechanism B |
| 5 | Can `wdt_set_period` (0x14) be given a very long period, or 0/0xFFFFFFFF for "never"? | Would be a clean one-shot fix |
| 6 | Does a long `check_alive` period set from Linux persist across an SoC reset into U-Boot? | Would make U-Boot windows irrelevant |
| 7 | Does adding a `UCLASS_WDT` device hijack `reset` via `SYSRESET_WATCHDOG_AUTO`? | Chunked flashing depends on `reset` |
| 8 | Is a button press held through power-on latched by the MCU, or dropped? (`seg2.dec` has `sdio not init but use sdio tx event,event drop`) | Boot-time recovery trigger UX |
| 9 | Does WiFi **STA** work at all on our source-built gtxaspec driver (`CONFIG_MAC80211=y`)? | Gates any LAN-based update path |
| 10 | Is the microSD slot reachable without opening the case? | Decides whether the SD `stop.txt` recovery trigger is enough and the button is optional |
| 11 | Does the Z7682 boot ROM validate the `mcu_fw.bin` footer checksums? | Whether MCU firmware can be repacked |
| 12 | Exact ISA of the two ATBM cores (ARC? C-SKY?) | Only needed for deep firmware work |

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

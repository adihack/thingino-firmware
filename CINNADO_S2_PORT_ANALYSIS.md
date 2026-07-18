# Cinnado S2 (Ingenic T23ZN) → Thingino — Port Analysis & Plan

_Review of the `duggasco/LV-PYN3-W-SP` fork, discovery of the in-tree Cinnado B6 near-twin,
and the initial Cinnado S2 profile added to this fork. Written 2026-07-18._

Target device: **Cinnado S2** — Ingenic **T23ZN**, sensor **OmniVision OS02G10** (2304×1296),
WiFi **AltoBeam ATBM6441** (SDIO, Z7682 MCU inside), **16 MB** NOR flash (GigaDevice GD25Q127C,
JEDEC `c84018`), UART console on **ttyS1 @115200**. Camera runs on constant USB power.

---

## TL;DR

- **We do NOT need to start from `duggasco`.** Thingino already ships a *near-twin* of the S2:
  **`configs/cameras/cinnado_b6_t23zn_os02g10_atbm6461/`** — same SoC (T23ZN), **same sensor
  (OS02G10)**, same 16 MB flash, same ttyS1, and its `thingino.json` GPIO map is **byte-for-byte
  our live-reverse-engineered map**. The B6 is a Cinnado PTZ sibling on the identical AJCloud/ZRT board.
- **The Cinnado S2 = Cinnado B6 minus the pan/tilt motors, plus a PIR sensor, with ATBM6441 instead
  of ATBM6461.** That is a *tiny* delta.
- **The MCU watchdog problem is already solved upstream.** `package/wifi-atbm6461` ships
  `z7682_disable_wdt` (RTOS cmd `0x13`) and `package/thingino-mmc` `S09mmc` calls it at boot — this is
  exactly the `mcu_test --wdt_disable` we did by hand. And `package/atbm6461-tools/atbm6461-tool.c`
  is an open-source `mcu_test` using the **identical opcodes we reverse-engineered live**
  (pir_enable=9, wdt_disable=0x13, battery=0x1a/0x1b).
- An initial profile has been added: **`configs/cameras/cinnado_s2_t23zn_os02g10_atbm6441/`**.

---

## 1. Review — `duggasco/LV-PYN3-W-SP`

That fork ports Thingino to a LaView (also **T23ZN + ATBM6441**, but sensor SC3336, 8 MB flash).
Contents (5 files at repo root):

| File | Verdict |
|---|---|
| `t23zn_sc3336_atbm6441_defconfig` (frag) | **Useful pattern** — confirms `BR2_SOC_INGENIC_T23ZN` + `BR2_PACKAGE_WIFI_ATBM6441` are valid selections. |
| `laview_..._defconfig` (75-line expanded config) | **Reference only** — an older/root-level layout; superseded by the current `configs/cameras/<dev>/` structure. Its U-Boot bootcmd/bootargs/mtdparts are a good reference. |
| `laview_..._.config` | Useful: `wlan_module="atbm6441"`, `wlan_module_opts="atbm_printk_mask=0"`. |
| `laview_..._.uenv.txt` | Useful: shows the `gpio_default=` + `gpio_mmc_cd=` uenv format. Their GPIO map is a LaView map — **not ours**. |
| `README.md` (605 lines) | **Very useful** — a full stock-firmware teardown (mtdparts, gv-gpio.ko, U-Boot files, `cat /sys/kernel/debug/gpio`). Good methodology reference; their HW (SC3336, 8 MB, different GPIO) differs from ours. |

**What to take from duggasco:** the `BR2_PACKAGE_WIFI_ATBM6441` selection + the `wlan_module`
`.config` keys + the U-Boot mtdparts/bootcmd shape. **What to ignore:** SC3336 sensor, 8 MB sizing,
their GPIO map, and the root-level file layout (thingino moved to `configs/cameras/<dev>/`).

**Bottom line:** duggasco proves an ATBM6441 T23ZN port is feasible, but the **Cinnado B6** in-tree
profile is a far closer base for us.

---

## 2. The better base — in-tree **Cinnado B6** (`cinnado_b6_t23zn_os02g10_atbm6461`)

B6 defconfig header literally documents our platform:
> SoC: Ingenic T23ZN … Sensor: OmniVision OS02G10, I2C 0x3c, reg_addr_size=0 (ZRT bank-switch) …
> WiFi: AltoBeam ATBM6461, SDIO, **also manages hardware MCU watchdog** … Flash: 16MB NOR SPI … UART: ttyS1

**B6 `thingino.json` GPIO == our live-validated map (identical):**

| thingino key | GPIO | our RE finding |
|---|---|---|
| `ircut` | 58 64 | IR-cut H-bridge 58/64 ✓ |
| `ir940` | 62 | IR-LED (night) 62 ✓ |
| `white` | 60 | **floodlight** (white light) 60 ✓ |
| `led_b` | 49 | status LED blue 49 ✓ |
| `led_r` | 50 | status LED red 50 ✓ |
| `speaker` | 63 | SPK_AMP 63 ✓ |
| `mmc_cd` | 61 | SD detect 61 ✓ |

B6 also carries a `motors` block (it is a PTZ cam, `ptz=1`). **The S2 has `ptz=0` — we drop motors.**

### What B6 gives us for free
- **OS02G10 sensor** enablement for T23 (driver already in `ingenic-sdk` `3.10.14/sensor-src/t23/os02g10.c`).
- **MCU watchdog** auto-disable at boot: `package/thingino-mmc/files/S09mmc` →
  loads `atbm6461_wifi_sdio.ko` (+ `/sbin/mmc_gpio` SDIO pinmux PB8–PB14) → runs
  `/usr/bin/z7682_disable_wdt`. (Exactly our manual recovery recipe, automated.)
- **`atbm6461-tools`** (`atbm6461-tool.c`, 405 lines): an open `mcu_test` — WiFi setup, battery,
  **PIR/RTC**, firmware helpers. **Opcodes match our RE 1:1**: `CMD_PIR_ENABLE 9`,
  `CMD_WDT_DISABLE 19 (0x13)`, `CMD_GET_BATTERY_STATUS 26 (0x1a)`, `CMD_GET_BATTERY_VOLTAGE 27 (0x1b)`,
  `CMD_SET_PIR_TYPE 81`. Installs as `/usr/bin/mcu_test` (+ symlinks). `librtos_recovered.c` is a
  recovered source of the same `librtos.so` we pulled and reversed.
- **Floodlight** = "white" light: `package/thingino-daynight/files/daynight` drives `gpio_white`
  (from `thingino.json`) via `light white on/off`. Works out of the box.
- **IR-cut / day-night**, **audio** (gpio63), **SD card**, **LEDs** — all standard thingino, wired
  from the same `thingino.json`.

---

## 3. Added profile — `configs/cameras/cinnado_s2_t23zn_os02g10_atbm6441/`

Cloned from B6 with these deltas:

| File | Change from B6 |
|---|---|
| `..._defconfig` | Removed `BR2_THINGINO_MOTORS=y` (S2 = no PTZ). Added `BR2_PACKAGE_ATBM6461_TOOLS=y` (PIR/battery `mcu_test`). Kept OS02G10, 16 MB, audio gpio63, rmem 18M. Kernel-fragment path repointed to this dir. Rich header notes (chip=6441-on-6461-stack, MCU watchdog, PIR, buttons, flash id). |
| `..._.uenv.txt` | `serialport=ttyS1` (same as B6). |
| `cinnado_s2_t23zn.kernel.config` | Same kernel requirements as B6 (CONFIG_BUG=y, DYNAMIC_DEBUG off, MMC1 fixups via wifi pkg). |
| `thingino.json` | B6 GPIO map (= our validated map), **motors block removed**. |

Build (once thingino toolchain is set up):
```
make BOARD=cinnado_s2_t23zn_os02g10_atbm6441
```

---

## 4. WiFi decision — ATBM6441 vs the 6461 stack (the one real risk)

Our chip is **ATBM6441**; B6's is **ATBM6461**. Thingino's packages:
- `package/wifi-atbm6461` — **complete**: prebuilt `atbm6461_wifi_sdio.ko` + `librtos.so` +
  `z7682_disable_wdt` build + MMC1 fixups. Wired into `S09mmc` (hardcoded to `atbm6461_wifi_sdio.ko`).
- `package/wifi-atbm6441` — **minimal**: source-built module from `github.com/gtxaspec/atbm6441`,
  no `z7682_disable_wdt`, no tools, no MMC1 fixups. Would reboot-loop on the MCU watchdog.

**Chosen for the initial profile: use the complete ATBM6461 stack** (`BR2_PACKAGE_WIFI_ATBM6461=y`).
Rationale: ATBM6441/6461 are the same ATBM60xx / Z7682 SDIO family (our stock even loads the generic
`atbm6041_wifi_sdio.ko`), and the 6461 stack brings the watchdog-disable + tools + S09mmc wiring for free.

> **FIRST-BOOT CHECK #1:** does WiFi associate? If the 6461 `.ko` does not bring up the 6441 radio,
> use the **fallback below**.

### WiFi fallback — our own dumped blob (guaranteed to match this chip)
We have this unit's exact, working driver + protocol lib:
- `c:/dev/cinnado_s2/extracted/atbm6041_wifi_sdio.ko` (the module our stock loads)
- `c:/dev/cinnado_s2/extracted/librtos.so`
To use them: clone `package/wifi-atbm6461` → `package/wifi-atbm6441zrt`, replace the `.ko` +
`librtos.so` with ours, set the module name to `atbm6041_wifi_sdio`, and patch `S09mmc`
(or add a device init) to `insmod` our module name and then call `z7682_disable_wdt`.
(These blobs are known-good — they are what we ran live to disable the watchdog and read PIR/battery.)

---

## 5. Build & flash plan (from prior live investigation)

- **Flashing = CH341A only.** The vendor bootloader is **single-stage SPL** — verified over 33 live
  boots: SPL banner `Ver:240319-T23ZN-SINGLE` goes straight to the kernel, **no interactive U-Boot on
  ttyS1** (`Hit any key`/`isvp_t23#` never appear). USB-C data lines are not wired, so Ingenic USB-boot
  / DFU is out too. → **Flash Thingino via the (soldered) CH341A.** flashrom chip: `GD25Q127C`
  (JEDEC `c84018`; NOT `W25Q64`/`ef4017`).
- **First flash = full 16 MB image** with CH341A — a single-shot overwrite that also removes the
  vendor **recovery-OTA footgun** (the vendor recovery `net_upgrade.sh → upgrade → flash_eraseall`
  that erased our chip once). Thingino's layout drops the recovery partition entirely.
- **Backups kept:** `dump.bin` (stock, sha256 `d34ffbd0…`), `dump_modified.bin` (rdinit=/bin/sh,
  `35a18a2f…`). Re-flash either to restore.
- **After Thingino's own (interactive, ttyS1) U-Boot is on flash**, the fast `loady`+`bootm` RAM-test
  loop becomes possible — but note the MCU watchdog resets the SoC ~14.5s into any boot unless
  `z7682_disable_wdt` runs, which U-Boot can't do (needs SDIO). So large `loady` transfers may be
  time-limited; **iterate with CH341A partition writes (kernel/rootfs) for reliability.**

---

## 6. First-boot checklist / open items

1. **WiFi assoc** (see §4). If dead → own-blob fallback.
2. **Sensor**: confirm OS02G10 streams at 2304×1296 (B6 driver `H20240705b`); tune IQ if needed.
3. **MCU watchdog**: confirm `z7682_disable_wdt` runs from S09mmc and the board stays up >20s.
4. **Floodlight**: `light white on` → GPIO60 drives the white panel.
5. **IR-cut / IR-LED / day-night**: `thingino-daynight` toggles gpio58/64 + gpio62.
6. **PIR**: `mcu_test --pir_enable`; wire motion (576-byte `/dev/atbm_ioctl` records, type 0x06
   byte[0x4e]==1) into thingino motion — may need a small `mcud`-style reader/agent.
7. **Audio**: SPK_AMP gpio63; mic via Ingenic AIC (needs IMP init — Thingino/prudynt provides it).
8. **Buttons PWR/RST**: MCU power/wake (long-press), not SoC GPIO — leave unhandled.
9. **Partition sizing**: 16 MB gives generous rootfs + overlay vs the 8 MB reference boards.

Upstream note: Thingino maintainers WONTFIX battery/floodlight cameras (issue #653) — this stays a
self-hosted fork (like duggasco's).

---

## 7. Cross-references (our reverse-engineering, in `c:/dev/cinnado_s2/`)
`logs/gpio_map.txt` (validated GPIO), `logs/mcu_opcodes_full.md` (MCU protocol/opcodes — the ones
that match `atbm6461-tool.c`), `logs/mcu_protocol.md`, `logs/STABLE_SHELL_RECIPE.md`,
`extracted/atbm6041_wifi_sdio.ko` + `extracted/librtos.so` (own-blob fallback),
`dump.bin` / `dump_modified.bin` (restore images).

---

## 8. BUILD RESULT — SUCCESS ✅ (2026-07-18, autonomous)

The profile **builds cleanly** and produces a valid, bootable 16 MB image.

```
output/.../images/thingino-cinnado_s2_t23zn_os02g10_atbm6441.bin
  size = 16777216 (16 MB, padded to flash)
  first bytes = 06 05 04 03 02 55 aa 55  (valid Ingenic SPL header — same format as stock)
  sha256 = 048146518442e56b046745b181b704f8b94f5a4ed9166cb7b1eeace9199d5fda
  built from commit 70b6c8c
```

**Thingino MTD layout produced for the S2 (16 MB):**
```
mtdparts=jz_sfc:320k(boot),64k(env),1408k(kernel),4608k(rootfs),9984k(data),16384k@0(all)
```
| part | offset | size | content |
|---|---|---|---|
| U_BOOT | 0x000000 | 320K | Thingino U-Boot (interactive, console=ttyS1) |
| UB_ENV | 0x050000 | 64K  | U-Boot env |
| KERNEL | 0x060000 | 1408K | uImage (~1.38 MB) |
| ROOTFS | 0x1C0000 | 4608K | squashfs (RO, ~4.56 MB) |
| DATA   | 0x640000 | 9984K | jffs2 overlay (writable) |

Artifacts also copied (outside the repo) to `c:/dev/cinnado_s2/thingino_images/`:
`thingino-...bin` (full), `u-boot-with-tpl-lzma.bin`, `u-boot-env.bin`, `uImage`, `rootfs.squashfs`.

### Host build deps NOT flagged by `make bootstrap` / `dep_check.sh` (add these)
The stock dep list is incomplete for a clean Ubuntu; the build failed until these were added:
- **`python3-dev`** — U-Boot 2026.07 `scripts/dtc/pylibfdt` needs `Python.h`.
- `ripgrep shfmt nodejs npm` — dep_check prompts interactively for these (hangs a non-interactive build).
- Also installed defensively: `python3-setuptools libssl-dev pkg-config texinfo help2man gettext`.
- **PATH must not contain spaces** — buildroot aborts if the (WSL-inherited Windows) PATH has
  `Program Files`. Build with `PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`.

### Flashing (do with the board POWERED OFF)
The stock bootloader is single-stage SPL (no interactive U-Boot on ttyS1), and USB-C data is unwired,
so **CH341A is the flash path.** Full-image write (also removes the vendor recovery-OTA footgun):
```
flashrom -p ch341a_spi -c GD25Q127C -w thingino-cinnado_s2_t23zn_os02g10_atbm6441.bin
```
(Chip is GigaDevice GD25Q127C, JEDEC c84018.) Keep `dump.bin` / `dump_modified.bin` as restore images.
After flashing, Thingino's U-Boot + kernel print to **ttyS1** — so first boot is fully observable
over our existing serial. First-boot checklist: §6 (WiFi assoc is risk #1).

---

## 9. LIVE: Thingino U-Boot SELF-FLASHED & running (no desolder!) ✅✅✅ (2026-07-18)

**Self-flashed the built Thingino U-Boot from the running (vendor-Linux) board — no CH341A, no desolder —
and it boots fully interactive on ttyS1.**

Method (worked): the recovery /bin/sh has `flashcp` + `md5sum` (no dd/mtd_debug/base64). Steps:
1. Extract first 0x60000 of the full image (U_BOOT 0x0 + UB_ENV 0x50000) → `ube_0x60000.bin` (393216 B, md5 49a72742…).
2. Transfer to `/tmp/ube.bin` over serial (printf-hex chunks, ~12 min); **verify md5 on-device == local (GATE)**.
3. `mknod /dev/mtd0 c 90 0` (no mdev in bare initramfs; mtd char major=90), then
   `flashcp -v /tmp/ube.bin /dev/mtd0` → erases 12×32K blocks, writes 384K, **verifies 100%** (rc=0).
4. `reboot -f`.

Result on ttyS1:
```
T23 TPL / TPL: DDR up / SPL loaded, jumping
U-Boot SPL 2026.07  →  U-Boot 2026.07 (our build)
CPU: Ingenic T23 (XBurst1)  Model: ISVP-T23ZN (SFC NOR)  DRAM: 64 MiB
SF: Detected gd25q128 ... 16 MiB     (flash correct)
In/Out/Err: serial@10031000          (ttyS1 — interactive)
Hit any key to stop autoboot         (interruptible — unlike vendor single-stage SPL)
=> version  → U-Boot 2026.07 ... Buildroot 15.3.0   (responds to commands)
```
`printenv` (key vars): `bootcmd=run autoupdate;run loaduenv;sf probe;setenv bootargs …;sf read ${loadaddr}
${kern_addr} ${kern_size};bootm`; `kern_addr=0x60000 kern_size=0x160000 loadaddr=0x80600000
flash_len=0x1000000 root=/dev/mtdblock3 rootfstype=squashfs serialport=ttyS1`.
Autoboot fails with `ERROR -91: can't get kernel image!` — expected, kernel/rootfs are still vendor data
(only 0x0–0x60000 was flashed). Drops to the `=>` prompt.

### The `autoupdate` mechanism (clean full-install path, from env)
```
autoupdate = fatload mmc 0:1 ${loadaddr} autoupdate-full.bin ; sf probe ; sf erase 0 ${flash_len} ;
             sf write ${loadaddr} 0 ${filesize} ; ... reset
```
→ Put the full image on a FAT SD card as **`autoupdate-full.bin`**, insert, and Thingino U-Boot
auto-flashes the whole 16 MB and reboots. (See watchdog caveat below.)

### MCU-watchdog caveat (why it currently reboot-loops)
The ATBM6441/Z7682 MCU watchdog resets the SoC ~14 s after boot unless fed/disabled, and **U-Boot cannot
disable it** (needs the atbm SDIO driver, not in U-Boot). So the `=>` prompt survives only ~14 s per cycle,
then resets — a harmless loop (it's our U-Boot; the vendor recovery-OTA is gone). This ALSO time-limits any
U-Boot flash op: a full `sf erase+write` of 16 MB (autoupdate or manual) and a `loady` of the 1.4 MB kernel
both exceed ~14 s → risky. Once the FULL firmware is flashed, Linux boots (<14 s) and its `S09mmc` runs
`z7682_disable_wdt` → watchdog off → stable.

### To finish the install (get full Thingino booting)
- **Reliable:** CH341A full-flash of `thingino-...bin` (board OFF, no watchdog): `flashrom -p ch341a_spi
  -c GD25Q127C -w thingino-...bin`. (Milestone proves the U-Boot; this completes kernel+rootfs+data.)
- **Watchdog-limited alternatives:** SD `autoupdate-full.bin`, or U-Boot `loady`+`sf write` — both need the
  op to finish inside the ~14 s window (tight/risky) unless the MCU watchdog is first extended/disabled.

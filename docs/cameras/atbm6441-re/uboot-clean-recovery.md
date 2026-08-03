# Clean recovery U-Boot + RST factory reset + AP-SSID ownership (2026-07-27)

Status of the bootloader after shelving the U-Boot-WiFi experiment. Everything below
is **built + patch-verified**; the on-hardware items are flagged `*** UNTESTED ***`
(they were written while the operator was away and could not power-cycle).

Commits: `e7dda51` (clean U-Boot: strip WiFi eth driver, add RST factory reset + LED +
`atbm button` return code) and the follow-up that renames the recovery AP.

---

## 1. What the clean U-Boot is

`board/ingenic/isvp-t23/atbm_wdt.c` (delivered as `package/all-patches/uboot/2026.07/0002-cmd-atbm-wdt.patch`).
The **proven** recovery core is kept:

- SDIO bring-up + full WSM handshake (unlimited bidirectional MCU messaging).
- MCU watchdog control (`0x13` disable / `0x12` enable) — the ~14.5 s reset defeat.
- The **scan-crash stop**: on recovery-console entry it injects `0x40 wifi_start_ap`
  (a dummy AP) so the boot STA-scan stops and the ATBM firmware does not hit the
  `LMACtoUMAC_ScanComplete` assert (the real cause of the ~56 s reset — see §14.4c of
  the main doc).
- RST-button read over the SDIO AHB window (`0x16800020` bit17, active-low).
- `atbm ap/apA/ping/rx/ahb/button/wdt` console commands (interactive only).

**Removed:** the DM_ETH WiFi pseudo-Ethernet driver + NetConsole WiFi-mode. That work
is preserved verbatim in `uboot-wifi-eth-driver-WIP.md` and can be resumed later. The
clean binary contains **zero** eth-driver code.

## 2. RST-hold factory reset (`*** HARDWARE-CONFIRMED 2026-07-28 ***`)

`atbm_rst_recovery_check()` is called from `board_late_init()` on **every** boot:

```
if (atbm_ensure_linked()) return;   // SDIO didn't come up -> normal boot
if (!atbm_rst_pressed())  return;   // RST not held -> normal boot
// RST held: kill MCU wdt; steady 2 Hz blink of the RED LED (gpio50) while counting.
// held >= 10 s -> 3 even 1s/1s white-floodlight (gpio60) blinks (confirm) ->
//                 run_command("run overlay_wipe")  (chunked factory reset + reboot)
// released < 10 s -> normal boot (gesture cancelled)
```

- **Feedback GPIOs** (T23 SoC port-B, raw JZ GPIO regs at `GPIOB=0xb0011000`: INTC 0x18 /
  MASKS 0x24 / PAT1C 0x38 config; PAT0S 0x44 high / PAT0C 0x48 low; all **active-high**,
  live-verified via `gpio set 50/60 1`):
  - **RED status LED** = gpio50 = PB18 (the bi-colour LED's red half; gpio49 = blue).
  - **White floodlight** = gpio60 = PB28 — the bright, unmistakable confirm signal.
- **GPIO gotcha:** busybox `devmem` needs the **physical** address (`0x10011044`), not the
  KSEG1 alias `0xb0011044` that U-Boot `mw` uses. `/sys/class/gpio` + debugfs gpio are
  empty on this build; drive pins with the `gpio` command or physical-address `devmem`.
- This mirrors thingino's own factory-reset convention `button_cmd_0=... run overlay_wipe`
  (`configs/common.uenv.txt:3`). thingino's *standard* button handler reads a **SoC**
  GPIO, which does not exist for this camera — RST is on the **ATBM MCU** — so this
  camera needs the custom ATBM-side read. That is exactly what `atbm_rst_recovery_check`
  does.
- **`atbm button` return code fixed**: bare `atbm button` now returns SUCCESS iff PRESSED
  (was always SUCCESS), so `if atbm button; then ...` works in scripts.

### Behavioural change to be aware of
`board_late_init` now brings the ATBM SDIO up **early on every boot** (to read RST).
Previously the ATBM was only touched in U-Boot on a recovery-console entry. On a normal
boot the link comes up, RST reads "released", and we return — Linux then re-enumerates
the SDIO from scratch (proven to work: we have booted Linux many times right after a
U-Boot `ensure_linked`). Still, **confirm normal boot reaches Linux + WiFi initialises**.

## 3. AP-SSID ownership — RESOLVED (root cause of the "s2" AP)

The soft-AP was showing **"s2"** instead of "thingino". Root cause found by reading the
whole path:

- **Linux already owns the AP SSID.** `/etc/init.d/S38wpa_supplicant`
  (`package/wifi/files/S38wpa_supplicant.in:254-298`, `start_atbm_softap`) runs
  `atbm_softap "$ssid" 6` where `$ssid` comes from the `ssid="..."` line of
  `/etc/wpa_supplicant.conf`. The shipped default is `ssid="THINGINO-"`
  (`package/wifi/files/wpa_supplicant.conf:5`) → with the MAC-octet fallback in the init
  script → **`THINGINO-XXXX`**. `atbm_softap` (`package/atbm6461-tools/files/atbm_softap.c`)
  issues `CLEAR_WIFI_CFG` then `AP_CFG` with that SSID, then `mcu_test --send-raw=12`
  starts the beacon.
- **"s2" came from U-Boot, not Linux.** `atbm_wdt_console_entry()` used the literal
  `m3_msg(0x40, "s2", 2)` as its dummy scan-stop AP, and the interactive `atbm ap/apA`
  experiment commands wrote "s2" into the chip. On a *normal* boot the console-entry does
  not run, so a clean boot already lets Linux set `THINGINO-XXXX`.
- **Fix applied:** the recovery dummy AP is renamed **`s2` → `thingino-recovery`** so the
  bootloader never emits a mystery product-looking SSID. The FINAL running-system AP name
  is owned by Linux via `wpa_supplicant.conf`. No Linux package change was needed — the
  Linux side was already correct.

### `*** UNTESTED, live-verify ***`
If, after a Linux boot, the AP still shows a stale name (e.g. `thingino-recovery` or a
persisted value) rather than `THINGINO-XXXX`, then `mcu_test --send-raw=12` is beaconing
**persisted chip config** instead of the freshly written `AP_CFG`. Fix would be in
`start_atbm_softap` (re-issue AP_CFG after op12, or a chip mode-reset before AP_CFG). To
change the SSID deliberately, edit `wpa_supplicant.conf:5` `ssid="..."` — no rebuild of
anything else required.

### "Restore normal WiFi/config"
A normal Linux boot re-runs `atbm_softap` (CLEAR_WIFI_CFG + AP_CFG), which overwrites the
chip's experiment config. STA/client mode is the `mcu_test --wifi_connect` path
(`S38wpa_supplicant.in:332-378`), selected when `wpa_supplicant.conf` has `ssid=` **and**
`psk=` and **no** `mode=2`. Nothing on flash needs clearing by hand.

## 4. Flash partition layout + factory-reset correctness [CONFIRMED, this build]

mtdparts baked into the U-Boot env (from `u-boot-env.bin`, generated by
`package/thingino-uboot/thingino-uboot.mk:100-118` from the actual kernel/rootfs sizes):

```
jz_sfc:320k(boot),64k(env),1408k(kernel),4608k(rootfs),9984k(data),16384k@0(all)
       mtd0        mtd1     mtd2          mtd3           mtd4        mtd5
```

| part | mtd | offset      | size       |
|------|-----|-------------|------------|
| boot   | mtd0 | 0x000000 | 0x050000 (320k) |
| env    | mtd1 | 0x050000 | 0x010000 (64k)  |
| kernel | mtd2 | 0x060000 | 0x160000 (1408k) |
| rootfs | mtd3 | 0x1C0000 | 0x480000 (4608k) |
| **data (overlay/config)** | **mtd4** | **0x640000** | **0x9C0000 (9984k = 9.75 MB)** |
| all    | mtd5 | 0x000000 | 0x1000000 (whole 16 MB) |

`overlay_wipe` (`...uenv.txt:54`) erases `0x640000` + 3×`0x340000` = `0x640000..0x1000000`
= **exactly the `data` partition (mtd4)**, touching nothing else. Factory-reset offsets
are **provably correct for this build**.

### ⚠→✅ Offset fragility — RESOLVED 2026-08-04
The `data` offset is *computed* from kernel+rootfs sizes at build time, but `overlay_wipe`
USED to *hardcode* `0x640000` — and this fragility bit us exactly as warned: the 2026-08-03
BSSID-fix rebuild grew the rootfs (4608k→8192k) and `au_relayout` moved `data` to
`0xa60000`, so the hardcoded wipe erased **rootfs** (brick risk) and missed the real
overlay → the RST factory reset left WiFi stuck in **client** mode. Worse, on this device
`overlay_wipe` wasn't even imported into the env, so `run overlay_wipe` was a no-op.
**FIX (live-validated 2026-08-04):** `overlay_wipe` now uses the layout-tracking env vars
`${data_addr}`/`${data_size}` (set by `au_relayout`), so it always targets the real `data`
partition regardless of size — no hardcoded offset to go stale. Captured live: `AU:wiping-overlay
0xa60000 0x5a0000` → `AU:overlay-wiped-defaults` → reboot → AP (`THINGINO-78ec`). The
~5.76 MB erase completes in ~30s, inside the ~60s MCU host-alive window. **Fully-robust
alternative** (only needed if `data` ever exceeds ~10 MB so the erase can't finish in one
window): don't erase from U-Boot at all — have `atbm_rst_recovery_check` tag the kernel
cmdline (`thingino_factory_reset=1`, RAM-only so it self-clears), and have `overlay/init`
`flash_eraseall` the mtd **named** "data" (from `/proc/mtd`) before mounting it — offset-free,
uncuttable (Linux keeps the MCU fed). Also guard `S38 credentials_from_card()` on that tag
so an inserted provisioning SD can't re-seed client mode on the reset boot.

### ⚠ 60 s host-alive window (best-effort wipe)
A full `data` erase is ~57 s (≈179 KB/s) and the ATBM host-alive timer (~60 s, **cannot be
disabled, only fed**, and U-Boot doesn't feed it) may cut it. This is *acceptable* for a
factory reset: `overlay_wipe` erases from the **start** (`0x640000`) first, so even a cut
wipe destroys the jffs2 superblock → the overlay won't mount → thingino falls back to
defaults anyway. The **reliable full wipe** is from Linux: `flash_erase /dev/mtd4 0 0`
(a running Linux feeds the MCU indefinitely).

## 5. `*** UNTESTED ON HARDWARE ***` — verify-on-return checklist

1. Flash the clean U-Boot (`u-boot-with-tpl-lzma.bin`) to `/dev/mtd0` (flashcp over UART,
   or the full `thingino-*.bin` via CH341A). Fallback if bad: reflash known-good via CH341A.
2. **Normal boot** still reaches Linux and WiFi comes up (board_late_init now brings the
   ATBM SDIO up early every boot).
3. Soft-AP shows **`THINGINO-XXXX`** (not `s2`, not `thingino-recovery`). If not, see §3.
4. **Hold RST at power-on** → status LED (gpio49) blinks + console prints the `1..10s`
   countdown. Confirm the LED **pin + polarity** (assumed active-high).
5. **Release < 10 s** → normal boot. **Hold to 10 s** → `overlay wiped` + reboot to
   defaults. Confirm the reset actually clears the overlay (creds/config reset).
6. `atbm button` at the U-Boot prompt returns success only while pressed.

# Reboot-hang, remote recovery, and the WiFi-config-apply chain (Cinnado S2, 2026-07-28)

All **live-verified** on the unit this day. This resolves a chain: the WiFi portal couldn't
apply STA (client) settings → because it applies them by **rebooting** → because **`reboot`
hangs on this board**.

## 1. The reboot-hang — root cause

`reboot` on this board reaches `Restarting system.` (kernel `machine_restart`) and then **hangs
forever** — no `T23 TPL`, U-Boot never re-runs. Diagnosis:

- The T23 kernel's `machine_restart` is `jz_wdt_restart` (`arch/mips/xburst/soc-t23/common/reset.c`),
  a **WDT 4 ms soft-reset**. On this board a WDT reset does **not** re-cycle the SPI-NOR / ATBM
  state, so the bootrom can't reload TPL → hang. (Cold power-cycle always works; warm WDT reset
  doesn't.)
- The kernel has a second path, `hibernate_restart()` (RTC hibernate + wake), exposed at
  `/proc/jz/reset/reset`. **`echo hibernate > /proc/jz/reset/reset` reboots cleanly** (T23 TPL
  ~39 s later, full boot to login). So the board *can* reboot — via a real power-cycle, not a
  WDT reset.
- **Why the hibernate wake takes ~39 s, and why full `reboot` still hangs even with
  `CONFIG_HIBERNATE_RESET=y`:** the **RTC is disabled** on this build — `RTCCR = 0x00000000`
  (RTC-enable bit clear), no `/sys/class/rtc/rtc0`. So `hibernate_restart()`'s RTC wake-alarm
  (`RTCSAR = RTCSR+5`) can **never fire** (the RTC isn't counting). The actual wake is the
  **ATBM** power-cycling the T23 (`master_power_on`, ~39–40 s — same timing as an ATBM reboot,
  see §2). A **full `reboot` first runs the shutdown sequence** (stops WiFi, `device_shutdown`
  tears down the SDIO/ATBM link) → the ATBM can no longer power-cycle the T23 → **hang**. The
  `/proc` path keeps everything up → the ATBM wakes it.

So: `CONFIG_HIBERNATE_RESET=y` (now in the kernel fragment) makes `reboot` *use* the hibernate
path, but it's **not sufficient** — the shutdown breaks the ATBM wake.

## 2. Remote recovery (no physical power-cycle) — `AT+REBOOT`

When a `reboot` hangs, the T23 is dead but the **ATBM is a separate always-on chip**. On its
**AT console (COM11)**, `AT+REBOOT` reboots the ATBM, and on re-init its `master_power_on`
**cold-boots the T23**. Live-verified: `AT+REBOOT` → `T23 TPL at 1 s` → login at 40 s. This is
the lab recovery lever (and it's why the hibernate/`reboot` wakes are ATBM-driven). *Lab-only —
COM11 is not a deployment channel.*

## 3. The fix (shipped) — `/bin/reboot` hibernate wrapper

Because `PATH=/bin:/sbin`, a script at **`/bin/reboot`** shadows busybox `/sbin/reboot` for every
caller (the WiFi portal `api.cgi:218 reboot -d 2 &`, `reboot.cgi`, the shell). It skips the
service-shutdown that breaks the wake and triggers the hibernate directly while the SDIO/ATBM is
still up, so the ATBM power-cycles the T23:

```sh
#!/bin/sh
# Cinnado S2: WDT soft-reset hangs on this board; use the RTC hibernate reset which keeps
# the ATBM/SDIO up so the ATBM power-cycles the T23. Honors busybox 'reboot -d N'.
[ "$1" = "-d" ] && sleep "${2:-0}"
sync
echo hibernate > /proc/jz/reset/reset
```

Live-verified: `reboot -d 2` → `T23 TPL at 49 s` → login at 88 s. Works on the stock kernel too
(it uses `/proc/jz/reset/reset`, independent of `CONFIG_HIBERNATE_RESET`). **Reboot is ~50 s to
TPL — slower than a normal reboot, but it works** (vs. an infinite hang).

Trade-off: services aren't stopped gracefully (`sync` flushes the jffs2 overlay first, so no
config loss). Acceptable for a camera reboot.

## 4. WiFi config apply — now works

The portal writes the WiFi config then `reboot -d 2 &` to apply it (`api.cgi:154-219`). With the
hang, STA settings never applied → "set STA mode, didn't connect". With `/bin/reboot` in place:
**live-confirmed** a `wlan configure <ssid> <psk>` (no `mode=2`) + reboot brings the board up in
**client mode** (no AP/portal flag, `wlan0` no IP because the test SSID doesn't exist). The AP
path (`mode=2`) restores on the next reboot. Chain fixed.

## 5. Deployable fix — SHIPPED (kernel reboot-notifier)

The `/bin/reboot` wrapper (§3) is live on *this unit's* overlay, but thingino's
`BR2_ROOTFS_OVERLAY` (`configs/fragments/core.fragment`) is **global** — one `overlay/` for all
cameras — and a hibernate `/bin/reboot` would **hang non-ATBM boards** (whose WDT reboot works).
So the deployable fix is **kernel-based**, shipped as
`board/ingenic/xburst1/patches/linux/0090-cinnado-s2-atbm-reboot-hibernate-notifier.patch`:

a **reboot-notifier** in `reset.c` that calls `hibernate_restart()` on `SYS_RESTART` from
`kernel_restart_prepare` — **before** `device_shutdown`, while the WiFi driver is still loaded (the
reboot service-shutdown does *not* rmmod it — verified) — so the ATBM wakes the T23. Gated on
`CONFIG_HIBERNATE_RESET` (this camera's kernel fragment) so other xburst1 boards are unaffected.

**Live-verified: with the `/bin/reboot` wrapper removed, a native `reboot` reboots cleanly**
(T23 TPL ~66 s → login). So every caller — the WiFi portal (`api.cgi reboot -d 2 &`),
`reboot.cgi`, the shell — now works, and **web-panel device/WiFi setup applies correctly**. Reboot
is ~60-90 s (the ATBM power-cycle is slow) but reliable. The `/bin/reboot` wrapper is redundant
once this kernel ships (kept only as a kernel-independent fallback).

Alternative (not needed): enable the RTC so the hibernate alarm self-wakes (~5 s, no ATBM
dependency) — untested; the RTC may have no oscillator populated.

## 6. Related: the "s2" soft-AP

Separate issue (see `uboot-clean-recovery.md` §3): the mystery "s2" AP is **ATBM-NVRAM residue**
from early U-Boot `apA` experiments, not the Linux image. Linux owns the SSID via
`atbm_softap` (default `THINGINO-XXXX`); at cold boot `mcu_test --send-raw=12` (op12) can beacon
the stale stored config before Linux's `AP_CFG` settles. A boot-time re-apply of `atbm_softap`
after a short settle in `S38wpa_supplicant` would harden it. Runtime `atbm_softap` overrides the
beacon immediately (verified). `AT+FLASH_CONFIG_RESET` on COM11 would scrub the NVRAM but risks
MAC/cal — avoid.

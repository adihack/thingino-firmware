# ATBM6441 register & memory reference

All addresses are on the ATBM6441's internal NDS32 bus (little-endian). They are reachable live via
`AT+rmem`/`AT+wmem` on the ATBM UART, and — for the MMIO peripherals — from the T23 **only** through
the SDIO→AHB direct-access window (the same bridge firmware-download uses), not as plain SDIO
registers. Verified live where marked [LIVE].

## Memory map (from the AT+rmem address scan) [LIVE]

| Range | Contents |
|---|---|
| `0x000000`–`0x00ffff` | ITCM (vectors/code, copied from flash `0x410000`) |
| `0x030000` | IVB / vector base at runtime |
| `0x060000`–`0x0fffff` | application text/rodata at runtime (link base: `flash = VMA + 0x380000`) |
| `0x400000`–`0x5fffff` | **SPI-NOR, XIP-mapped** (2 MB). Header magic `0000ab45 0000ab47` at `0x400000` |
| `0x800000`–`0x83ffff` | DTCM (data). `gp = 0x807980` lives here |
| `0x16100000` | clock/PMU-ish block (WDT clock gate at `+0x80/+0x90`) |
| `0x16600000` | **watchdog** |
| `0x16800000` | **GPIO controller** |
| `0x16a00000` | SPI-flash controller (`+0x80/+0x94/+0x98`; device-id check) |
| `0x0900xxxx` | a second RAM/alias window (holds copies of some data) |

## `gp` and key globals (`gp = 0x807980`) [LIVE + RE]

| Symbol | Address | Notes |
|---|---|---|
| crc32 table | `gp+0x2124` = `0x809aa4` | standard reflected CRC-32 (`00000000 77073096 ee0e612c …`) [LIVE] |
| `g_master_wdt_timer` | `gp+0x202c` = `0x8099ac` | → timer object `0x809298` (callback `0xa9ffe`); **dormant** [LIVE] |
| master_wdt `period_ms` | `gp-0x7968` = `0x800018` | set by msg_id 0x14 (seconds×1000) |
| `master_mode` flag | `gp+0x20fc` | 0/1; read-only in the app image |
| master power-state | `gp+0x2034` | 0/1/2 |

## Watchdog `0x16600000` — the ~14.5 s STARTUP wdt [RE + LIVE]

Key-protected: write the key to `+0x18` immediately before every control write. In-blob driver at
VMA `0xce44c–0xce57c`. **Idle in normal operation** (count `+0x28 = 0`, control `+0x00 = 0x03002001`,
stable across reads [LIVE]) — it only runs during the ~14.5 s startup.

| Reg | Meaning |
|---|---|
| `0x16600018` | KEY / unlock ← `0x00005AA5` (before every protected write) |
| `0x16600010` | CONTROL, bit0 = enable (set = arm, clear = disable) |
| `0x16600014` | FEED ← `0x0000CAFE` (kick, after key) |
| `0x16600020 / 24` | timeout / prescaler reload |
| `0x16600028` | current count / status (read-only) |
| `0x1660001c` | software-reset trigger (magics `5AA5`/`CAFE`) |
| `0x16100080 ← 3`, `0x16100090` | WDT module clock gate |

To disable by raw poke: `0x16600018 ← 0x5AA5` then `0x16600010 ← 0`. (This is separate from the
~56 s host-alive reset, which these pokes do NOT address — see parent §14.4.)

## GPIO controller `0x16800000` [RE + LIVE]

Pin number = bit index in each 32-bit register. HAL at `0xcee30–0xcf05e`. **Internal to the ATBM —
not visible on the SDIO bus.** Read a pin: `(0x16800020 >> pin) & 1`.

| Reg | Meaning |
|---|---|
| `0x16800020` | INPUT level |
| `0x16800024` | OUTPUT data (set/clr/toggle) |
| `0x16800028` | OUTPUT-ENABLE / direction (1 = output) |
| `0x16800034` | INPUT / interrupt-enable |
| `0x16800050 / 54` | per-pin interrupt enable / 4-bit trigger config |
| `0x16800064` | interrupt pending (write to clear); ISR `0x93a16`, handler table `gp-0x795c` |

Pin assignment (live-validated by reading `0x16800020/24/28/34`):

| Pin | Function | Live evidence |
|---|---|---|
| **17** | **KEY0 = RST button**, active-low (pressed = 0) | INPUT bit17 = 1 idle; input+IRQ enabled |
| **16** | **PIR**, active-high | INPUT bit16 = 0 idle; input+IRQ enabled |
| **22** | **host-wake** output to the T23 | OUT-ENABLE bit22 set, OUTPUT bit22 = high |
| 19, 25 | interrupt inputs (charge/USB/etc.) | IN/INT-EN = `0x020b0000` (16,17,19,25) |
| 20, 21, 23 | outputs | OUT-ENABLE = `0x00f00000` (20–23) |

The RST button therefore cannot be read directly from the T23; only via the WSM event indication
(eventId 16) or a hypothetical firmware register-peek command. Floodlight/IR/status-LEDs are **not**
here — they are T23 SoC GPIOs (floodlight gpio60, IR-cut 58/64, IR-LED 62, LEDs 49/50).

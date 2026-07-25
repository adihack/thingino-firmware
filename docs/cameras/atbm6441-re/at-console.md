# ATBM6441 AT-command console

The ATBM6441 exposes an interactive AT console on its **own UART** (on the Cinnado S2 dev unit:
`COM11`, **115200 8N1**, DTR/RTS don't matter). This is separate from the Ingenic T23 console. It is
a **lab tool for a single soldered camera** — not a deployment interface.

## Ground rules [LIVE]

- Commands are `AT+NAME` or `AT+NAME=arg[,arg…]`; case-sensitive; terminated with CR-LF. Bare
  `help` prints the full list (~180 commands). `AT+HELP` prints the short identity line.
- **Numeric args: address is hex (no `0x`), length is decimal.** e.g. `AT+rmem=30000,16` reads
  16 bytes at `0x00030000`.
- **Read replies are capped** at ~160 bytes; anything over ~8 hexdump lines overruns the chip's
  UART TX FIFO and corrupts bytes. Use **≤128-byte** reads.
- Run `AT+DEFAULT_DEBUG_ENABLE=0` once at the start so asynchronous debug prints (PIR/lp_mgr/etc.)
  don't interleave into a hexdump. `AT+SetDbgMask=0` also helps.
- Words are **little-endian** in the hexdump.

## Commands we relied on

| Command | Use |
|---|---|
| `AT+rmem=<hex>,<dec>` | **read any address** — the whole RE is built on this |
| `AT+wmem=<hex>,<hex>` | write any address (not used against the live cam except read-back checks) |
| `AT+GET_VER` / `AT+GET_SDK_VER` / `AT+WIFI_GET_FWINFO` | identity: `ATBM:6441 fwVer:15043`, SDK `0.4.0`, app `1.2.5u1` |
| `AT+GET_SYS_STATUS` | mode, MAC, channel, SSID, heap free, CPU MHz |
| `AT+DEFAULT_DEBUG_ENABLE=0` | mute async prints (do this first) |
| `AT+FWCHKSUM` / `AT+KEYCHKSUM` | firmware/key checksums |
| `AT+taskShow` / `AT+memoryShow` | RTOS task + heap dumps |

## Other notable groups (from `help`)

- **GPIO / analog:** `AT+GPIO_READ` `AT+GPIO_WRITE` `AT+GPIO_SET_DIR` `AT+GPIO_GET_DIR`
  `AT+GPIO_TOGGLE` `AT+GET_ADC` `AT+SET_PWM` `AT+STOP_PWM`
  (arg format differs from the manual pin number — the GPIO controller is easier read via
  `AT+rmem 0x16800020`; see `registers.md`.)
- **WiFi:** `AT+WIFI_SCAN` `AT+WIFI_JOIN_AP` `AT+WIFI_STATUS` `AT+WIFI_AP_CFG` `AT+WMODE`
  `AT+WIFI_STA_MAC` `AT+WIFI_COUNTRY` `AT+SMART_CFG_START` …
- **Net:** `AT+IFCONFIG` `AT+PING` `AT+DNS` `AT+SOCKET*` `AT+iperfs`/`iperfc` `AT+SNTP_*`
- **RF/cal:** `AT+READ_TEMP` `AT+GET_FREQ` `AT+TX_POWER` `AT+WIFI_ETF_*` (production test)
- **Power/sleep:** `AT+DEEP_SLEEP` `AT+LIGHT_SLEEP` `AT+WAKEUP_GPIO` `AT+WAKEUP_RTC`
- **Flash config:** `AT+FLASH_CONFIG_RESET` `AT+RESTORE` `AT+REBOOT`
  ⚠️ these change state / reset the chip — avoid on the live camera.

## Bricked-ATBM recovery [RE]

The ATBM bootloader (`bootloader.flashIotBoot`) has a UART **firmware-download** mode — strings
`FLASH BIN received`, `HI_UartReceiveHandler`, `flash_page_program`, `check device id success!!`
with flash-controller regs `0x16a00080/94/98`. So a mis-flashed ATBM is recoverable over this same
UART without a chip clip (protocol not yet fully reversed).

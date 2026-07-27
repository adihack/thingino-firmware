# ATBM6441 firmware reverse-engineering — methodology & tooling

This folder preserves the tools and the method used to recover and statically analyse the
**ATBM6441** WiFi-SoC firmware on the Cinnado S2 (2026-07-25). The results are written up in the
parent doc [`../cinnado_s2_atbm6441.md`](../cinnado_s2_atbm6441.md) §14. This README is the
"how to redo it" companion, plus the reference tables:

- [`msgid-reference.md`](msgid-reference.md) — the complete message_mgr command table (69 msg_ids)
- [`registers.md`](registers.md) — WDT, GPIO, flash-controller and CRC/gp register maps
- [`at-console.md`](at-console.md) — the ATBM AT-command console (how we dumped the flash)
- [`tools/`](tools/) — the scripts

U-Boot integration & recovery (how the RE turned into shipped bootloader behaviour):

- [`uboot-clean-recovery.md`](uboot-clean-recovery.md) — **current bootloader**: clean U-Boot,
  RST-hold factory reset + LED, AP-SSID ownership (the "s2" fix), flash partition map &
  factory-reset correctness proof, and the on-hardware verify checklist
- [`uboot-wifi-datapath.md`](uboot-wifi-datapath.md) — softMAC WiFi data-path RE (TX/RX WSM path)
- [`uboot-wifi-eth-driver-WIP.md`](uboot-wifi-eth-driver-WIP.md) — the shelved U-Boot-WiFi eth
  driver, preserved for later (drain-for-association finding + gotchas)

Tags used throughout: **[LIVE]** = observed on the running chip, **[RE]** = from static
disassembly, **[TBC]** = unconfirmed.

## The chip

The ATBM6441 (a.k.a. Z7682 MCU "embedded in" the same package) is an **Andes NDS32**
little-endian core running FreeRTOS + LwIP + the AltoBeam WiFi MAC (`ATHENA_BX`) + the AJCloud
low-power-camera application (`lp_mgr`, `message_mgr`). It has its **own 2 MB SPI-NOR** and its
**own UART** — both entirely separate from the Ingenic T23 host SoC. The T23 talks to it only over
SDIO. See §2 of the parent doc.

## Step 1 — get a console: the ATBM has an AT command shell [LIVE]

The soldered ATBM UART (on this board: `COM11`, 115200 8N1) runs an interactive AT console.
`AT+HELP` lists ~180 commands. The two that matter for RE:

- `AT+rmem=<addr_hex>,<len_dec>` — read any address (little-endian words, **max ~160 B/reply**)
- `AT+wmem=<addr_hex>,<val_hex>` — write any address

Footguns: replies longer than ~8 hexdump lines overrun the chip's UART TX buffer and corrupt
bytes — use **128-byte chunks**. Mute async debug prints first with `AT+DEFAULT_DEBUG_ENABLE=0`
so they can't land inside a hexdump. Full command reference in [`at-console.md`](at-console.md).

**This UART is a lab instrument for ONE camera. It is not a deployment channel.** Everything that
must ship is done from the T23 over SDIO; the AT console is only used to discover and *verify*
those T23-side mechanisms.

## Step 2 — dump the flash [LIVE]

The SPI-NOR is XIP-mapped at `0x400000–0x5FFFFF` (2 MB). `tools/at_dump2.ps1` reads it in 128-B
chunks (~2 kB/s, ~18 min), auto-reopens on USB-serial dropouts, and verifies by re-reading 48
random chunks. A second independent dump was byte-identical. Result: `atbm_flash2.bin`,
md5 `5e9e017e915eea70cf816c8b49b34a82`. Firmware is **unencrypted** (`no-enc` in the boot banner).

## Step 3 — build an NDS32 disassembler [RE]

Neither radare2 nor capstone supports NDS32. binutils still has the target, so build objdump from
source: `tools/build_nds32_objdump.sh` (binutils-2.38, `--target=nds32le-elf`, ~10 min, objdump+gas
only). NDS32 is confirmed by the exception handler printing `IVB/PSW/IPSW/EDMSW/ITYPE`.

## Step 4 — find the runtime link base [RE]

The image is stored in flash but linked to run at a different VMA. `tools/find_delta.py` brute-forces
the offset that makes the most `sethi/ori`-reconstructed pointers land on string addresses; it finds
**`flash_addr = VMA + 0x380000`** (3542 hits). So the app disassembles cleanly with:

```
nds32le-elf-objdump -D -b binary -m nds32 -EL --adjust-vma=0x80000 atbm_flash2.bin
```

(The small bootloader front runs XIP at VMA `0x400000`; disassemble that part with
`--adjust-vma=0x400000`. There is also an in-ROM helper region based at `0x1400000` not present in
the dump.)

## Step 5 — annotate & analyse [RE]

`tools/nds32_analyze2.py` disassembles the whole image at the correct base, reconstructs every
`sethi/ori/movi/addi` constant load, and cross-references them against the string table — producing
a fully annotated disassembly (each pointer load tagged with the string or MMIO register it builds),
a string→xref map (2172 resolved), and an MMIO register list. That substrate is what made the
subsystem RE tractable. `tools/msgid_jumptable.py` walks the command dispatch jump table.

## Step 6 — verify against silicon [LIVE]

The static findings were checked by reading the actual registers/variables over the AT console:
GPIO pin map (`tools/at_gpioregs.ps1`), WDT registers (`tools/at_wdtregs.ps1`), the CRC-32 table,
`gp`, and the master_wdt timer object. Several static inferences were corrected this way — most
importantly, the master_wdt turned out to be **dormant** (see parent §14.4), overturning an earlier
"the ~56 s reset is the master_wdt" claim. **This is the whole point of having the AT console: it
turns previously-blind SDIO reasoning into something observable from the chip side.**

## What this bought us (summary — details in parent §14)

- The complete **message_mgr command interface** (the T23↔ATBM control surface): 532-byte packet,
  `[hdr][msg_id][crc32][len][payload]`, CRC-checked; full msg_id map.
- The **CRC fully reversed**: standard reflected CRC-32 (poly `0xEDB88320`), init `0xFFFFFFFF`,
  **no final inversion** — so any host can build byte-correct frames. `crc32(empty) = 0xFFFFFFFF`.
- The **WDT** register block (`0x16600000`, key `0x5AA5`) = the ~14.5 s startup wdt, idle in run.
- The **GPIO** controller (`0x16800000`): KEY0/RST = pin 17, PIR = pin 16, host-wake = pin 22 —
  all on the ATBM private bus, not T23-addressable.
- A **bricked-ATBM recovery** path over the same UART (bootloader `FLASH BIN received` mode).
- Correction: the ~56 s idle-U-Boot reset is **not** the app master_wdt; it is a lower-layer
  SDIO-keepalive host-alive (feedable, not in this dump). Bounded-chunk flash remains the fix.

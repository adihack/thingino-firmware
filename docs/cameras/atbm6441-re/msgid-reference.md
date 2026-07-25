# message_mgr command table (T23 → ATBM6441 over SDIO)

The T23 host controls the ATBM by posting **532-byte packets** to the `message_mgr` task (dispatcher
at VMA `0xaa956`). This is the same channel our Linux driver / `mcu_test` / `librtos` use (WSM
general-command `0x003A`, confirm `0x043A`), and the same numbering as the reversed "MCU command
protocol".

**Packet layout** (see parent doc §14.4b):

```
+0x00 u32  header/magic (0xACACCACA on the general-cmd path)
+0x04 u32  msg_id           <- selects the handler below
+0x08 u32  crc32            <- crc32(payload, len); if it mismatches, the frame is silently DROPPED
+0x0c u32  len              <- payload byte length
+0x10 ...  payload
```

CRC = standard reflected CRC-32 (poly `0xEDB88320`, init `0xFFFFFFFF`, **no final inversion**);
`crc32(empty) = 0xFFFFFFFF`. Table at `gp+0x2124 = 0x809aa4`.

**Dispatch:** `index = msg_id - 1`, valid `1..0x45`; jump table at `0xaa9d4`
(target = `0xaa9d4 + signed16(entry)`); out-of-range → `unsupported msg_id:0x%x`. Some handlers
translate the command into an **internal event** `0x1001..0x1032` consumed by a second dispatcher at
`0xab15c` (table `0xab184`, index = id − 0x1001).

Confidence column: **C** = handler purpose confirmed from referenced strings / traced code;
**H** = inferred from an older catalog / naming; **?** = handler located but not yet labelled;
**-** = routes to the "unsupported" default (unimplemented on this firmware).

> **Reproduce:** `tools/msgid_jumptable.py` walks the jump table from `atbm_flash2.bin`.

| msg_id | hex | handler | conf | meaning |
|---:|:---:|:---:|:---:|---|
| 1 | 0x01 | 0x0aae94 | C | post lp_mgr internal event 0x1003 |
| 2 | 0x02 | 0x0aaa8a | C | network / P2P send (ip,port,did,payload) |
| 3 | 0x03 | 0x0aabb8 | ? | handler @ 0x0aabb8 (not yet labelled) |
| 4 | 0x04 | 0x0aaac4 | C | network / P2P send |
| 5 | 0x05 | 0x0aab44 | C | cloud connect (ip,port,did,mode,code) |
| 6 | 0x06 | (default) | - | *unsupported / unimplemented* |
| 7 | 0x07 | 0x0aab76 | ? | handler @ 0x0aab76 (not yet labelled) |
| 8 | 0x08 | 0x0aab9c | ? | handler @ 0x0aab9c (not yet labelled) |
| 9 | 0x09 | 0x0aabd0 | C | PIR enable  (spi_cmd_set_pir_enable) |
| 10 | 0x0a | 0x0aac42 | C | PIR disable (spi_cmd_set_pir_disable) |
| 11 | 0x0b | 0x0aaca4 | C | PIR cooldown timer |
| 12 | 0x0c | 0x0aacac | ? | handler @ 0x0aacac (not yet labelled) |
| 13 | 0x0d | 0x0aacf6 | ? | handler @ 0x0aacf6 (not yet labelled) |
| 14 | 0x0e | 0x0aad34 | ? | handler @ 0x0aad34 (not yet labelled) |
| 15 | 0x0f | 0x0aad3c | ? | handler @ 0x0aad3c (not yet labelled) |
| 16 | 0x10 | 0x0aad7a | ? | handler @ 0x0aad7a (not yet labelled) |
| 17 | 0x11 | (default) | - | *unsupported / unimplemented* |
| 18 | 0x12 | 0x0aad82 | C | master_wdt STOP  (dormant timer; see 14.4) |
| 19 | 0x13 | 0x0aad8a | C | master_wdt DELETE (dormant timer; see 14.4) |
| 20 | 0x14 | 0x0aad92 | C | master_wdt SET-PERIOD+START (payload w0=seconds; ARMS it) |
| 21 | 0x15 | 0x0aad9c | C | master_wdt KICK / feed |
| 22 | 0x16 | 0x0aada4 | C | set_mcu_alarm |
| 23 | 0x17 | (default) | - | *unsupported / unimplemented* |
| 24 | 0x18 | 0x0aadf0 | ? | handler @ 0x0aadf0 (not yet labelled) |
| 25 | 0x19 | (default) | - | *unsupported / unimplemented* |
| 26 | 0x1a | 0x0aae3a | H | battery status/voltage (older catalog: 26) |
| 27 | 0x1b | 0x0aae60 | H | battery (older catalog: 27) |
| 28 | 0x1c | (default) | - | *unsupported / unimplemented* |
| 29 | 0x1d | 0x0aae66 | ? | handler @ 0x0aae66 (not yet labelled) |
| 30 | 0x1e | (default) | - | *unsupported / unimplemented* |
| 31 | 0x1f | 0x0aae7e | ? | handler @ 0x0aae7e (not yet labelled) |
| 32 | 0x20 | (default) | - | *unsupported / unimplemented* |
| 33 | 0x21 | 0x0aae82 | ? | handler @ 0x0aae82 (not yet labelled) |
| 34 | 0x22 | (default) | - | *unsupported / unimplemented* |
| 35 | 0x23 | (default) | - | *unsupported / unimplemented* |
| 36 | 0x24 | 0x0aae9c | C | GET version -> "1.2.5u1"   [was mis-numbered 0x23] |
| 37 | 0x25 | (default) | - | *unsupported / unimplemented* |
| 38 | 0x26 | (default) | - | *unsupported / unimplemented* |
| 39 | 0x27 | (default) | - | *unsupported / unimplemented* |
| 40 | 0x28 | 0x0aaec0 | ? | handler @ 0x0aaec0 (not yet labelled) |
| 41 | 0x29 | 0x0aaa68 | ? | handler @ 0x0aaa68 (not yet labelled) |
| 42 | 0x2a | (default) | - | *unsupported / unimplemented* |
| 43 | 0x2b | 0x0aaa5e | C | set master_mode (payload w0 = 0/1) -> ctx byte[0x99] |
| 44 | 0x2c | 0x0aaede | ? | handler @ 0x0aaede (not yet labelled) |
| 45 | 0x2d | (default) | - | *unsupported / unimplemented* |
| 46 | 0x2e | 0x0aaee8 | ? | handler @ 0x0aaee8 (not yet labelled) |
| 47 | 0x2f | 0x0aaef6 | ? | handler @ 0x0aaef6 (not yet labelled) |
| 48 | 0x30 | (default) | - | *unsupported / unimplemented* |
| 49 | 0x31 | (default) | - | *unsupported / unimplemented* |
| 50 | 0x32 | 0x0aade2 | ? | handler @ 0x0aade2 (not yet labelled) |
| 51 | 0x33 | 0x0aae26 | ? | handler @ 0x0aae26 (not yet labelled) |
| 52 | 0x34 | 0x0aaf0e | C | MCU factory reset |
| 53 | 0x35 | (default) | - | *unsupported / unimplemented* |
| 54 | 0x36 | (default) | - | *unsupported / unimplemented* |
| 55 | 0x37 | 0x0aaf28 | C | wifi stop  (SPICMD_SET_WIFI_STOP -> internal 0x1023) |
| 56 | 0x38 | 0x0aaf40 | C | set static IP (MSG_SET_STATIC_IP -> internal 0x1024) |
| 57 | 0x39 | 0x0aaf64 | C | get wifi DCXO |
| 58 | 0x3a | 0x0aaf94 | C | set wifi DCXO |
| 59 | 0x3b | 0x0ab05e | C | set RTC mode |
| 60 | 0x3c | 0x0aae86 | ? | handler @ 0x0aae86 (not yet labelled) |
| 61 | 0x3d | 0x0aaff0 | C | set battery param (full/low/shut/c20/c80) |
| 62 | 0x3e | 0x0ab028 | C | get battery param |
| 63 | 0x3f | 0x0aaafe | C | network / P2P send |
| 64 | 0x40 | 0x0ab070 | C | wifi start_ap (-> internal 0x1031) |
| 65 | 0x41 | 0x0ab0a0 | C | wifi stop_ap  (-> internal 0x1032) |
| 66 | 0x42 | 0x0ab0f8 | ? | handler @ 0x0ab0f8 (not yet labelled) |
| 67 | 0x43 | 0x0aacec | C | g_bat_inc_interval |
| 68 | 0x44 | 0x0ab0e6 | C | g_bat_inc_interval |
| 69 | 0x45 | 0x0ab0c6 | C | get battery param |

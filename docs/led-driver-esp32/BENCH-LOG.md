# LED driver — bench log

## Session 1 — 2026-08-19: first board built, WLED RS485 validated

**Board 1** (SparkFun ESP32 LoRa 1-CH Gateway): WS2801 terminal (5V·GND·DATA·CLOCK bottom→top),
74AHCT125 all four channels wired (bus 2 unused so far), MAX3485 on 5/19/18, LM1117 logic rail.
Runs `led_driver_wifi` (gitignored override: WiFi + `RS485_BRIDGE_ADDRESS=96`) on the
`led-driver-board-profile` WLED branch. On Acropolis at **192.168.1.58**, RS485 **address 96**.
Currently configured 200 px, 8 A brightness limit, rainbow-cycle as boot preset 1.

**Validated:**
- WS2801 output (50→200 px) with baked-defaults boot: patterns on power-up, no UI needed.
- **First-ever WLED RS485 hardware run** — full chain on the first wired attempt:
  UDP probe → bridge(96) → RS485 @28000 → legacy module 72 → poll response relayed back to the
  probe. VALUE pulses on 72's output 0 handled (`hmtl_handle_msg` ×2). Bridge counters and 72's
  `framing_errors:0 rejects:0` agree. Tx-evidence test (counter increments with bus unwired) run
  before wiring — worth keeping in the bring-up sequence for future boards.

**Design decisions this session:**
- One 800-px chain on bus 1 preferred over 2×400: only the first clocked bus gets WLED's
  hardware-SPI driver; a second is bit-banged (WLED's own WS2801 flicker warning). 2×400 stays a
  bench experiment; wiring supports both.
- ~99 Hz wire ceiling at 2 MHz for 800 px; WLED's 42 FPS target is the practical limit.
- Series resistors: **91 Ω** into Cat6A runs (source termination ≈ 100 Ω pair − ~18 Ω AHCT
  drive); the original 150 Ω resistors move to the fire controller's ~6-inch LED leads where
  matching is irrelevant. Signal runs (6–10 ft) over Cat6A pairs: signal + ground-return per
  pair; never LED power over the Cat.

**Gotchas re-confirmed:** saved cfg.json beats compile defaults (factory-erase before first boot
of a reflashed board, or push runtime cfg); `DEFAULT_MODE` compile override did not survive
first-boot segment creation (boot preset used instead — unexplained, low priority).

**Also validated (session close):** blink PROGRAMs to module 71 outputs 0-3 at four rates via
the bridge; program-cancel + value-off cleanup. One frame of a 4-frame burst (150 ms spacing)
was silently lost and succeeded on retry — one-shot UDP has no delivery guarantee; scripts
should verify or retry (motivates the filed REST-endpoint task). 91 Ω series resistors
installed. **Prototype complete 2026-08-19** — board 1 is a working WLED+RS485 LED controller.

**Next:** second board build · 800-px strand + Cat6A run (on order) · 2 MHz clock validation
with live FPS · filed tasks: HMTL Command Server vs ESP32 (HMTL_Ecosystem), REST HMTL endpoint
(WLED_dev, P4) · addresses 96+ for this family (71/72 trigger boards, 129 fire controller).

## Session 2 — 2026-08-21 — first production board: Lightbringer Ceiling

**Board 2 (first non-breadboard build) flashed and deployed** as HMTL addr 97,
`http://lightbringer-ceiling.local` on "CBCI-0970" — full details in `docs/DEVICES.md`.
Flashed `[env:led_driver_ceiling]` (gitignored override: baked WiFi creds, addr 97,
SERVERNAME/MDNS_NAME) over USB; fresh board so compile defaults seeded cleanly; runtime
cfg set 800 px @ 2 MHz, ABL 8 A, rainbow boot preset. RS485 bridge verified in cfg
(uart2, rx5/tx19/en18, 28000 baud, UDP 21331) — not yet exercised on a bus from this board.

**Also this session (WLED_dev `camera-ledmap-tool` branch):** camera-based LED position
mapper (`tools/ledmap_camera`) written for mapping the ceiling's triangle lattice to a
WLED 2D ledmap; adversarially reviewed against firmware source and hardened (compact
`"map":[` serialization required by the firmware's literal parser; identity-map
neutralize before re-sweeps; `rSeg` after live reload; crash-safe sweep; gap-based
auto-threshold). Solve validated on a synthetic 800-px serpentine triangle lattice.
Mapping session pending: iPhone-on-floor Continuity Camera (camera index 1 last
enumerated), array on ceiling.

**Interim:** "Lightbringer Test" (old WLED Strip board, data 4/clock 16) was reflashed
to current firmware and configured 800 px / 8 A as a stopgap driver for the installed
LEDs; superseded by Lightbringer Ceiling.

# WLED LED driver — SparkFun ESP32 LoRa 1-CH Gateway — wiring

Two identical modules driving WS2801 pixels, running WLED with the `rs485_bridge` usermod.
Same board, regulator, level shifter, and RS485 transceiver as the fire controller —
[docs/fire-controller-esp32/WIRING.md](../fire-controller-esp32/WIRING.md) is the authority for
everything shared (LM1117 pinout/tab=VOUT, the no-5V-pad / USB-3V3 caution, MAX3485 wiring
detail, 74AHCT125 handling). This doc covers what differs: no MPR121, no MCP23017, and **two**
WS2801 buses through all four shifter channels.

## 1. Pin map

| Function        | GPIO        | Notes                                       |
| --------------- | ----------- | ------------------------------------------- |
| RS485 DE/RE     | **18**      | DE and RE tied together                     |
| RS485 RX ← RO   | **5**       | strapping pin — safe (RO idles high)        |
| RS485 TX → DI   | **19**      |                                             |
| WS2801 #1 DATA  | **25**      | shifter ch1 (same pair as fire controller)  |
| WS2801 #1 CLOCK | **23**      | shifter ch2                                 |
| WS2801 #2 DATA  | **21**      | shifter ch3 (freed: no I2C on this build)   |
| WS2801 #2 CLOCK | **22**      | shifter ch4                                 |
| spare           | 4           | freed: no MPR121 IRQ                        |

**Off limits — LoRa (on-board radio, populated whether used or not):** `12` MISO, `13` MOSI,
`14` SCK, `16` CS, `26` DIO0, `33` DIO1, `32` DIO2. **Leave free:** `27` (unresolved — see the
fire-controller doc). **Also avoid:** 0, 2, 15 (strapping) · 1, 3 (console) · 6–11 (flash) ·
34–39 (input-only).

WLED pin assignments are **runtime config** (Settings → LED Preferences: two WS2801 buses with
the pins above). The rs485_bridge UART/pins/baud are also runtime config (UART 2, RX 5, TX 19,
EN 18, **28000 baud**), applied on the next boot.

## 2. One bus of 400 vs two buses of 2×400

WS2801 is clocked at 24 bits/pixel; the stable clock rate is set by the worst wire run, not the
chip spec. Ballpark frame-serialization times:

| Layout        | Bits   | @ 1 MHz | @ 500 kHz |
| ------------- | ------ | ------- | --------- |
| 1 × 400       | 9,600  | ~10 ms (≈100 Hz ceiling) | ~19 ms (≈52 Hz) |
| 1 × 800       | 19,200 | ~19 ms (≈52 Hz)          | ~38 ms (≈26 Hz) |
| 2 × 400       | 19,200 total | ~19 ms (≈52 Hz)    | ~38 ms (≈26 Hz) |

**Driver asymmetry (from WLED's `bus_wrapper.h`):** on ESP32 only the **first** 2-pin bus gets
the hardware SPI driver (`_2PchannelsAssigned == 0 → isHSPI`); a second clocked bus is
**bit-banged**, and the source comment singles out WS2801 as "prone to flickering if bit-banged
too slow" (500 µs latch timeout). Hardware SPI routes through the GPIO matrix to ANY pins with
no penalty below 40 MHz, so the chosen pins already are "native SPI" in every way that matters —
the IOMUX pin sets themselves are unavailable here anyway (VSPI natives = 5/18/19/23, our RS485
map + bus-1 clock; HSPI natives = 12/13/14/15, wired to the LoRa radio).

**Recommendation:** wire all four shifter channels (costs nothing), but default to **one
800-px chain on bus 1** — everything on hardware SPI + DMA. Treat the 2×400 split as a bench
experiment: keep it only if the bit-banged bus 2 shows no flicker under real load. WLED pushes
buses sequentially, so the split does not halve frame time anyway; its benefits are shorter
electrical runs (higher stable clock), independent failure domains, and injection layout.

**Installed-geometry decision (2026-08):** the two 400-px strands are already installed **side
by side and must display identically**, with **~24 ft between the last pixel of strand 1 and the
first pixel of strand 2**. Side-by-side-identical is the deciding constraint and it rules out
both alternatives:
- **2×400 two outputs** — bus 2 is bit-banged; any flicker/timing difference vs bus 1's
  hardware-SPI output would show as a visible seam between adjacent strands.
- **Two independent controllers on plain WLED sync** — WLED device-sync is *state* sync (each
  device animates locally from synced params), so dynamic effects **drift in phase** → a visible
  offset side by side. Two controllers would only match if *frame-locked* (streamed pixels / a
  master→slave frame push), which is real code, not a config toggle.

Chosen approach: **single 800-px chain on bus 1**, with the 24 ft inter-strand gap bridged by a
**differential clock/data extender (§8)**. One render engine, one clock domain → inherently
frame-locked, physically extended across the gap — the best side-by-side match *and* the least
code. Clock rate is runtime-tunable (§7), so the extender's reliable ceiling is found by
sweeping, not reflashing.

## 3. Power — the LEDs dominate everything

**400 WS2801 pixels ≈ 24 A at 5 V full-white worst case; 800 ≈ 48 A.** The board's LM1117 path
is for logic only — **LED power never touches the board.**

```
   5V LED supply (sized for the strips, see below)
        ├────────────────────────────► WS2801 strips, injected every ~100 px
        ├────────────────────────────► 74AHCT125 pin 14 (VCC, 5V logic side)
        └──► LM1117T-3.3 ──► 3.3V ──┬─► ESP32 "3V3" pin
              10µF in + out         └─► MAX3485 VCC

   GND ── everything: LED supply, regulator, ESP32, MAX3485, shifter,
          strip grounds AT EVERY INJECTION POINT, RS485 bus ground
```

- Size the supply for the *configured* ceiling, not the theoretical one: set WLED's brightness
  limiter (Settings → LED Preferences → "Enable automatic brightness limiter") to the supply's
  real rating minus margin, per bus.
- Inject 5V+GND at the head, tail, and every ~100 px; a 400-px run fed from one end only will
  brown out and redshift at the far end regardless of supply size.
- Fuse each injection feed. Keep injection wiring ≥ 16 AWG for multi-amp runs.
- Common ground is load-bearing three ways: LED data references, RS485 bus reference, and the
  logic rail. Star it at the supply.

## 4. Level shifter — 74AHCT125, all four channels

| Channel | In (ESP32) | Out (strip) | Signal |
|---|---|---|---|
| 1 (pins 1A/1Y) | GPIO 25 | bus 1 DATA  | |
| 2 (2A/2Y)      | GPIO 23 | bus 1 CLOCK | |
| 3 (3A/3Y)      | GPIO 21 | bus 2 DATA  | |
| 4 (4A/4Y)      | GPIO 22 | bus 2 CLOCK | |

All four /OE pins (1, 4, 10, 13) to GND. VCC (14) = 5V, GND (7) = GND, 100 nF decoupler across
VCC/GND at the chip. Optional but cheap insurance on 400-px runs: 33–100 Ω series resistor on
each Y output at the shifter, and run each CLOCK twisted with a ground return to the strip.

## 5. RS485 — identical to the fire controller

MAX3485 at 3.3V: RO→GPIO5, DI←GPIO19, DE+/RE tied→GPIO18, A/B to the bus (A↔A, B↔B — a swap is
silent; the fire-controller doc's §5 has the voltage-fingerprint diagnosis procedure), bus
ground common. 28000 baud 8N1 (`RS485Socket::DEFAULT_BAUD`).

## 6. Firmware

WLED_dev `ampworks`-family env with `USERMOD_RS485_BRIDGE` (`-D RS485_HARDWARE_SERIAL=2`);
these boards have **no MPR121**, so the build for them should not enable the mpr121 usermod.
Bridge + LED pins/baud are runtime config per §1. HMTL addresses for the two modules: TBD
(71/72 are the trigger boards, 129 the fire controller).

## 7. WS2801 SPI clock speed — runtime-tunable, not hardcoded

The clocked-SPI rate is **configurable at runtime, no reflash** (verified in WLED 16.0.1 source):

- **Default 2 MHz** if unset — `bus_manager.cpp:153` `_frequencykHz = bc.frequency ? bc.frequency : 2000U`.
- **Per-bus, in kHz.** JSON key **`hw.led.ins[N].freq`** (`cfg.cpp:239` reads it, `:1002` writes
  it back). Set via a POST to **`/json/cfg`** or by editing cfg.json — e.g. `freq: 1000` = 1 MHz,
  `2000` = 2 MHz. Also exposed in the **LED Preferences UI** clock-speed field (`set.cpp:209`, the
  `SP` arg).
- **Label caveat:** the UI text and code comments say *"DotStar & PWM"*, but the bus wrapper routes
  WS2801 (`I_HS_WS1_3`) through the **same** `beginDotStar → SetMethodSettings(NeoSpiSettings(clock))`
  path as DotStar (`bus_wrapper.h:414`) — so it **does** apply to WS2801 despite the naming. Confirm
  empirically on first run: set 1 MHz, scope the clock line, expect 1 MHz not 2.
- **Ignore** the `// 1 MHz clock` at `bus_manager.cpp:397` — inside `#ifdef ESP8266`, irrelevant to
  this ESP32.
- **Frame-rate headroom:** 800 px @ 1 MHz ≈ 19 ms ≈ **52 Hz**, still above WLED's 42 FPS target, so
  dropping to 1 MHz for signal-integrity margin over the extender (§8) costs no usable frame rate.

**Bench step:** after wiring §8, **sweep `freq` live** (2000 → 1000) over the differential link and
watch the far strand for pixel corruption; pick the highest clean rate. This makes the
transceiver-vs-clock tradeoff a runtime A/B, not a firmware cycle.

## 8. 24 ft inter-strand differential extension (single-chain across the gap)

Chosen per §2: one 800-px chain, with the ~24 ft gap between strand 1's end and strand 2's start
bridged by differential line drivers. The signals crossing the gap are the **5 V CKO/SDO** off the
**last WS2801 of strand 1** into the **CKI/SDI of the first WS2801 of strand 2**. A WS2801 output
can't drive 24 ft of line single-ended at MHz rates; differential drivers extend it cleanly.

**Topology (simplex, one direction):** end of strand 1 → convert CKO and SDO each to a differential
pair (driver) → 24 ft twisted pair → convert back to single-ended (receiver) → CKI/SDI of strand 2.

**Transceiver choice — and the level-shift consequence:**

| Option | Rail | Speed | Level shifting | Chips |
|---|---|---|---|---|
| **MAX485** | 5 V | 2.5 Mbps | **None** — 5 V matches WS2801 both ends | 4 (drv+rcv × 2 signals) |
| MAX3485 | 3.3 V | 10 Mbps | **Both ends** — down 5→3.3 V at DI, up 3.3→5 V at RO (WS2801 V_IH ≈ 3.5 V) | 4 + 3.3 V reg + shifters |
| **AM26LS31 / AM26LS32** (RS-422 quad) | 5 V | ~10 Mbps | **None** | 2 (one quad driver + one quad receiver) |

- **Prefer a 5 V part:** MAX485 @ 1 MHz (no regulator, no shifting; 52 Hz > target), or AM26LS31/32
  @ 2 MHz (no regulator, no shifting, 2 chips, purpose-built for clock+data extension). **Avoid
  MAX3485 here** — its 3.3 V rail forces both a regulator and level shifting at *both* ends. (If a
  3.3 V part is unavoidable, the board's existing **74AHCT125** does the far-end up-shift.)

**Wiring detail:**
- Tap CKO + SDO at the last WS2801 of strand 1 (leads in inches) into the driver inputs.
- Enables static: driver end active (`DE` high / `RE` don't-care), receiver end active — simplex,
  no direction switching.
- **Terminate each pair 100–120 Ω at the receiver (far) end.** 120 Ω standard; 100 Ω matches Cat6
  more exactly — either is fine at 24 ft / 1–2 MHz.
- Receiver outputs → CKI/SDI of the first WS2801 of strand 2.
- **Power each transceiver set from the LOCAL 5 V injection** already present at each strand — no
  logic power over the gap.

**Cabling — same Cat6/6A as the bus leads, and a good fit here:**
- **One twisted pair = CLOCK differential; a second twisted pair = DATA differential.** Keep each
  signal on **one** pair — never split a differential signal across pairs, never share a pair
  between clock and data.
- Both pairs in the **same Cat6 run are length-matched** → minimal clock/data skew, which is the
  one thing that breaks a clocked differential link. (This is why one Cat6 run beats two separate
  cables.)
- Use a **third pair as a ground bond** between the two ends. Differential still needs a
  common-mode reference (RS485/422 range is limited); grounds are already common via power
  injection, but bond a conductor anyway.
- **Never run LED power over Cat6** (unchanged rule — the gap carries only clock pair + data pair
  + ground).

**Result:** perfect side-by-side matching (single render, single clock domain) with the physical
reach of two strands — no bit-bang flicker, no inter-controller sync/drift.

### 8.1 Build guide — ST485BN / MAX485CPA (chips on hand, 20–24 ft Cat6)

**Part choice:** ST485BN and MAX485CPA are spec-equivalent for this job — 5 V rail, 2.5 Mbps,
~30 ns prop delay, and the **identical DIP-8 pinout** — so this guide applies verbatim to either.
Use **four of the same part** if inventory allows; if mixing, keep each *signal path* homogeneous
(both CLOCK chips one type, both DATA chips the other). **Design clock: 1 MHz** (`freq: 1000`,
§7) — 2.5 Mbps parts are comfortable there and marginal at 2 MHz; try 2 MHz as a free experiment,
expect to land at 1 MHz. 800 px @ 1 MHz ≈ 52 Hz > WLED's 42 FPS target, so no visible cost.

**DIP-8 pinout (both parts identical):**

```
        ┌───u───┐
   RO  1│       │8  VCC (5V)
  /RE  2│       │7  B   (inverting)
   DE  3│       │6  A   (non-inverting)
   DI  4│       │5  GND
        └───────┘
```

**Enable mnemonic — driver end: pins 2+3 tied HIGH. Receiver end: pins 2+3 tied LOW.**
(Simplex, permanent: DE high enables the driver / RE̅ high disables the unused receiver, and
vice-versa at the far end. The enables never toggle — this is a one-way link, not a bus, so no
direction-control GPIO and no fail-safe bias resistors are needed. The driver is always on, so
the line is never idle/undriven.)

**Four chips total: 2 drivers at the strand-1 end, 2 receivers at the strand-2 end** — one each
for CLOCK and DATA.

**Strand-1 END — two DRIVER chips (one CLOCK, one DATA):**

| Pin | Connect to |
|---|---|
| 4 DI | ← WS2801 output: CKO (clock chip) / SDO (data chip), last pixel of strand 1 — leads in inches |
| 3 DE | → VCC (5 V) — driver permanently enabled |
| 2 RE̅ | → VCC (5 V) — unused receiver disabled |
| 1 RO | n/c |
| 8 VCC | → **local** 5 V injection at strand 1 |
| 5 GND | → local GND |
| 6 A / 7 B | → one Cat6 pair (A=tip, B=ring), out to the far end |
| — | 100 nF from pin 8 to pin 5, at the chip |

**Strand-2 START — two RECEIVER chips (one CLOCK, one DATA):**

| Pin | Connect to |
|---|---|
| 6 A / 7 B | ← the matching Cat6 pair from the driver end |
| 2 RE̅ | → GND — receiver permanently enabled |
| 3 DE | → GND — unused driver disabled |
| 4 DI | → GND (tie off, unused) |
| 1 RO | → WS2801 input: CKI (clock chip) / SDI (data chip), first pixel of strand 2 — leads in inches |
| 8 VCC | → **local** 5 V injection at strand 2 |
| 5 GND | → local GND |
| 6–7 | **120 Ω across A–B** (termination — receiver end only) |
| — | 100 nF from pin 8 to pin 5, at the chip |

**Cat6 pair assignment (20–24 ft run, one cable):**

| Cat6 pair | Carries | Notes |
|---|---|---|
| Pair 1 (e.g. blue) | CLOCK A/B | one differential signal = one twisted pair |
| Pair 2 (e.g. orange) | DATA A/B | keep clock and data on **separate** pairs |
| Pair 3 (e.g. green) | GROUND bond | tie both conductors together, both ends, → GND each end |
| Pair 4 (e.g. brown) | spare | leave for a 2nd ground or a future signal |

- **Never split A and B across different pairs**, and never share a pair between clock and data —
  A/B of one signal must be the two wires of the *same* twisted pair (that twist is what rejects
  common-mode noise from nearby solenoid/12 V wiring).
- Clock and data pairs share the same cable → equal length → clock/data skew is a few ns against a
  500 ns (1 MHz) bit window. That skew margin is why this works; it evaporates if you ever run clock
  and data on two *different* cables.
- **Ground bond is required, not optional** — RS-485 is differential but still needs the two ends
  within its ±7 V common-mode window. Power injection makes grounds nominally common; the bond
  guarantees it.
- **No LED power on the Cat6.** The gap carries clock pair + data pair + ground, nothing else.

**No series resistors on the short hops** (WS2801→DI and RO→WS2801 are inches, not transmission
lines). The only termination in this stage is the 120 Ω at each receiver. The 91 Ω source
resistors from §4 stay where they are — on the controller→strand-1 leads, a different segment.

**Bring-up sequence:**
1. Wire and power both ends (local 5 V each). With WLED idle, drivers hold the lines at the
   WS2801 idle level — a scope on A–B at the receiver should show a clean differential idle.
2. Set the bus to **`freq: 2000`** (2 MHz) first as a free experiment — it may pass at 24 ft.
   Push full-white + a fast effect; watch the **strand-2** pixels for sparkle/wrong colours.
3. If strand 2 shows corruption, drop to **`freq: 1000`** (1 MHz) — the design point. Re-test.
   1 MHz gives ~52 Hz refresh, above WLED's 42 FPS, so there is no visible cost to running there.
4. Confirm strand 1 and strand 2 are pixel-identical side by side under motion — that is the whole
   point of the single-chain topology, and the pass criterion for this stage.

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

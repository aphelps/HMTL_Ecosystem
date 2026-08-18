# Fire Controller brains — ESP32 build

Working notes for the ESP32-based Fire Controller: a SparkFun ESP32 LoRa 1-CH Gateway driving
WS2801 LEDs, reading an MPR121 capacitive touch breakout, talking to legacy HMTL modules over
RS485, and linking to the TouchMatrix (identical hardware) over LoRa.

## Contents

| File | What it covers |
|---|---|
| **[STARTUP.md](STARTUP.md)** | **Start here at the bench.** Pre-flight checks, the three source/build changes, staged bring-up with pass/fail criteria, reference numbers, known traps |
| [WIRING.md](WIRING.md) | Part identification, the GPIO conflict with the TouchController PCB design, the revised pin map, wiring diagram, and the WS2801 logic-level risk |
| [OTA.md](OTA.md) | Why OTA is needed (USB/3V3 conflict), what exists, and the plan — HTTP `/update` primary (espota is blocked on this laptop), with ignition-specific guards |
| [BENCH-LOG.md](BENCH-LOG.md) | **Current board state**, what was measured and concluded each session — including retracted conclusions, kept with their retractions |
| [RS485-BRIDGE-BRINGUP.md](RS485-BRIDGE-BRINGUP.md) | RS485 bus facts (28000 baud), the WLED `rs485_bridge` usermod settings, the cached-`libdeps` build trap, and the address registry collision |

## The short version

- **Board:** SparkFun ESP32 LoRa 1-CH Gateway, **ESP32-WROOM-32E** — no PSRAM, so WLED's
  GPIO 16/17 PSRAM restriction does not apply here.
- **This is the first ESP32 fire-control hardware actually built.** The
  `HMTL_ESP32_TouchController` PCB exists only as a KiCad schematic and has never been fabricated
  or tested, so treat it as design intent to copy, not as a validated reference.
- **That design's pin map does not fit this board.** WS2801 DATA/CLOCK (13/14) and RS485 RX (16)
  collide with the LoRa radio's SPI bus and chip-select. Since the LoRa link to the TouchMatrix is
  required, the radio wins and the peripherals move.
- **Revised pins:** see [WIRING.md](WIRING.md) §3 — the single source of truth. Not repeated
  here; this front page drifted out of sync with it once already.
  Four values change from the schematic; IRQ, I2C and DE/RE stay put.
- **GPIO 27 is deliberately unused** — sources disagree on whether it is the LoRa reset, and the
  design does not need it. See WIRING.md §3.
- **WS2801 is driven through a 74AHCT125 level shifter** (3.3V → 5V), matching the PCB design.
  `AHCT` specifically; see WIRING.md §8.
- **RS485 bus runs at 28000 baud 8N1**, not 57600 or 115200. Do not read the rate off an EEPROM
  config dump; that field is inert.

## Open questions

1. **Firmware target** — HMTL_Fire_Control (`-e touchcontroller_esp32`) or WLED + the
   `rs485_bridge` usermod? Same wiring, different build and bring-up path.
2. **LoRa support does not exist yet.** `DISABLE_LORA` is a build flag in
   `HMTL/platformio/HMTL_Module/platformio.ini` with no implementation behind it, and there is no
   RFM95/LoRa code anywhere in the local tree. ArduinoLibs has `Socket`, `RS485Utils`,
   `RFM69Socket` and `XBeeSocket` — a `LoRaSocket` would be new work modelled on `RFM69Socket`.
   Possible that prior radio work is **RFM69** (different chip, same Socket pattern) rather than
   LoRa; unresolved.
3. **GPIO 27** — settle from the schematic in `sparkfun/ESP32_LoRa_1Ch_Gateway/Hardware` if a
   seventh GPIO is ever needed.

## Resolved

- **WS2801 3.3V logic** — 3.3V is out of spec against a ≈3.5V threshold. Decided: buffer DATA and
  CLOCK through a **74AHCT125**, matching the PCB schematic. WIRING.md §8 has the DIP-14 breadboard
  pinout. Do not substitute a BSS138 bidirectional converter — those are for I2C and too slow for a
  clocked pixel bus.

## Related

- Trigger boards **71** and **72** (HMTL Trigger Board v3, hardware_version 5) were configured and
  verified as the RS485 peers for this work — see `HMTL/addresses.txt` (on `main`, PR #11 / `b4214c8`).
- The existing ESP32 touch controller pin map is documented at
  `HMTL_Fire_Control/platformio/HMTL_Fire_Control_Wickerman/platformio.ini:66-81`.

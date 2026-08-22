# HMTL / WLED device registry

Known hardware, addresses, and where each lives. Update when a board is
built, re-addressed, or retired.

## RS485 / HMTL address map

| Addr | Device | Board | Role |
|---|---|---|---|
| 71 | Trigger board 1 | AVR HMTL module | Poofer trigger + outputs |
| 72 | Trigger board 2 | AVR HMTL module | Poofer trigger + outputs; bench gateway via FTDI |
| 96 | LED driver prototype | SparkFun ESP32 LoRa 1-CH Gateway (breadboard) | WLED `led_driver_wifi` env, WiFi "Acropolis", first WLED+RS485 board |
| 97 | **Lightbringer Ceiling** | SparkFun ESP32 LoRa 1-CH Gateway (first non-breadboard build) | WLED `led_driver_ceiling` env — see below |
| 129 | Fire controller | SparkFun ESP32 LoRa 1-CH Gateway | HMTL_Fire_Control_Wickerman (MPR121 touch, MCP23017 switches) |

Address conventions: 71/72 trigger boards, 129 fire controller, 96+ WLED
LED-driver family.

## Lightbringer Ceiling (added 2026-08-21)

First production (non-breadboard) WLED LED-driver board. Drives the 800-px
WS2801 ceiling array (triangle lattice, ~24 ft differential inter-strand
extension per `led-driver-esp32/WIRING.md` §8).

- **Firmware:** WLED_dev `[env:led_driver_ceiling]` (in gitignored
  `platformio_override.ini`; extends `led_driver`). No MPR121; RS485 bridge on.
- **Network:** WiFi "CBCI-0970", `http://lightbringer-ceiling.local`
  (10.1.10.163 at last check). Name + mDNS hostname are compile-baked.
- **LEDs:** 800×WS2801, data GPIO 25 / clock GPIO 23 (74AHCT125 shifted),
  color order **BRG**, ABL 8000 mA @ 55 mA/LED, rainbow boot preset 1.
- **Bus clock: 1.5 MHz standard** (`hw.led.ins[0].freq: 1500`). Bench result
  2026-08-21: 2 MHz flickered near the end of strand 1 on the installed
  array, 1 MHz and 1.5 MHz clean — 1.5 MHz is the validated operating
  point (~52 fps wire ceiling, above WLED's 42 fps target).
- **RS485:** MAX3485, RX 5 / TX 19 / EN 18, 28000 baud, HMTL addr **97**,
  bridge UDP port 21331.
- **Audio: UDP Sound Sync RECEIVE is standard config** — no local mic; a
  mic-equipped WLED device on the same network sends (multicast
  239.0.0.1:11988, v2 format). **PENDING: board went offline 2026-08-21
  before this was applied** — run when next reachable:
  `curl -X POST http://lightbringer-ceiling.local/json/cfg -H 'Content-Type: application/json' -d '{"um":{"AudioReactive":{"enabled":true,"sync":{"port":11988,"mode":2}}}}'`
  (mode bitfield: 1=send, 2=receive; exactly one sender per network.)
- **Context:** the Lightbringer is a Burning Man mutant vehicle — its
  network/location changes. On-site WiFi: dedicated travel router
  preferred; ESP32/WLED-AP fallback works for a handful of devices (see
  bench log).
- **Pending:** camera ledmap session (`WLED_dev tools/ledmap_camera`,
  iPhone-on-floor Continuity Camera) to map the triangle lattice to a 2D
  grid. Apply the audio-receive cfg above.

## Other WLED devices (not on the HMTL bus)

| Name | Host | Notes |
|---|---|---|
| Lightbringer Test | `10.1.10.112` ("WLED Strip" hardware) | ESP32, WS2801 on data 4 / clock 16; temporarily configured for the 800-px ceiling array (superseded by Lightbringer Ceiling) |
| Trancender | `10.1.10.227` | Stock WLED 16.0.1, 54×24 matrix, audio-sync sender |

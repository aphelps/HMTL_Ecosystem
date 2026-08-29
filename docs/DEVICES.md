# HMTL / WLED device registry

Known hardware, addresses, and where each lives. Update when a board is
built, re-addressed, or retired.

## RS485 / HMTL address map

| Addr | Device | Board | Role |
|---|---|---|---|
| 71 | Trigger board 1 | AVR HMTL module | Lightbringer vehicle: igniter/pilot/large poofer |
| 72 | Trigger board 2 | AVR HMTL module | Lightbringer vehicle: 4 accumulator poofs (was bench gateway via FTDI) |
| 96 | LED driver prototype | SparkFun ESP32 LoRa 1-CH Gateway (breadboard) | WLED `led_driver_wifi` env, WiFi "Acropolis", first WLED+RS485 board |
| 97 | **Lightbringer Ceiling** | SparkFun ESP32 LoRa 1-CH Gateway (first non-breadboard build) | WLED `led_driver_ceiling` env — see below |
| 129 | Fire controller | SparkFun ESP32 LoRa 1-CH Gateway | HMTL_Fire_Control_Wickerman (MPR121 touch, MCP23017 switches) |
| 128 | Classic fire controller (2014 wooden box) | AVR nano328 | `firecontroller_lightbringer` env, reflashed 2026-08-28 targeting the vehicle's poofers 71/72 + lights 67 (interim until new touchcontroller board is built) |

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
  network/location changes.

## Lightbringer vehicle network

- **SSID "Lightbringer"** — credentials in the gitignored
  `WLED_dev/WLED/platformio_override.ini` (never in committed files).
  Every vehicle WLED device gets it in its known-network list (runtime
  `nw.ins`) alongside its bench SSID.
- **Router: TP-Link Deco X50-Outdoor** (AX3000, IP65). Deployment notes
  from 2026-08 research:
  - **App-first device**: setup REQUIRES the Deco app + TP-Link ID +
    working internet — do ALL setup and updates at home before the burn.
    The web UI (tplinkdeco.net / 192.168.68.1) is diagnostics-only.
  - **On-playa WAN: Starlink is available** (camp has connectivity), so
    cloud-dependent app management keeps working when the Deco's WAN is
    fed from it (Starlink ethernet adapter → Deco WAN port). Still
    complete setup before departure; if Starlink is down the mesh + LAN
    keep working (status LED goes red, ignore it) and the app manages
    locally from a phone joined to the Deco WiFi.
  - **ESP32 clients**: disable band steering or use the IoT/2.4GHz-only
    network feature for the "Lightbringer" SSID; set security to
    **WPA2-PSK only** (WPA2/WPA3-mixed breaks ESP32 joins); do NOT enable
    client/IoT isolation (it would kill UDP multicast audio sync and
    phone→WLED control).
  - **Power**: 802.3at PoE+ (≤18 W) or its AC adapter — from vehicle 12 V,
    use a 12→48 V PoE+ injector or an inverter.
  - **Failover**: a spare ESP32 running a WLED AP with the SAME
    SSID/password substitutes with zero device reconfig (≤4 clients).
- **Router VERIFIED 2026-08-22** (home bench, Deco WAN fed from Acropolis
  LAN as the Starlink stand-in): ESP32 joins on 2.4 GHz/WPA2 (5 GHz
  disabled on the Deco in lieu of a band-steering toggle; -47 dBm);
  clients get internet via Deco NAT; **UDP multicast audio sync delivered**
  (synthetic v2 sender `WLED_dev tools/send_audiosync.py` → TouchTower
  "receiving", GEQ reacting); local HTTP control works. Deco auto-picked
  2.4 GHz **channel 3** — pin to 1/6/11 in the app for playa if exposed.
  Deco LAN is 192.168.68.0/22, gateway .68.1.
- **Audio sender for the vehicle: UNDECIDED** — TouchTower's mic, or a
  dedicated low-profile LED-less ESP32 + I2S mic (INMP441-class) as a
  mic-only sender node. Exactly one sender on the network.

## TouchTower

WLED touch device: 5×5 APA102 matrix (pins 32/33), MPR121 touch (I2C
0x5A on SDA 19 / SCL 22), AudioReactive with local mic, SensorSync.
`touchtower.local`. AP fallback SSID: `WLED-TOUCH-BOX` (default pass).
**Updated 2026-08-28 on playa**: OTA'd from the old `touch-grid-effect`
June build to origin/main @ 8ea0be8c (`apa102_mpr121` env). Known
networks (priority order): **Lightbringer**, Verizon-MiFi8800L-5BD4
(playa jetpack, creds in WLED_dev `platformio_override.ini`), Acropolis.
Audio sync mode is **off** (local mic processing); flip to send
(`sync.mode:1`) if it becomes the vehicle's sender.

⚠ **Fleet gotcha found during this update**: current WLED main requires
the global I2C pins in *runtime config* (`hw.if.i2c-pin`) — the
`I2CSDAPIN`/`I2CSCLPIN` compile defines are no longer sufficient, and
the MPR121 usermod silently reports "not found" when they're unset.
After flashing main onto any older MPR121 board, set
`{"hw":{"if":{"i2c-pin":[19,22]}}}` and reboot.
- **Pending:** camera ledmap session (`WLED_dev tools/ledmap_camera`,
  iPhone-on-floor Continuity Camera) to map the triangle lattice to a 2D
  grid. Apply the audio-receive cfg above.

## Other WLED devices (not on the HMTL bus)

| Name | Host | Notes |
|---|---|---|
| Lightbringer Test | `10.1.10.112` ("WLED Strip" hardware) | ESP32, WS2801 on data 4 / clock 16; temporarily configured for the 800-px ceiling array (superseded by Lightbringer Ceiling) |
| Trancender | `10.1.10.227` | Stock WLED 16.0.1, 54×24 matrix, audio-sync sender |

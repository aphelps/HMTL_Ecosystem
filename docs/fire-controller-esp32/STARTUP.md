# Fire Controller — bench startup guide

Terse. Full reasoning is in [WIRING.md](WIRING.md); this is the do-list.

Board: SparkFun ESP32 LoRa 1-CH Gateway (ESP32-WROOM-32E, no PSRAM).
Peers: HMTL Trigger Board v3 modules **71** and **72**, already configured and verified.

---

## 0. Pre-flight (before power)

```bash
# 1. ArduinoLibs is 5 commits stale and is what HMTL builds link against.
#    Without d047ce2 a 32-bit build disagrees with the AVR modules on the wire.
# NOTE: a bare `pull` FAILS -- the local branch tracks a stale refs/heads/master
# that no longer exists on the remote. Use the explicit form:
git -C ~/Dropbox/Arduino/ArduinoLibs fetch origin
git -C ~/Dropbox/Arduino/ArduinoLibs merge --ff-only origin/main

# 2. confirm the packed headers arrived
grep -c "__packed__" ~/Dropbox/Arduino/ArduinoLibs/RS485Utils/RS485Utils.h   # expect >= 1
```

Physical checks:

- [ ] **Avoid USB and the 3V3 feed at the same time.** The board has no 5V input pad, so box power
      arrives regulated on `3V3`, back-driving the on-board regulator. Two sources on one rail is
      usually benign (see WIRING.md §4) — but the regulator part is unknown, so unplug the 3V3
      feed before USB. Cheap insurance, not a catastrophe.
- [ ] LM1117: **10µF on input and output** — required for stability, not optional.
- [ ] LM1117: **the tab is VOUT (3.3V), not ground.** Isolate it from the enclosure.
- [ ] LM1117 fed from the supply directly (star), not downstream of the strip's current path.
- [ ] MCP23017 powered from **3.3V, not 5V** — its I2C must not sit at 5V levels.
- [ ] 74AHCT125 orientation — pin 1 at the notch. Backwards = 5V onto GND.
- [ ] No 5V touches an ESP32 GPIO. Only 5V nets: shifter VCC, shifter outputs (pins 3, 6), strip.
- [ ] All grounds common: ESP32, regulator, MAX3485, shifter, MCP23017, strip supply, RS485 bus.
- [ ] MAX3485 A/B not swapped — the classic silent RS485 failure.
- [ ] 120Ω at **both** bus ends and nowhere else. Check whether the breakout already has one.
- [ ] LoRa antenna fitted if the radio will transmit.
- [ ] Strip 5V comes from the supply directly, not the dev board or breadboard rails.

---

## 1. Pin map

**See [WIRING.md](WIRING.md) §3.** Not duplicated here — one pin table, so the two documents cannot
drift apart. Quick version: IRQ 4 · I2C 21/22 · RS485 RX/TX/EN 5/19/18 · WS2801 DATA/CLOCK 25/23 ·
LoRa owns 12/13/14/16/26/32/33 · leave 27 alone.

## 2. Source + build changes

Three changes. Two are flags; one is a source edit that is easy to miss.

**a. RS485 UART pins — now landed in source (HMTL_Fire_Control PR #3):** defaults live in
`HMTL_Fire_Control.h` as `RS485_RX_PIN=5` / `RS485_TX_PIN=19`, overridable as a pair
(`#error` on a half-override). The old hardcoded `16, 17` put the UART on the LoRa
chip-select and LED_BUILTIN. Nothing to edit if you are on that branch/PR.

**b. `platformio/HMTL_Fire_Control_Wickerman/platformio.ini`, `[env:touchcontroller_esp32]`:**

```ini
-    -DPIXELS_WS2801_13_14
+    -DPIXELS_WS2801_25_23
-    -DSWITCH_PIN_1=26 -DSWITCH_PIN_2=27 -DSWITCH_PIN_3=32 -DSWITCH_PIN_4=33
```

`13_14` is the LoRa SPI bus. `25_23` already exists in `PixelUtil_config.h:179`, so no library
change is needed.

The `SWITCH_PIN_*` GPIO defines go away because all four are LoRa (26=DIO0, 33=DIO1, 32=DIO2, and 27
reportedly RST — unconfirmed, see WIRING.md §3). **The switches are required — they move to the MCP23017 expander (§3, stage 2b).** That is
not a flag change: reading them over I2C is new firmware, including the fail-safe behaviour in
WIRING.md §7.

Unchanged and correct already: `-DIRQ_PIN=4`, `-DRS485_ENABLE_PIN=18`, `-DSERIAL_BAUD=115200`.

**c. Board target.** `board = esp32dev` works. `board = sparkfun_lora_gateway_1-channel` is the
accurate variant and defines the LoRa SPI/CS pins — prefer it if the radio is being used.

---

## 3. Bring-up, in order

Do not skip ahead. Stages 3 and 4 each add a way to be wrong about grounds; together they are much
harder to diagnose than separately.

### Bench power configuration — read before stage 1

The box wiring in WIRING.md §4 and the bench procedure below need **different** power arrangements,
and running the box arrangement while USB is attached is the destructive case. For all of stages
1-4:

- **Leave the LM1117 → ESP32 `3V3` pin wire DISCONNECTED.**
- **USB powers the ESP32.**
- **Peripherals** (MAX3485, MPR121, MCP23017) run from the **ESP32's own `3V3` pin**, not the
  LM1117.
- Stage 4 additionally needs the 5V supply live for the shifter and strip — that is fine, because
  the 5V rail never touches the board. Keep grounds common.

The LM1117 → `3V3` connection is made **once, at the end**, with USB permanently unplugged. Bench
it separately first: 5V in, meter 3.3V out, confirm it is not shorted to the 5V rail — then wire it
to the board.

### Stage 1 — console only

Nothing connected but USB.

```bash
cd HMTL_Fire_Control/platformio/HMTL_Fire_Control_Wickerman
pio run -e touchcontroller_esp32 --target upload
pio device monitor -b 115200
```

**Pass:** boot banner, no reset loop. **Fail:** check `upload_port`, and that the board enumerates
(`ls /dev/cu.usbserial*`).

### Stage 2 — MPR121

Qwiic cable + one wire (INT → GPIO 4).

**Pass:** I2C scan finds `0x5A`; touching an electrode registers.
**Fail:** `0x5A` absent → cable seated? Adafruit board's `ADDR` must be unconnected for `0x5A`.

### Stage 2b — MCP23017 + ignition switches

Four wires: 3V3, GND, SDA(21), SCL(22). **Not** Qwiic — Waveshare uses PH2.0, which does not mate
with STEMMA QT. Power from **3.3V**.

⚠ **Jumper A0 closed first** — the all-open default `0x27` collides with the LCD
(`LiquidCrystal_I2C(0x27)`), so the expander runs at **`0x26`**.

**Pass:** I2C scan shows `0x26` alongside the MPR121's `0x5A`; each switch reads cleanly with the
internal pull-up enabled, switch wired to GND.
**Fail:** `0x26` absent → check the A0 jumper and that it is on 3.3V; if `0x27` appears instead,
the jumper is not shorted. Both devices vanish → bus contention or pull-ups; disconnect the
expander and confirm `0x5A` returns.

⚠ Before wiring these to anything that can ignite: verify the **fail-safe path** — pull the SDA line
and confirm firmware reports switches *off / not armed*, not last-known-state. WIRING.md §7.

### Stage 3 — RS485 to modules 71/72

Add the MAX3485. Bus is **28000 baud 8N1** — not 57600, not 115200.

⚠ **The device on USB must be the ESP32 fire controller**, forwarding serial→RS485. If you instead
put an HMTL module on USB, the poll travels module→bus→module and **passes with the ESP32's MAX3485
entirely unwired** — testing nothing you just built.

**Negative control:** once it passes, unplug the ESP32's `A`/`B` and confirm the poll now *fails*.
If it still passes, you were never testing the new hardware.

From the laptop, with the ESP32 on USB and the command server running:

```bash
cd HMTL/python
python3 bin/HMTLCommandServer -d /dev/cu.usbserial-XXXX -b 115200 &
python3 bin/HMTLClient -A 71 --poll        # expect a response from dev_id 71
python3 bin/HMTLClient -A 72 --poll
```

**Pass:** both addressed polls respond. **Fail:**
- nothing at all → A/B swapped, no common ground, or DE/RE not tied
- garbage → wrong baud (must be 28000 on the wire)
- works one direction only → DE/RE stuck; check GPIO 18 actually toggles

Notes: broadcast `--poll` only ever finds the directly-connected module — a known client bug, use
`-A <addr>`. `--dump` against a *remote* module returns nothing; that is a firmware limitation, not
your wiring.

### Stage 4 — WS2801 via the shifter

Introduces the 5V domain.

**Before connecting the strip:** power the shifter, drive the pins, and meter shifter pins 3 and 6.
They must swing to ~5V. If they sit at 3.3V, the part is HC/AHC rather than **AHCT**, or VCC is on
3.3V instead of 5V.

**Pass:** pixels light, colours correct, no flicker along the strip.
**Fail:** first pixel only → clock not reaching the strip. Random colour corruption → level or
ground problem, not firmware.

### Stage 5 — LoRa to the TouchMatrix

Needs the second board. Antenna fitted first — transmitting into no load can damage the PA.

⚠ **No LoRa implementation exists yet.** `DISABLE_LORA` is a build flag with nothing behind it;
ArduinoLibs has `Socket`, `RS485Utils`, `RFM69Socket`, `XBeeSocket` but no RFM95. A `LoRaSocket`
must be written, modelled on `RFM69Socket`. Also `RFM69Socket.cpp:27-33` fails to compile on ESP32
(`#error Unknown processor type`) — it maps IRQ pins for AVR only; ESP32 needs
`digitalPinToInterrupt()`.

---

## 4. Reference numbers

| | |
|---|---|
| RS485 wire rate | **28000 baud 8N1** (`RS485Utils.h`, `DEFAULT_BAUD`, line 114 pre-pull) |
| Module USB console | **115200** (`HMTL_Module.ino` compile-time `BAUD`) |
| EEPROM `baud` field | **inert** — reads 9600, feeds only a debug print. Ignore it. |
| MPR121 I2C address | `0x5A` |
| HMTL peers | 71, 72 (hardware_version 5) |
| Proposed bridge address | 73 (1 collides twice in `addresses.txt`) |

---

## 5. Known traps

- **Stale `.pio/libdeps`** (WLED builds): `lib_deps` copies ArduinoLibs by path and does not
  reliably re-sync. A build once reported SUCCESS against a deliberately wrong constant. Before any
  flash meant to test a source change: `rm -rf .pio/libdeps/<env>/RS485Utils`.
- **Two ArduinoLibs checkouts.** `~/Dropbox/Arduino/ArduinoLibs` (what HMTL links) vs
  `WLED_dev/ArduinoLibs` (what WLED links). They drift. Check both when editing the library.
- **`HMTL_Command_CLI` is not a bus sniffer** — it filters on socket-layer destination. Anything it
  should see must be addressed to it or to broadcast `65535`, or a working bridge reads as silent.

# Bench prep — ESP32 + RS485 bridge

Everything below was verified from the checkouts on this laptop, not recalled. Sources cited so
each claim can be re-checked rather than trusted.

## 1. The numbers that matter

| Thing | Value | Source |
|---|---|---|
| RS485 wire rate | **28000 baud, 8N1** | `RS485Utils.h` `DEFAULT_BAUD` (line 114 pre-pull), and independently `RS485 setup: 28000` in today's HMTL_Module boot log |
| UDP ingress port | 21331 | usermod readme |
| Bridge default addr | 1 — **collides**, see §4 | usermod readme |
| HMTL trigger boards | 71, 72 (hw_ver 5) | `HMTL/addresses.txt` on `main` (PR #11 / `b4214c8`) |

**Do not trust an EEPROM config dump for the wire rate.** The HMTL modules' stored `baud` reads
9600 and is inert — `HMTL_Module.ino:113-119` hardcodes a compile-time `BAUD` of 115200 for the USB
console, and the stored field only feeds a debug print (`HMTLTypes.cpp:613`). The RS485 bus is
28000 regardless. Three different numbers, none of which is a mistake.

## 2. rs485_bridge usermod settings (Config → Usermods → RS485Bridge)

| Field | Key | Default | Note |
|---|---|---|---|
| Enabled | `enabled` | `false` | off until explicitly set |
| UART | `uart` | `2` | 1 or 2; UART0 is the console. Reboot required |
| RX | `rx` | **16** | ⚠ PSRAM conflict — §3 |
| TX | `tx` | **17** | ⚠ PSRAM conflict — §3 |
| DE/RE | `en` | `18` | single pin drives both DE and RE |
| Baud | `baud` | `28000` | matches existing HMTL modules |
| Address | `addr` | `1` | applied live (this is how SET_ADDRESS works) |
| Device id | `devId` | `0` | 0 derives from MAC |
| UDP port | `port` | `21331` | applied live |

`addr` and `port` apply live; everything else needs a **reboot**, because `RS485Socket::init_general()`
re-runs `new RS485(...)` without freeing, so `setup()` is the only safe caller.

Config round-trip check: `curl -s http://<ip>/json/cfg | python3 -m json.tool | grep -A9 RS485Bridge`

## 3. The PSRAM pin trap — exact rule

`WLED/wled00/pin_manager.cpp:249-256`, classic ESP32:

```c
if (gpio == 16) return !psramFound();          // blocked whenever PSRAM present
if (gpio == 17) {
  if (chipModel == "ESP32-D0WDR2-V3") return true;   // 17 IS allowed here
  else return !psramFound();
}
```

So the usermod's **defaults (16/17) are exactly the pins PSRAM takes**. If the module is a WROVER
(or any in/off-package PSRAM part), pin allocation fails for a reason that has nothing to do with
RS485 — reassign before enabling, not after debugging.

Nuance worth knowing: on `ESP32-D0WDR2-V3`, GPIO17 is fine and only 16 is blocked.

Also on classic non-mini ESP32: **GPIO 6-11 are SPI flash, never usable** (`:247`).

### ⚠ Does not apply to our board — but keep it for the next one

The board in hand is an **ESP32-WROOM-32E** (no PSRAM), so 16/17 are not blocked by PSRAM. They are
nonetheless unusable here for a different reason: **GPIO 16 is the LoRa chip-select**. The PSRAM
rule above matters only if this build is ever moved to a WROVER.

**For the actual pin assignment on this hardware see [WIRING.md](WIRING.md) §3** — it is the single
source of truth and accounts for the LoRa radio. Summary: `rx=5, tx=19, en=18`
(23 is the WS2801 clock, 25 its data).

Pins to avoid on a classic ESP32 generally: 0, 2, 12, 15 (strapping) · 1, 3 (console) ·
6-11 (flash) · 34-39 (input-only, cannot drive DE/RE).

## 4. Address collision — bridge should NOT be 1

`HMTL/addresses.txt` already uses address 1 **twice**:
- line 47 — `0x0101  1/0x1` First assembled wireless pendant
- line 72 — `1  1/0x01` First Lightbringer 1284 board

Proposed **73**, contiguous with 71/72 registered today. Pending mini's confirmation.

## 5. Build discipline — the cached-libdeps trap

`lib_deps` names the ArduinoLibs dirs **by path**, so PlatformIO *copies* them to
`.pio/libdeps/<env>/` and builds the copy without reliably re-syncing.

This is documented as having actually happened: a build reported SUCCESS against a deliberately
wrong `RS485B_SOCKET_HDR_LEN` because it compiled a cached pre-fix header, so the `static_assert`
meant to catch exactly that never saw the new struct. Touching the `.cpp` was not enough.

**Before any flash intended to test a source change:**
```bash
cd /Users/amp/Dropbox/Arduino/WLED_dev/WLED
rm -rf .pio/libdeps/ampworks/RS485Utils   # + any other ArduinoLibs dir touched
pio run -e ampworks
```
Env `ampworks` is at `WLED/platformio.ini:517`. Both `-D USERMOD_RS485_BRIDGE` and
`-D RS485_HARDWARE_SERIAL=2` are load-bearing: the latter makes `SERIAL_TYPE` resolve to
`HardwareSerial` instead of AVR-only `SoftwareSerial`.

## 6. HMTL_Command_CLI is NOT a bus sniffer

It filters on **socket-layer destination**, so a frame addressed to a third node never reaches its
print path. Anything we expect it to see must be addressed to `<cli-addr>` or broadcast `65535`.
Getting this wrong reads as "the bridge never transmitted" off a perfectly working bridge.

## 7. Parts — identified

Resolved from photographs on 2026-08-17; the open questions this section used to list are answered.

| Part | Identified as | Consequence |
|---|---|---|
| MCU board | SparkFun ESP32 LoRa 1-CH Gateway | only ~7 GPIO broken out; LoRa consumes 12/13/14/16/26/32/33, and possibly 27 |
| MCU | **ESP32-WROOM-32E** | **no PSRAM** — §3 does not apply |
| RS485 | **MAX3485** breakout | **3.3V part** — no level shifting needed, unlike a MAX485 |
| Touch | Adafruit MPR121, STEMMA QT | I2C `0x5A`; connect via Qwiic ↔ STEMMA QT cable |
| LEDs | WS2801 | 5V part — 3.3V drive is out of spec, see WIRING.md §8 |

Still to check on the bench: whether the MAX3485 breakout has a **120Ω termination resistor**
fitted or jumperable. Terminate both physical ends of the bus and no more — two terminators at one
end is a common bench mistake.

## 8. Wiring

**See [WIRING.md](WIRING.md) §5** for RS485, or §2 for the whole-system diagram. Not duplicated
here, so the two documents cannot drift apart.

The one rule worth repeating: a **common ground** between the bridge and the HMTL modules is not
optional. RS485 is differential but still needs a return reference.

## 9. Open items

- **Firmware target** — HMTL_Fire_Control (`-e touchcontroller_esp32`) or WLED + this usermod.
  Same wiring, different build and bring-up path.
- **`<cli-addr>`** — `HMTL_Command_CLI` has only a `platformio.ini` and no config JSON, so its
  address depends on which physical board is flashed with it.
- **`<ip>`** — assigned once the bridge is on WiFi.
- **`<bridge-addr>`** — 73 proposed (see §4), pending confirmation.
- **LoRa** — no implementation exists yet; see [README.md](README.md) open question 2.

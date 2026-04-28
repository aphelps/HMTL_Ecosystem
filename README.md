# HMTL Ecosystem

**Hardware Message Transport Layer** — a modular platform for controlling networked LED and lighting effects, originally built for the Burning Man art car [Ku, the Heavy Metal Tiki Lounge](https://www.facebook.com/KuHMTL).

## Modules

| Directory | Description |
|---|---|
| [`HMTL/`](HMTL/) | Core platform: firmware, libraries, Python tooling |
| [`HMTL_Fire_Control/`](HMTL_Fire_Control/) | Theatrical propane flame effect controller |
| [`CircularController/`](CircularController/) | Wireless handheld box controller (RFM69 radio) |
| [`DistributedArt/`](DistributedArt/) | Flask web app + Raspberry Pi deployment for installation control |

## Quick Start

### Prerequisites

- [PlatformIO CLI](https://platformio.org/install/cli) — `pip install platformio`
- Python 3 — `pip install -e HMTL/python/`
- Arduino libraries symlinked via `cd HMTL && bash install.sh`

### Build all firmware

```bash
make build
```

### Run all tests

```bash
make test
```

### Build + test everything

```bash
make all
```

Individual submodules can be built/tested independently:

```bash
make HMTL
make HMTL_Fire_Control
make CircularController
```

## Testing

All tests run without hardware. The ecosystem uses three complementary tracks across two submodules.

### Tracks

| Track | What it tests | HMTL | HMTL_Fire_Control |
|---|---|---|---|
| **Python emulator** | Protocol, message routing, config — pure Python | `make test-python` | `make test-python` |
| **C++ native** | Firmware logic (programs, outputs, manager) compiled for desktop via PlatformIO + Unity | `make test-native` | `make test-native` |
| **AVR build check** | Real `avr-gcc` compile of the main firmware sketch | `make test-simavr` | — |

### Running tests

```bash
# All tests across all submodules
make test

# One submodule
cd HMTL && make test
cd HMTL_Fire_Control && make test
```

### Coverage

```bash
# All coverage across all submodules (Python + C++)
make coverage

# Split by language
make coverage-python
make coverage-native

# One submodule
cd HMTL && make coverage
cd HMTL_Fire_Control && make coverage
```

## Architecture

HMTL modules are Arduino-class microcontrollers (ATmega328P, ATmega1284P, ESP32, Moteino) that communicate over a shared bus. Each module has a set of **outputs** configured in EEPROM and responds to a binary message protocol over RS485, XBee, RFM69, or serial/Bluetooth.

### Message protocol

8-byte header: `startcode | crc | version | length | type | flags | address (2B)`

Message types: `OUTPUT`, `POLL`, `SET_ADDR`, `SENSOR`, `TIMESYNC`, `DUMP_CONFIG`

### Output types

| Type | Description |
|---|---|
| `VALUE` | Single-color LEDs, solenoids, ignitors |
| `RGB` | RGB LED strips |
| `PIXELS` | Addressable LEDs (WS2812B, APA102, WS2801) via FastLED |
| `MPR121` | 12-channel capacitive touch sensor |
| `RS485` | Serial bridge |
| `XBEE` | XBee wireless bridge |

### Timed programs

The ProgramManager runs timed effects on outputs: `BLINK`, `FADE`, `SPARKLE`, `CIRCULAR`, `SEQUENCE`, `TIMED_CHANGE`, `LEVEL_VALUE`, `SOUND_VALUE`.

## HMTL Core (`HMTL/`)

### Firmware

```bash
cd HMTL/platformio/HMTL_Module
pio run -e nano          # build
pio run -e nano --target upload   # flash
```

Common environments: `nano`, `uno`, `mini`, `esp32`, `moteino`. Board-specific pixel types are selected via compile flags (e.g. `-DPIXELS_WS2812B_12`).

### Python tools

```bash
cd HMTL/python
python bin/HMTLConfig.py          # read/write EEPROM config via JSON
python bin/HMTLCommandServer.py   # start network command server
python bin/HMTLClient.py          # send commands to modules
python bin/TailArduino.py         # serial monitor
python bin/Scan.py                # discover modules on network
```

Module configs (one JSON file per physical device) live in `HMTL/python/configs/`. Load them onto hardware using the `HMTLPythonConfig` firmware sketch together with `HMTLConfig.py`.

See [Testing](#testing) above for per-track commands.

## Fire Control (`HMTL_Fire_Control/`)

Controls propane poofing effects. Supports multiple controller configurations:

- **HMTL_Fire_Control** — standard nano-based controller
- **HMTL_Fire_Control_Wickerman** — dual-role build (`firecontroller` / `touchcontroller` env)

```bash
cd HMTL_Fire_Control && make build
```

## Circular Controller (`CircularController/`)

Wireless handheld controller based on Moteino (RFM69 radio). Includes a `Bringup` sketch for hardware bring-up.

```bash
cd CircularController && make build
```

## Distributed Art (`DistributedArt/`)

Flask web application for controlling HMTL installations from a browser. Deployed to Raspberry Pi via Ansible.

```bash
cd DistributedArt && make test      # run Flask unit tests

# Local development
cd DistributedArt/DistributedArtFlask && flask run
```

### Raspberry Pi deployment

```bash
cd DistributedArt/DistributedArtPi
ansible-galaxy install -r install_roles.yml
cp hosts.example hosts && cp wpa_supplicant.conf.example wpa_supplicant.conf
# Edit hosts and wpa_supplicant.conf, then:
ansible-playbook playbook.yml -i hosts
```

## Wiring Reference

### 4-Pin XLR (RS485 bus)

| Pin | Use | Wire colour |
|---|---|---|
| 1 | GND | White |
| 2 | Data A | Black |
| 3 | Data B | Green |
| 4 | VCC (12V) | Red |

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

HMTL (Hardware Message Transport Layer) is a modular platform for controlling networked LED and lighting effects, designed for art installations (notably Burning Man). It spans embedded C++ firmware for Arduino-class microcontrollers, Python tooling for configuration/control, and a Flask web app for deployment.

## Repository Structure

```
HMTL/                       # Core platform
  HMTL_Module/              # Main firmware sketch
  Libraries/                # C++ libraries shared across modules
  platformio/               # PlatformIO build configs per firmware target
  python/                   # Python library + CLI tools + configs
  test/                     # Arduino test sketches
HMTL_Fire_Control/          # Specialized fire/flame control module
CircularController/         # Wireless box controller (RFM69 radio)
DistributeArt/              # Flask web control app + Raspberry Pi deployment
```

## Building Firmware

PlatformIO is the build system. Each firmware project has a `platformio/` subdirectory containing `platformio.ini` with multiple board environments.

```bash
# Build a specific environment
cd HMTL/platformio/HMTL_Module
pio run -e nano

# Upload to device
pio run -e nano --target upload

# Serial monitor
pio device monitor

# List available environments (from platformio.ini)
pio run --list-targets
```

Common environments: `nano`, `uno`, `pro`, `esp32`, `esp32_routed`. Board-specific pixel types and pin assignments are passed as compile flags (e.g., `-DPIXELS_WS2812B_12`).

Libraries are resolved from `~/.platformio/` and from `~/Dropbox/Arduino/libraries/` (symlinked via `HMTL/install.sh`).

## Python Tools

The Python library lives in `HMTL/python/hmtl/` and CLI tools in `HMTL/python/bin/`.

```bash
# Install Python package
cd HMTL/python
pip install -e .

# Run Python tests
pytest hmtl/tests/

# Key CLI tools (run from HMTL/python/)
python bin/HMTLConfig.py       # Read/write module EEPROM config via JSON
python bin/HMTLCommandServer.py  # Start network command server
python bin/HMTLClient.py       # Send commands to modules
python bin/TailArduino.py      # Serial monitor
python bin/Scan.py             # Auto-discover modules on network
```

## Core Architecture

### Message Protocol

Each HMTL message has an 8-byte header: `startcode | crc | version | length | type | flags | address (2B)`. Message types: `OUTPUT`, `POLL`, `SET_ADDR`, `SENSOR`, `TIMESYNC`, `DUMP_CONFIG`. See `HMTL/Libraries/HMTLProtocol/` for C++ definitions and `HMTL/python/hmtl/HMTLprotocol.py` for the Python counterpart.

### Output Types (HMTLTypes)

Six output types defined in `HMTL/Libraries/HMTLTypes/HMTLTypes.h`:
- `VALUE` — single-color LEDs, solenoids, ignitors (13-bit value)
- `RGB` — RGB LED strips
- `PIXELS` — Addressable LEDs (WS2812B, APA102, WS2801) via FastLED
- `MPR121` — Capacitive touch sensors (12 inputs)
- `RS485` — Serial bridge output
- `XBEE` — XBee wireless bridge

### Message Routing (MessageHandler)

`HMTL/Libraries/HMTLMessaging/MessageHandler.{h,cpp}` — listens on one serial port plus multiple sockets. On each message: check if addressed to this device, if broadcast, or forward to other sockets. Processes OUTPUT, POLL, and SETADDR types.

### Program Manager

`HMTL/Libraries/HMTLMessaging/ProgramManager.{h,cpp}` — runs timed programs on outputs. Each program has an init function (called once on install) and a run function (called every tick). Programs: `BLINK`, `TIMED_CHANGE`, `FADE`, `SPARKLE`, `CIRCULAR`, `SEQUENCE`, `LEVEL_VALUE`, `SOUND_VALUE`.

Special output sentinels in `msg_program_t.hdr.output`:
- `HMTL_ALL_OUTPUTS` (0xFE) — install the program on every output simultaneously
- `HMTL_NO_OUTPUT` (0xFF) — program manages outputs itself (e.g. SEQUENCE); stored in a dedicated `no_output_tracker`, not tied to any output slot

`program_fade` uses `state->start_time == 0` as the "not yet initialised" sentinel. In tests, always run the first tick at `_mock_millis ≥ 1` (not 0) so `start_time` is latched to a non-zero value and subsequent ticks enter the blend branch correctly.

### Communication Sockets

Transport abstraction supporting: Serial (USB/Bluetooth), RS485, XBee, RFM69 radio, WiFi (ESP32). All socket types implement a common interface used by MessageHandler.

### Configuration System

Each module stores its config in EEPROM: device ID, network address, baud rate, output definitions. JSON config files for each physical device live in `HMTL/python/configs/`. `HMTLConfig.py` reads/writes these to hardware via the `HMTLPythonConfig` firmware sketch.

### Main Firmware Loop (`HMTL_Module.ino`)

1. `MessageHandler.check()` — poll serial/sockets for incoming messages
2. Route: addressed to me → process; broadcast → process + forward; other → forward
3. Apply message to output or schedule a program via ProgramManager
4. `ProgramManager.run()` — execute any active timed programs
5. Respond if `MSG_FLAG_RESPONSE` is set

## Testing

Three tracks, all invoked via `make test` from `HMTL/`:

```bash
make test           # all three tracks
make test-python    # Track 1: Python emulator tests only
make test-native    # Track 2: C++ native tests only
make test-simavr    # Track 3: AVR firmware build check only
```

### Track 1 — Python Emulator (`HMTL/python/`)

Pure-Python emulation of the firmware message loop. Tests in `hmtl/tests/test_emulator.py`. Run with `pytest`.

### Track 2 — C++ Native (`HMTL/platformio/HMTL_Test/`)

Firmware library code compiled for the host machine (no hardware) using PlatformIO's `native` platform and the Unity test framework.

```bash
cd platformio/HMTL_Test
pio test -e native                          # all test suites
pio test -e native --filter test_pixelutil  # single suite
```

**How it works:** `lib/hmtl_sources/hmtl_sources.cpp` uses `#include` to pull the real firmware `.cpp` files into one translation unit. All Arduino/FastLED/PixelUtil dependencies are satisfied by stubs in `stubs/`. PlatformIO's LDF only links libraries that appear in `#include` directives, so the `lib/hmtl_sources/library.json` + `lib_deps = hmtl_sources` in `platformio.ini` forces the library to link with every test binary.

**Stubs** (`platformio/HMTL_Test/stubs/`):

| Stub | Key details |
|---|---|
| `Arduino.h` | Force-included into every TU via `-include Arduino.h`. C++-specific content guarded with `#ifdef __cplusplus`. `millis()` returns `_mock_millis` (extern unsigned long — set directly in tests to drive time). |
| `Debug.h` | All `DEBUG1_*`–`DEBUG5_*` macros write to an in-memory line buffer and append to `/tmp/hmtl_test_debug.log`. Built at `DEBUG_LEVEL=5` (TRACE) so all levels fire. |
| `FastLED.h` | `CRGB` memory layout is `{r, g, b}` (matching real FastLED) so `.raw[]` is in RGB order — important because `hmtl_set_output_rgb` passes `.raw` directly to `setAllRGB(r,g,b)`. |
| `PixelUtil.h` | Stores actual `CRGB` values in a heap array. Every mutation emits a debug line (`pixel[N]=0xRRGGBB`, `setAllRGB 0xRRGGBB`, etc.). `getPixel(n)` for direct state assertions. CHSV→CRGB is simplified to greyscale (`r=g=b=value`), so any CHSV colour with `val=255` becomes `0xffffff`. |

**Debug log API** (declared in `Debug.h`, implemented in `test_support.cpp`):

```cpp
void setUp() { debug_log_begin_test(Unity.CurrentTestName); } // writes section header, clears buffer

debug_log_contains("setAllRGB 0xff0000")  // 1 if any line contains substring
debug_log_count()                         // number of completed lines
debug_log_line(int n)                     // get line n
debug_log_reset()                         // mid-test clear + "--- reset ---" marker
debug_log_open("/path/to/file.log")       // redirect (default appends to /tmp/hmtl_test_debug.log)
```

The log file **appends** across runs so the full history is preserved. Each test gets a `=== test_name ===` section header written by `debug_log_begin_test()`.

**`hmtl_set_output_rgb` stub** handles `VALUE`, `RGB`, and `PIXELS` output types. For PIXELS it calls `pixels->setAllRGB(r,g,b)` on the `object` cast to `PixelUtil*`.

### Track 3 — AVR Build Check (`HMTL/platformio/HMTL_Module/`)

Compiles the main firmware for ATmega328P using avr-gcc to catch AVR-specific issues. Does not run code (simavr is not installed).

```bash
cd platformio/HMTL_Module
pio run -e simavr_nano
```

## Flask Web App (DistributeArt)

`DistributeArt/DistributedArtFlask/` — Flask app with SQLAlchemy and Alembic migrations. Raspberry Pi deployment uses Ansible playbooks in `DistributeArt/DistributedArtPi/`.

```bash
cd DistributeArt/DistributedArtFlask
flask run
# or
python run.py
```

## Setup

```bash
# Symlink Arduino libraries (run once)
cd HMTL
bash install.sh
```

## Arduino Libraries (`~/Dropbox/Arduino/libraries/`)

Libraries are installed here and symlinked into the Arduino/PlatformIO search path by `install.sh`.

### HMTL Ecosystem (custom, from this repo or sibling repos)

| Library | Purpose |
|---|---|
| **HMTLMessaging** | Core messaging protocol — output messages, poll, sensor, time sync, CRC |
| **HMTLTypes** | Config/output data type definitions (value, RGB, pixels, MPR121, RS485, XBee) |
| **HMTLPoofer** | Theatrical flame poofer control — igniter, pilot, timing/state |
| **TimeSync** | Clock sync across HMTL modules with latency-aware adjustment |
| **Socket** | Abstract transport-agnostic socket interface (base class for all socket types) |
| **RS485Utils** | Socket impl wrapping Nick Gammon's non-blocking RS485 protocol |
| **RFM69Socket** | Socket impl for RFM69 wireless transceivers |
| **XBeeSocket** | Socket impl for XBee Series 1/2 modules |
| **Debug** | Configurable debug output (ERROR/LOW/MID/HIGH/TRACE levels), PROGMEM-backed |
| **PixelUtil** | FastLED wrapper with large pixel count support and compiler-flag LED type selection |
| **SerialCLI** | Serial command-line interface for interactive debugging |
| **EEPromUtils** | EEPROM read/write helpers for config storage |
| **GeneralUtils** | Miscellaneous utility functions |
| **Pins** | Pin configuration management |
| **Menu** | Text menu system for serial interfaces |
| **LCD** | LCD display utilities |
| **Shift** / **ShiftBar** | Shift register control; LED bar display via shift registers |

### Third-Party — LED / Display

| Library | Purpose |
|---|---|
| **FastLED** (v3.2.1) | Addressable LED control — WS2812B, APA102, WS2801; color/power management |
| **Adafruit_GFX** | Drawing primitives (lines, shapes, text) for Adafruit displays |
| **Adafruit_LEDBackpack** | 7-segment, 14-segment, matrix LED display drivers |
| **Adafruit_WS2801** | SPI-based WS2801 addressable pixel driver |
| **apa102-arduino** (v1.1.0) | Pololu APA102/APA102C LED strip driver |
| **Tlc5940** | 16-channel PWM driver for TI TLC5940 chip |
| **LiquidCrystal** | Standard LCD character display driver |
| **LiquidTWI** | I2C-based LCD driver |

### Third-Party — Wireless / Networking

| Library | Purpose |
|---|---|
| **RFM69** | Semtech SX1231 transceiver — AES encryption, ACK, RSSI, sleep (LowPowerLab) |
| **Xbee** | XBee Series 1/2 API mode — TX/RX, AT commands, I/O sampling |
| **RS485_non_blocking** | Nick Gammon's non-blocking RS485 protocol (used by RS485Utils) |
| **WiFiBase** / **TCPSocket** | ESP WiFi base + TCP socket impl (from EspLibraries) |
| **WIFIMANAGER-ESP32** | ESP32 captive-portal WiFi config manager |
| **blynk-library** | Mobile dashboard control (iOS/Android) for IoT projects |

### Third-Party — Sensors / Other

| Library | Purpose |
|---|---|
| **Adafruit_MPR121_Library** | 12-channel capacitive touch/proximity sensor |
| **NewPing** (v1.5) | Ultrasonic distance sensor (SR04/SRF05) with median filtering |
| **CapacitiveSensor** | Capacitive touch using standard I/O pins |
| **ArduinoJson** | Zero-malloc JSON parsing/generation |
| **Arduino-PID-Library** (v1.1.1) | PID feedback controller |
| **SPIFlash** | SPI flash read/write (used for OTA on Moteino) |
| **Unity** | Unit testing framework for embedded C/C++ |
| **MemoryFree** | Runtime free-memory reporting |
| **ffft** | Fast Fourier Transform (from Piccolo audio project) |

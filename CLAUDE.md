# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

HMTL (Hardware Message Transport Layer) — modular platform for networked LED/lighting art installations. Embedded C++ firmware for Arduino-class MCUs, Python tooling for config/control, Flask web app for deployment.

## Building Firmware

PlatformIO build system. Each firmware project has `platformio/platformio.ini` with multiple board environments.

```bash
cd HMTL/platformio/HMTL_Module
pio run -e nano                    # build
pio run -e nano --target upload    # flash
pio device monitor                 # serial monitor
```

Common environments: `nano`, `uno`, `pro`, `esp32`, `esp32_routed`. Board-specific pixel types/pins passed as compile flags (e.g. `-DPIXELS_WS2812B_12`).

Libraries resolved from `~/.platformio/` and `~/Dropbox/Arduino/libraries/` (symlinked by `HMTL/install.sh`).

## Python Tools

```bash
cd HMTL/python && pip install -e .
pytest hmtl/tests/

python bin/HMTLConfig.py          # read/write EEPROM config via JSON
python bin/HMTLCommandServer.py   # network command server
python bin/HMTLClient.py          # send commands to modules
python bin/Scan.py                # auto-discover modules
```

## Core Architecture

**Message protocol** — 8-byte header: `startcode | crc | version | length | type | flags | address(2B)`. Types: `OUTPUT`, `POLL`, `SET_ADDR`, `SENSOR`, `TIMESYNC`, `DUMP_CONFIG`. C++ in `Libraries/HMTLProtocol/`; Python in `python/hmtl/HMTLprotocol.py`.

**Output types** (`Libraries/HMTLTypes/HMTLTypes.h`): `VALUE` (single LED/solenoid), `RGB`, `PIXELS` (addressable via FastLED), `MPR121` (capacitive touch), `RS485`, `XBEE`.

**MessageHandler** (`Libraries/HMTLMessaging/`) — polls serial + sockets; routes messages to this device, broadcasts, or forwards.

**ProgramManager** (`Libraries/HMTLMessaging/`) — runs timed programs on outputs. Programs: `BLINK`, `TIMED_CHANGE`, `FADE`, `SPARKLE`, `CIRCULAR`, `SEQUENCE`, `LEVEL_VALUE`, `SOUND_VALUE`.

Special `msg_program_t.hdr.output` sentinels:
- `HMTL_ALL_OUTPUTS` (0xFE) — install on every output
- `HMTL_NO_OUTPUT` (0xFF) — program manages outputs itself (e.g. SEQUENCE); stored in dedicated `no_output_tracker`

**Config** — stored in EEPROM per module (device ID, address, baud, outputs). JSON configs in `python/configs/`. `HMTLConfig.py` reads/writes via `HMTLPythonConfig` sketch.

**Main loop** (`HMTL_Module.ino`): poll sockets → route message → apply to output/ProgramManager → run programs → respond if flagged.

## Testing

```bash
make test              # all three tracks (from HMTL/)
make test-python       # Track 1: Python pytest
make test-native       # Track 2: C++ native Unity tests
make test-simavr       # Track 3: AVR build check
```

### Track 1 — Python (`HMTL/python/hmtl/tests/test_emulator.py`)

### Track 2 — C++ Native (`HMTL/platformio/HMTL_Test/`)

Firmware libraries compiled for the host with PlatformIO `native` + Unity.

```bash
cd platformio/HMTL_Test
pio test -e native
pio test -e native --filter test_pixelutil
```

`lib/hmtl_sources/hmtl_sources.cpp` `#include`s the real firmware `.cpp` files. PlatformIO's LDF only links libraries appearing in `#include` directives — `lib/hmtl_sources/library.json` + `lib_deps = hmtl_sources` in `platformio.ini` forces it into every test binary.

**Stubs** (`stubs/`):

| Stub | Key details |
|---|---|
| `Arduino.h` | Force-included via `-include Arduino.h`. `millis()` returns `_mock_millis` (set directly in tests). |
| `Debug.h` | `DEBUG1_*`–`DEBUG5_*` write to in-memory buffer + `/tmp/hmtl_test_debug.log` (appends). Built at `DEBUG_LEVEL=5`. |
| `FastLED.h` | `CRGB` layout is `{r,g,b}` matching real FastLED — `.raw[]` is RGB order. Critical: `hmtl_set_output_rgb` passes `.raw` directly to `setAllRGB(r,g,b)`. |
| `PixelUtil.h` | Stores `CRGB[]` on heap. Mutations emit `pixel[N]=0xRRGGBB`, `setAllRGB 0xRRGGBB`, etc. `getPixel(n)` for assertions. CHSV→CRGB is greyscale (`r=g=b=value`), so `val=255` → `0xffffff`. |

**Debug log API** (in `Debug.h`, implemented in `test_support.cpp`):

```cpp
void setUp() { debug_log_begin_test(Unity.CurrentTestName); }  // section header + clear buffer

debug_log_contains("setAllRGB 0xff0000")  // 1 if any line matches
debug_log_count()                         // completed line count
debug_log_line(int n)                     // get line n
debug_log_reset()                         // clear buffer + write "--- reset ---"
```

**Gotcha:** `program_fade` uses `state->start_time == 0` as uninitialised sentinel. Always run the first fade tick at `_mock_millis >= 1`, not 0.

### Track 3 — AVR Build Check

```bash
cd platformio/HMTL_Module && pio run -e simavr_nano
```

## Flask Web App

`DistributeArt/DistributedArtFlask/` — Flask + SQLAlchemy + Alembic. Raspberry Pi deployment via Ansible in `DistributeArt/DistributedArtPi/`.

# RFM95Socket: a LoRa Socket for the SparkFun ESP32 LoRa 1-CH Gateway, modelled on RFM69Socket

## Goal

Add `ArduinoLibs/RFM95Socket/` implementing the abstract `Socket` interface the way `RFM69Socket`
and `RS485Socket` do, so the on-board RFM95 (LoRa) radio on the SparkFun ESP32 LoRa 1-CH Gateway
becomes one more transport behind the existing abstraction.

**Scope is the library only.** WLED integration is deliberately later — writing to `Socket` is what
makes that a small separate step.

The `Socket` contract (`ArduinoLibs/Socket/Socket.h`) is the whole specification: `setup()`,
`initialized()`, `initBuffer()`, `sendMsgTo()`, `getMsg()` ×2, `getLength()`, `headerFromData()`,
`sourceFromData()`, `destFromData()`, over `socket_addr_t` with `SOCKET_ADDR_ANY`.

## What already exists (verified against the repo)

- `-DDISABLE_LORA` exists, and **is set globally, not per-env.** It sits in `[DEFAULT] OPTION_FLAGS`
  (`HMTL/platformio/HMTL_Module/platformio.ini:15`), folded into `GLOBAL_BUILDFLAGS` (:16), which
  every env's `build_flags` interpolates — **including `[env:esp32_lora_gw]` itself** (:217). No
  source consumes it today, so it is inert; the moment new code is guarded on it, the LoRa board's
  own env compiles none of that code. **This is the first thing to fix**, before it becomes
  load-bearing.
- The board env `[env:esp32_lora_gw]` exists (pixels on 25/23, `RS485_HARDWARE_SERIAL=1`).
- **The pin map is now RESOLVED from the schematic netlist** (2026-08-26) — see
  `## Pin map (verified)` below. The repo's reserved set 12/13/14/16/26/32/33 turned out to be
  exactly right and exactly complete, and "CS = 16" from the benchtop is confirmed. The surprise is
  that **RESET is not wired to the ESP32 at all**, which invalidates every `rst` value SparkFun's
  own example sketches use.
- `rfm69_socket_hdr_t` is `{byte ID, socket_addr_t source, socket_addr_t address, byte flags}`,
  packed, with a `static_assert` pinning 6 bytes. **It carries no length field** — length comes from
  the driver via `getLength()`.
- `ArduinoLibs/test/` is a real host harness (Makefile + `shim/{Arduino.h,FastLED.h,Wire.h}`), but
  `TESTS`/`BINARIES` are hardcoded lists, so a new `.cpp` dropped in is never built.

## Decisions (all settled by Adam, 2026-08-26)

- **Driver: `arduino-LoRa`.** Research below. `Socket` keeps ownership of addressing.
- **Reliability (acks / retries / dedup) goes in `Socket`, not here** — an immediate follow-up task,
  so every transport gets it rather than LoRa alone. See
  [[socket-reliability-layer-acks-retries-and-duplicate-suppression-above-the-transport]].
- **No AVR LoRa endpoint for now — but pack the wire protocol so one is possible later.**
  Concretely: `__attribute__((__packed__))` on the header, `static_assert` on its size **and every
  field offset**, and a host check under `-fpack-struct=1` (the AVR-layout proxy) inside ArduinoLibs'
  own suite. It does **not** mean wiring the header into `HMTL/tests/layout/` today — three edits
  across a submodule boundary to cover a peer that does not exist yet. Deferred deliberately, and
  recorded in Notes so the deferral stays visible instead of being forgotten.
- **Encryption: documented as absent.** No software cipher. The README must say plainly that this
  transport is unencrypted, and why the sibling differs — the RFM69 has AES in hardware, the RFM95
  does not — so the gap reads as a decision rather than an oversight.
- **Frequency: 915 MHz (US).**
- **Bridging is coming, and it shapes the header.** LoRa↔RS485/HMTL is planned, possibly other packet
  protocols after. Keep `rfm95_socket_hdr_t` a *generic* socket header — resist putting anything
  LoRa-specific (RSSI, SNR, spreading factor) on the wire; that belongs in a status API, not in a
  header a bridge has to re-frame.

## Driver research (done 2026-08-26; both repos cloned and read)

**The blocking incompatibility, and it is concrete.** RadioHead's addresses are **8-bit**
(`uint8_t _thisAddress`, `RH_BROADCAST_ADDRESS` = `0xff` — 254 usable nodes). `Socket`'s are
**16-bit** (`typedef uint16_t socket_addr_t`, `SOCKET_ADDR_ANY` = `0xFFFF`). A Socket address cannot
round-trip through RadioHead's header. Broadcast maps cleanly (`0xFFFF` → `0xFF`); ordinary addresses
do not. So "map between the two" is not a detail — it is a choice to make RadioHead's 8-bit space the
real address space and constrain `socket_addr_t` on this transport, which every caller then has to know.

| | arduino-LoRa | RadioHead (adafruit fork) |
|---|---|---|
| Files / size | **2 files, 384K** | 104 files, 2.9M |
| Last commit | **2024-06** | 2023-05 |
| Addressing | none — `Socket` owns it | 8-bit, its own |
| Pin config | **`setPins(ss, reset, dio0)`** — exactly this board's need | via driver ctor |
| Radio control | full: SF, BW, coding rate, preamble, sync word, CRC, LNA gain, OCP | full |
| Static RAM | small | `_seenIds[256]` + `_buf[255]` ≈ **511 B** |
| ESP32 | plain Arduino SPI | conditional (`RH_ESP32_USE_HSPI`); a source comment still reads "Currently Teensy and ESP32 only" |

**What RadioHead genuinely buys** — and it is not nothing: `RHReliableDatagram` gives acks, retries,
timeouts and duplicate suppression (`_seenIds`); `RHRouter`/`RHMesh` give multi-hop routing (10-entry
table); `RHEncryptedDriver` wraps any `BlockCipher`. For a multi-node deployment those are real.

**Recommendation: `arduino-LoRa`, and put reliability in the `Socket` layer if it is wanted.** The
features that make RadioHead attractive — acks, retries, dedup — are exactly the features **RS485
also lacks**. Implemented inside RadioHead they benefit LoRa only; implemented once above `Socket`
they benefit every transport, which is the reason this abstraction exists. Taking RadioHead means
paying its weight *and* adopting an 8-bit address space that conflicts with `socket_addr_t`, to get
reliability for one transport out of four.

## Pin map (verified 2026-08-26 against the schematic netlist)

Source of truth: `sparkfunX/ESP32_LoRa_1CH_Gateway`, `Hardware/esp32_lora_gateway.sch` — EAGLE 9.1
schematics are XML, so this is the **netlist**, not a reading of the schematic PDF. U1 =
ESP-WROOM-32, U2 = RFM96W footprint (the board ships the 915 MHz RFM95W).

| Role | ESP32 GPIO | Net name | Evidence |
|---|---|---|---|
| SCK | **14** | `SCK` | `U1.SCK_H/IO14 <-> U2.SCK, J4.3` |
| MISO | **12** | `MISO` | `U1.MISO_H/IO12 <-> U2.MISO, J4.2` |
| MOSI | **13** | `MOSI` | `U1.MOSI_H/IO13 <-> U2.MOSI, J4.1` |
| CS / NSS | **16** | `RFM_CS` | `U1.IO16 <-> U2.NSS` |
| DIO0 (RX/TX done IRQ) | **26** | `RFM_INT/26` | `U1.IO26 <-> U2.DIO0` |
| DIO1 | **33** | `RFM_DIO1/33` | `U1.XTAL_N/IO33 <-> U2.DIO1` |
| DIO2 | **32** | `RFM_DIO2/32` | `U1.XTAL_P/IO32 <-> U2.DIO2` |
| RESET | **none — not connected to the ESP32** | `RFM_RST` | `U2.!RESET <-> R5.1` only, and `R5.2` is on the `3.3V` net |

That accounts for all seven reserved pins and nothing else, so the repo's reserved list needs no
correction.

**RESET is the finding.** `RFM_RST` reaches a 10 k pull-up to 3.3 V and stops there — no GPIO. So
the radio cannot be hardware-reset in software on this board, and any `rst` pin number is fiction.
SparkFun's own sketches disagree with each other *because the value is unused*:

| Sketch | `.rst` |
|---|---|
| `sparkfun/…/Firmware/ESP-1CH-TTN-Device-ABP.ino` | 5 |
| `sparkfunX/…/Firmware/ESP-1CH-TTN-Device-ABP.ino` | 5 |
| `sparkfunX/…/Production/ESP32_Lora_Send_sketch.ino` | **27** |
| `sparkfunX/…/Production/Receiver/…_Receiver_sketch.ino` | **27** |

Two files in the same repo, two different answers, neither doing anything. Copying either into our
driver would have driven a real GPIO for no reason — and 5/27 are both broken out to headers.

**Other board pins, for whoever assigns pixels or RS485 next** (same netlist):

- GPIO 17 → `R4` → green LED (`LED_BUILTIN`); GPIO 0 → the "0" button (`S2`), also a strapping pin.
- Broken out on **J9** (10-pin): 4, 5, 18, 19, 23, SDA 21, SCL 22, RXI, TXO.
- Broken out on **J4** (8-pin): MOSI 13, MISO 12, SCK 14, 27, 25, EN, 3.3V, GND — note the radio's
  SPI bus is shared with this header.
- The shipped RS485 assignment (recv 5 / xmit 19 / enable 18) and this env's pixel pins
  (`PIXELS_DATA=25`, `PIXELS_CLOCK=23`) are all on J9/J4 and **clear of the radio** — confirmed, not
  assumed. The one collision risk is the default-VSPI problem above, which reaches GPIO 23.
- GPIO 12 (MISO) is the ESP32's MTDI strapping pin, which selects flash voltage at boot. It is an
  input during radio RX, so this is a note rather than a problem, but it is why a scope probe or
  external pull on that line can brick a boot.


## Subtasks

- [x] Add `arduino-LoRa` (`sandeepmistry/arduino-LoRa`) as the driver dependency, pinned to a
      specific version rather than floating.
- [x] **Fix the `DISABLE_LORA` plumbing before anything depends on it.** Remove it from
      `[DEFAULT] OPTION_FLAGS` (`platformio.ini:15`) and set it explicitly in the non-LoRa envs that
      want it (`simavr_nano` already lists it separately at :245), so `esp32_lora_gw` is the one env
      where it is absent.
- [ ] **Wire the library into the path the build actually resolves.** `platformio.ini:19` sets
      `lib_dir = /Users/amp/Dropbox/Arduino/libraries`, whose entries symlink into a *separate*
      ArduinoLibs checkout — not this submodule. Symlink `RFM95Socket` there, verify the link points
      at this checkout, and record the step in the README. `ArduinoLibs/setup.sh` links into
      `../libraries` relative to its own checkout, which is not that directory.
- [x] Add `RFM95Socket` and the chosen driver to `[common] esp_only_libs` (:27-31), mirroring how
      `RFM69Socket`/`RFM69` sit in `avr_only_libs`. Every AVR env carries
      `lib_ignore = ${common.esp_only_libs}`; without this, `simavr_nano` and `nano` try to compile
      an ESP32-only library.
- [x] ~~Derive the RFM95's full pin-role map from the SparkFun schematic~~ — **done 2026-08-26**,
      from the EAGLE netlist rather than the PDF. Recorded in `## Pin map (verified)` below; still
      to be copied into the README as part of the README subtask.
- [x] **Bind SPI explicitly to 14/12/13 — this is not optional and it is the likeliest silent
      failure.** `[env:esp32_lora_gw]` uses `board = esp32dev`, whose default `SPI` is VSPI
      (SCK 18 / MISO 19 / MOSI 23 / SS 5), *not* the radio's HSPI-side pins. `LoRa.begin()` calls
      `_spi->begin()` with whatever `SPI` defaults to, so leaving it alone (a) talks to nothing and
      reports `initialized() == false`, and (b) drives GPIO 23, which this env has assigned as
      `PIXELS_CLOCK`. Call `SPI.begin(14, 12, 13, 16)` before `LoRa.begin()`, or hand `LoRa.setSPI()`
      an explicitly-pinned `SPIClass`. SparkFun's own variant hides this by remapping the defaults in
      `pins_arduino.h`; we do not build with that variant.
- [x] **Pass `-1` as the reset pin: `LoRa.setPins(16, -1, 26)`.** `LoRa.cpp:113` guards the reset
      sequence on `_reset != -1`, so this is supported. Passing SparkFun's 5 or 27 would toggle an
      unrelated broken-out GPIO — and 5 is a strapping pin sitting on J9 next to the RS485 header.
- [x] Get a bare radio init compiling for `esp32_lora_gw`. **Done 2026-08-26.** Both envs build:
      `esp32_lora_gw_a` and `esp32_lora_gw_b`, xtensa-esp32, RAM 4.4% / Flash 11.8%, zero compiler
      diagnostics from any file under `ArduinoLibs/`.

      **Proved it compiled the new code rather than trusting the green.** A deliberate `#error` in
      `RFM95Socket::setup()` turned the build RED (`RFM95Socket.cpp:77`), and the dependency graph
      names the source: `RFM95Socket (Path: /Users/amp/src/WLED_dev/ArduinoLibs/RFM95Socket)`, with
      `Socket` and `Debug` from the same checkout and `LoRa @ 0.8.0` from `lib_deps`. Object file
      `libd10/RFM95Socket/RFM95Socket.cpp.o` exists.

      **The `lib_dir` trap is real and this build had to route around it.** The project's
      `lib_dir = /Users/amp/Dropbox/Arduino/libraries` has **no `RFM95Socket` symlink at all**, and
      the symlinks that do exist point at `../ArduinoLibs` — a *different* checkout. A plain
      `pio run` there would not have found the library. Verified with
      `PLATFORMIO_LIB_DIR=/Users/amp/src/WLED_dev/ArduinoLibs`, which is the only configuration in
      which the result means anything. Anyone repeating this must do the same until the `lib_dir`
      task lands.
- [x] Define `rfm95_socket_hdr_t` from `rfm69_socket_hdr_t`'s field set. Pack it; `static_assert`
      size **and every field offset**. **Do not widen anything for MTU:**
      `Socket::sendMsgTo(uint16_t, const byte *, const byte length)` and `byte Socket::getLength()`
      pin payload length to one byte *in the base class*, and LoRa's 255-byte max fits. A >255-byte
      payload would be a change to `Socket.h` and all four transports — separate task, out of scope.
- [x] Implement `RFM95Socket : public Socket` — constructor + `init()` mirroring `RFM69Socket`'s
      shape, then each virtual in turn.
- [x] Map `SOCKET_ADDR_ANY` onto LoRa, which has **no native node addressing** (unlike RFM69, whose
      broadcast is a driver concept via `RFM69_BROADCAST_CONVERT`). Addressing lives entirely in our
      header; every received packet must be filtered in software.
- [x] Wire host tests into `ArduinoLibs/test/`: a `shim/<driver>.h` stub, an **explicit**
      `$(BUILD)/rfm95_socket_test` target with its own `-I` set (the generic pattern rule links every
      test against the RS485 sources — PixelUtil and MPR121 each needed their own target for this),
      and append to `BINARIES`.
- [x] `RFM95Socket/README.md` following `RFM69Socket/README.md`, including pin ownership, the
      interop decision, and the lib_dir symlink step.
- [x] `RFM95Socket/examples/` sketch, plus `ArduinoLibs/platformio/RFM95Socket/` — the standalone
      project that actually builds it, matching `platformio/RFM69Socket/`. Without it the example is
      source nothing compiles.
- [x] Update `ArduinoLibs/README.md`, which hardcodes the transport count in three places: the
      Socket-family table (:53-58), "All three declare `: public Socket`" (:60), and "The RS485,
      RFM69 and XBee header structs are `__attribute__((__packed__))` … 7, 6 and 5 bytes
      respectively" (:81).
- [x] **`library.json` added** — Adam, 2026-08-28: *"give it a library.json, those you mention with
      it are ones I've worked on recently"*, i.e. the split is chronological, not a real convention
      divide. Follows `Socket`/`RS485Utils`: `dependencies` on Socket/Debug plus
      `sandeepmistry/LoRa@0.8.0`, and `"platforms": ["espressif32"]` only — this library is ESP32-only
      and the manifest should say so rather than relying on `lib_ignore` alone. Verified the manifest
      does not change resolution: host suite still 79×2 green, and `libRFM95Socket.a` is still
      archived into both `esp32_lora_gw_a`/`_b` builds.

## Test Plan

- [ ] `cd HMTL/platformio/HMTL_Module && pio run -e esp32_lora_gw` **and prove the new code compiled**
      — put a deliberate `#error` inside the `#ifndef DISABLE_LORA` branch once and confirm this
      build turns red. A green build proves nothing until that is demonstrated, because the env
      inherits `-DDISABLE_LORA` today.
- [ ] `cd HMTL/platformio/HMTL_Module && pio run -e simavr_nano` — AVR build still compiles, with
      the flag excluding the new code. Paired with the check above, the two show the guard both
      excludes *and* includes.
- [ ] Before trusting either `pio run`: confirm the `lib_dir` symlink resolves to **this** checkout.
      `layout_check.cpp` and the top-level `Makefile` both record why — an impossible `static_assert`
      planted in an HMTL header once left `make -C HMTL test-simavr` green.
- [x] `make -C ArduinoLibs/test` — existing host suite still passes. (`make -C ArduinoLibs test` is a
      false green; the Makefile says so.)
- [x] New host tests, no radio needed: header pack/unpack round-trip; address matching including
      `SOCKET_ADDR_ANY`; and the software filter **accepting** own-address and broadcast while
      **rejecting** others. The negative half is the point.
- [x] Cross-ABI layout: `c++ -std=c++11 -fsyntax-only` the header under **both** default and
      `-fpack-struct=1` (the AVR-layout proxy), asserting identical `sizeof` and `offsetof` for every
      field. This runs inside ArduinoLibs' own suite — no submodule boundary crossed — and is what
      makes "packed so an AVR peer is possible later" a checked claim rather than an intention.
      **Deliberately NOT wiring the header into `HMTL/tests/layout/`** (3 edits incl. the hardcoded
      `GUARDED` list in `negative_control.py`): there is no AVR LoRa peer yet, and coverage for a
      peer that does not exist is weight without signal. Revisit when one appears — see Notes.
- [x] `make test STRICT=1` at the super-repo — output **must** now name the new `rfm95_socket_test`
      in the ArduinoLibs section. If it is literally unchanged, the test was never wired into
      `BINARIES` and CI is not running it.

## Testing Required — **OWNED BY THE LAPTOP, not this machine**

Adam, 2026-08-28: *"the mini is not going to be the one testing the lora hardware, that task needs to
transfer to my laptop."* The three items below are therefore **not actionable from the Mac Mini** and
should not be counted against this board's throughput. Whoever runs them files results back here.

Two items in the Test Plan above are in the same position and were left unchecked deliberately —
`pio run -e esp32_lora_gw` / `-e simavr_nano` **inside HMTL_Module**, which additionally cannot mean
anything yet: nothing in HMTL_Module includes `LoRa.h`, so that env compiles none of this library.
They belong with
[[rfm95-integration-for-wled-bridge-rs485-hmtl-packets-and-wled-sync-commands-over-lora]].


- [ ] **Flash `ArduinoLibs/platformio/RFM95Socket/RFM95_SocketTest`, env `esp32_lora_gw_a`** —
      **NOT** HMTL_Module's `esp32_lora_gw`, which is what an earlier draft of this line said and
      which is wrong: nothing in HMTL_Module includes `LoRa.h`, so that env compiles none of this
      library and would come up without a radio at all. `RFM95_SocketTest` is the project that
      instantiates `RFM95Socket`, and it prints the pin map alongside the result.
      Confirm `initialized()` returns true and no boot loop. A wrong CS, RST *or* DIO0 all present
      identically, so passing means the whole pin map is right and failing does not say which pin.
      **CLOSEABLE WITH ONE BOARD.** Also note this sketch is standalone and WLED-free, so the global
      SPI collision documented in
      [[rfm95socket-shares-the-global-spi-whose-begin-is-a-no-op-once-the-bus-is-up]] does **not**
      apply here — nothing else brings the bus up first. That hazard is specific to running under
      WLED, and it is why this test passing would not licence assuming the WLED path works.
- [ ] Two-node send/receive: a second node receives a packet addressed to it and **ignores** one
      addressed elsewhere. Software filtering is the only thing stopping every node processing every
      packet. **NEEDS A SECOND WRL-15006 — inherently two-node, cannot be faked with one board.**
      Flash the peer with env `esp32_lora_gw_b` (it is the same sketch with the addresses swapped).
- [ ] Confirm the RS485 bridge still works on the same board with the radio active — they share it,
      and the pin constraint exists because these two collide.

## Post-Merge Verification

- [x] On merged `main`, confirm the `ArduinoLibs` pointer moved to a commit containing **both** the
      library and its test wiring. The top-level `Makefile` records this exact regression: "main
      briefly pinned esp-now-router at its README-only commit and the router suites vanished from
      `make test` without any signal."
- [x] `make test STRICT=1` on the merged base — the ArduinoLibs section must name the new binary; a
      skipped suite under STRICT is a failure, which is the point.
- [x] `cd WLED && pio run -e ampworks` — unaffected in principle (`platformio.ini` names each
      ArduinoLibs dependency explicitly rather than globbing), but this is the firmware that ships,
      so confirm rather than reason about it.

## Notes

- **`RFM69Socket` is a structural template, not a portable one.** Its `.cpp` carries
  `#error Unknown processor type` for any non-ATmega target, and it sits in `[common] avr_only_libs`,
  so no ESP32 env has ever compiled it. Copy the shape — class layout, packed header,
  `headerFromData()` pointer arithmetic, the `SOCKET_ADDRESS_MATCH` filter in `getMsg()` — but expect
  to diverge on the `INT_FROM_PIN` interrupt mapping (meaningless on ESP32), `RF69_SPI_CS` as a
  compile-time constant (this board's CS must be a parameter), and `init()` constructing the radio
  and calling `initialize()` before `setup()` ever runs.
- Do not treat `rfm69_socket_hdr_t`'s `static_assert`s as a working precedent — only AVR envs compile
  that library, and those resolve from the machine-local `lib_dir`, so those asserts have most likely
  never been evaluated by anything in CI.
- Watch for the trap the RS485 work hit: a diagnostic that reads as reassuring when it is merely
  uninformative. LoRa's RSSI/SNR are the candidates — a healthy RSSI on a packet that failed its
  address filter says nothing about whether addressing works.
- Round-1 plan review caught two errors in the first draft, recorded rather than quietly fixed:
  (1) the headline `esp32_lora_gw` build test would have compiled **nothing**, because that env
  inherits the global `-DDISABLE_LORA`; (2) a subtask to "widen the length field for LoRa's larger
  MTU" rested on a field that does not exist — `Socket.h` pins length to one byte in the base class.
  Both verified against the source before applying.
- **Deferred, on purpose:** the header is packed and offset-asserted so an AVR LoRa peer is possible
  later, but it is NOT wired into `HMTL/tests/layout/`. If an AVR node ever carries its own RFM95,
  that wiring becomes necessary — three edits, one of which is the hardcoded `GUARDED` list in
  `negative_control.py`, without which the new asserts are never perturbed and nothing shows they
  can fail.
- Bridging (LoRa↔RS485/HMTL, and possibly other packet protocols) is planned but out of scope here.
  It is the reason to keep the header generic: a bridge re-frames between transports, so anything
  LoRa-specific on the wire becomes something the bridge has to strip.

# OTA updates — plan

**Why:** the board has no 5V input pad, so box power arrives on `3V3` and back-drives the on-board
regulator. USB must therefore never be connected while the box is powered. OTA removes the only
remaining reason to plug USB in at all, which turns a live hazard into a non-issue.

Target: **roughly compatible with WLED's OTA** — same update mechanisms and tooling, with the
HTTP `/update` path primary (espota UDP is blocked on this laptop's macOS; see below).

## What exists today

| | Status |
|---|---|
| OTA in HMTL | **none.** `EspLibraries/WiFiBase/WiFiBase.h:21` has it as an open question: *"Use the Update and ArduinoOTA libraries?"* |
| WiFi in HMTL_Fire_Control | **none.** No WiFi reference anywhere in `HMTL_Fire_Control_Wickerman/` |
| WiFi infrastructure | `EspLibraries/WiFiBase` — connect w/ known-network list, background connect, AP fallback, config portal, REST endpoints, `checkServer()` |

So this is two pieces of work, not one: **WiFi first, then OTA on top.**

## How WLED does it (the compatibility target)

`WLED/wled00/wled.cpp`:

```c
// setup
if (aOtaEnabled) {
  ArduinoOTA.onStart([]() { /* disables watchdog */ });
  ArduinoOTA.onError([](ota_error_t e) { /* re-enables watchdog */ });
  if (strlen(cmDNS) > 0) ArduinoOTA.setHostname(cmDNS);
}
...
if (aOtaEnabled) ArduinoOTA.begin();

// loop — note all four guards
if (Network.isConnected() && aOtaEnabled && !otaLock && correctPIN) ArduinoOTA.handle();
```

Two independent mechanisms in WLED: **ArduinoOTA** (`espota`) and an **HTTP `/update`** endpoint in
`ota_update.cpp` using `Update.h`.

### ⚠ espota does not work from this laptop — plan for the HTTP path

`WLED/platformio.ini:522-524`, verified:

```ini
# Flash over HTTP (WLED's /update endpoint) via tools/upload_wled.py — macOS Sequoia blocks
# espota UDP, so curl POSTs the .bin. Override the target IP with WLED_IP=<ip> at upload time.
upload_protocol = custom
```

So this project has **already hit and solved this**: macOS Sequoia blocks espota's UDP, and the
`ampworks` env uses a custom HTTP POST instead. An espota-only plan would work on the device and
fail at the toolchain — the exact failure that wastes a bench session.

**Therefore the HTTP `/update`-style endpoint is the primary target, not the afterthought.** It is
also what `tools/upload_wled.py` already drives, so the existing tooling carries over. Implement
ArduinoOTA as well if convenient (it costs little and works from Linux hosts), but do not depend
on it from this machine.

Flags: `otaLock` (no OTA without password; defaults **true** on exposed builds), `aOtaEnabled`,
`correctPIN`.

⚠ WLED's own comment on `aOtaEnabled` (`wled.h:580`): *"Careful, it does not auto-disable when OTA
lock is on."* A known gap in their model. **We should not copy that**, see below.

## Plan

1. **WiFi.** Done — `HMTL_Fire_Control_API.cpp` brings `WiFiBase` up in a FreeRTOS task pinned
   to core 0, so bring-up and HTTP never stall `loop()`. AP fallback is WPA2-password-protected
   with runtime network configuration via the authenticated `/network` endpoint (see WIRING.md
   §7). OTA work builds on that task.
2. **ArduinoOTA.** `setHostname()`, `setPassword()`, `begin()` in setup; `handle()` in the main
   loop behind guards.
3. **PlatformIO upload path — HTTP primary** (espota UDP is blocked on this laptop's macOS;
   see the ⚠ above):
   ```ini
   upload_protocol = custom
   ; POST the .bin to the device's /update endpoint, as WLED's ampworks env does
   ; via tools/upload_wled.py (curl works too)
   ```
   ArduinoOTA/espota can be implemented as well (works from Linux hosts) but must not be the
   only path. Keep a serial env alongside for recovery.
4. **Guards — stricter than WLED, because this drives ignition:**
   - **Refuse OTA whenever the system is armed.** Not just "locked": armed state must hard-block
     `handle()`. This is the gap WLED explicitly leaves open and we should not inherit it.
   - **`onStart` must drive all outputs safe** — ignition off — before accepting an image, not
     merely disable the watchdog.
   - **Outputs must default safe at boot**, since a failed OTA reboots into an unknown image.
   - **Password required.** Never an unauthenticated OTA on a device that can light a fire.
5. **Recovery.** Keep serial flashing possible: with box power off and the 3V3 feed disconnected,
   USB is safe. Document that as the fallback for a bricked OTA.

## Notes

- ArduinoOTA defaults to port **3232** on ESP32; espota discovers via mDNS if a hostname is set.
- LoRa is sub-GHz (915MHz) and WiFi is 2.4GHz, so no RF band conflict.
- **Current budget:** WiFi TX peaks ~500mA on top of everything else, against an LM1117 rated
  800mA. OTA is the worst case — WiFi busy while the rest of the system runs. Another argument for
  a switching regulator (WIRING.md §4).

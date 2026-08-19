# Overnight soak plan — 2026-08-19 (authorized: tests + firmware uploads while Adam sleeps)

**Bus**: 129 (fire controller, USB) + 96 (WLED LED driver, WiFi, on-bus) + 72 (FTDI gateway).
71 disconnected for the night. LEDs authorized to run (garage); strand dimmed.

**Soaks (all read-only on the ignition path — no arming, no poofer commands):**
1. Bus poll loop alternating masters: 72-serial polls 129 & 96; bridge-96 polls 72 & 129.
   Log per-target success/failure, response times, framing/reject counters. Masters serialized
   by the script (one in flight at a time) to keep collision exposure controlled.
2. FC console capture continuous: reboots, MCP23017 errors, MPR121 anomalies, heap.
3. LED board: rainbow at low brightness; sample /json/info (FPS, heap, uptime) every few min.
4. 72: slow blink programs on outputs, periodic poll confirms responsiveness under load.

**Software during the soak**: MCP23017 driver native tests (Wire mock + fail-safe assertions);
investigate WLED DEFAULT_MODE first-boot override mystery. Firmware uploads permitted if a fix
warrants it (e.g. test instrumentation); ignition-path behavior changes stay read-only.

**Morning deliverable**: soak report — uptime/reset count per device, poll success rates,
error counters, anomalies with timestamps, plus test-writing results.

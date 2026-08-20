# OTA updates

**Why:** the SparkFun ESP32 LoRa 1-CH Gateway has no 5V input pad, so box power arrives regulated
on the `3V3` pin and back-drives the on-board regulator. USB must therefore **never** be connected
while the box is powered. OTA removes the only remaining reason to plug USB in at all, which turns
a live hazard into a non-issue.

## Status

| | Status |
|---|---|
| WiFi in `HMTL_Fire_Control` | **done** — merged at `5fb430f`. `HMTL_Fire_Control_API.cpp` brings `WiFiBase` up in a FreeRTOS task pinned to core 0, so bring-up and HTTP never stall `loop()` |
| OTA transport | **HTTP `POST /update`**, guarded. Not espota — see below |
| OTA in the rest of HMTL | none |
| `WiFiBase` OTA support | **none, and never any.** Its header used to claim otherwise; corrected — a caller that needs OTA builds it on `getServer()`, which is what this controller does |

## Transport: HTTP, not espota

espota's UDP is blocked by macOS Sequoia, so an espota-only path would work on the device and fail
at the toolchain — the failure mode that wastes a bench session. `WLED_dev` already hit and solved
this (`WLED/platformio.ini` `env:ampworks` uses `upload_protocol = custom` +
`post:tools/upload_wled.py`), and this is that precedent applied here.

**espota / `ArduinoOTA` is deliberately not implemented, not even as a second option.** One
transport means one set of guards to get right, and the guards are the hard part of this feature.

The consequence worth being explicit about: the upload endpoint is **a guarded surface we own**,
not a WLED UI we are borrowing. Every guard below applies to it, and a refusal is a visible HTTP
error with a reason — never a silent timeout, which an operator reads as a flaky network and
retries until it works.

## Guards — stricter than WLED's

WLED gates OTA on `Network.isConnected() && aOtaEnabled && !otaLock && correctPIN`
(`wled00/wled.cpp:113`). Four guards, and **no concept of output state at all**; its `onStart`
only disables the watchdog. That is a reasonable trade for a light controller. It is not one for
a controller that lights fires.

### 1. Any active switch refuses — not merely "armed"

`fc_is_armed()` is only `POOFER_ENABLE && POOFER_PILOT`, so it ignores the igniter and
program-mode switches entirely. The guard refuses if **any** switch is active: a switch that does
not by itself arm the controller still means an operator has their hands on the box.

Two subtleties, both of which invert the usual fail-safe direction:

- The guard reads the **raw** switch state (`fc_switch_raw()`), not the interlock-qualified state
  (`fc_switch_state()`). The arming interlock reports a switch that has been closed since boot as
  *inactive*, because it has not yet been observed open. Correct for arming; for this question it
  would report a physically-closed switch as inactive.
- It reads them from the **portMUX snapshot**, never from the sensor globals. Those are plain
  non-volatile globals written by `sensor_switches()` on core 1 with no synchronisation; the
  snapshot is the only sound cross-core read.

### 2. Refusal requires positive evidence of health

**This is the guard that is easiest to get backwards, and getting it backwards is silent.**

Everywhere else in this firmware, "the switches could not be read" resolves to *all switches open,
do not arm*. That is right for ignition. For OTA it is a **permit-on-fault**: the guard asks "is
anything active?", and a fault that reports everything inactive answers "no" — so an unreadable
switch bank, or a core 1 that has stopped publishing, would *permit* an upload onto a controller
whose real state is unknown.

So permitting requires **all** of:

- a snapshot has actually been published,
- the last switch read succeeded,
- that snapshot is fresh (default 1 s — loose enough that ordinary loop jitter cannot cause a
  spurious refusal, because a guard that cries wolf gets worked around),
- every switch is inactive.

Any of these missing is a refusal. *"Nothing looked active"* is not sufficient on its own and must
never be allowed to become sufficient.

The decision lives in `fc_ota_guard.cpp` — a dependency-free translation unit, deliberately
separate from the ESP32-only HTTP handler, so a native unit test can exercise every branch
including the ones that are hard to stage on hardware.

**"The last switch read succeeded" is only as good as the flag that carries it.**
`fc_switches_read_ok()` is the single source of truth for switch-read health, and
`sensor_switches()` **clears it on entry** and sets it only after a read completes. That ordering
is the whole property: a flag merely set at the end of a successful read stays TRUE for the entire
duration of a failed one, so a guard reading it during a fault would be told "healthy" while the
fail-safe simultaneously reported every switch open — a permit, in exactly the fault the flag
exists to catch. The same failure path clears `switch_raw[]` too, so a refusal reason can never
quote switch values that came from a read nobody completed.

Anything that later wants to know whether the switches are readable — `/status`, a display, a
future interlock — must read that accessor rather than keep its own flag or infer health from the
switch values. The values cannot carry it: a failed read looks exactly like an idle panel.

### 3. Outputs are driven safe by core 1, and confirmed, before flashing

`HMTL_Fire_Control_API.h` states that the server task *never touches ignition state*, and OTA does
not get an exemption. The API task raises a request and **blocks on an acknowledgement**;
`fc_api_service()`, called from `loop()` on core 1, performs the actual `fc_all_outputs_safe()`
and acknowledges it.

If the acknowledgement does not arrive within the bound, the **update is aborted** — the upload
fails cleanly and can be retried. OTA is *not* latched off until reboot; a controller in a field
with no serial access must not be able to lock itself out of updates.

The guard is then re-evaluated against a *fresh* snapshot including the ack, and re-evaluated
again **on every chunk** of the upload. An upload runs for seconds; per-chunk re-checking is what
makes "a switch blocks OTA" true for the whole flash rather than only for the instant it started.

### 4. Outputs default safe at boot

`setup()` sends cancel+off to every poofer, igniter and pilot output before anything else on the
bus, and before WiFi and the OTA endpoint come up.

**This fixes a hazard that exists today, with or without OTA.** The igniter and pilot are driven
with `sendBurst(..., 30 * 1000)`, which starts a **thirty-second** `TIMED_CHANGE` program on the
remote module and is merely re-sent every 15 s to keep it going — the remote needs no further
commands to hold that output on. A controller that resets mid-burst (brownout, watchdog, a failed
OTA, someone pressing reset) therefore came back up with a remote igniter or pilot still running
for the remainder of its 30 s, and `setup()` sent nothing to close it.

Note that **cancel-then-off** is what actually stops a running burst. A bare value-0 does not: the
remote's timed program simply re-asserts the output for the rest of its duration. The igniter and
pilot off-edges used to send a bare off and so did not truly close a burst still in flight; they
now go through the same `fc_igniter_safe()` / `fc_pilot_safe()` helpers.

#### This was measured, not just reasoned about

A 30 s `TIMED_CHANGE` burst was sent to module 72 output 0 over the controller's serial→RS485 path
(the same wire path `sendBurst()` uses; the controller console confirmed `Forwarding msg to 72`).
At **T+5.1 s** the controller was hard-rebooted with a DTR pulse — a worst-case uncontrolled reset.
It was back up at **T+6.8 s**, and **module 72's console shows no cancel or off of any kind
arriving afterwards.** The controller boots silent. That is precisely the gap this closes.

Two caveats, stated so the result is not read as stronger than it is: burst *receipt* at 72 is
**inferred** from the forward print plus zero framing errors in the window, not directly logged
(72's debug level does not distinguish program installs); and the burn did end on its own, because
a 30 s `TIMED_CHANGE` self-expires.

**The stronger case is the one without a timer.** A plain `VALUE`-driven output has *no*
self-expiry at all: a reboot after a non-timed ON leaves that output latched indefinitely with
nothing to end it. The boot-time safe drive covers that case too, and it — not the timed burst —
is the real argument for this change.

### 5. Password mandatory, no default

`FC_OTA_PASS` has no default, no derived-from-MAC fallback, and no "unset means disabled". An
unset password **fails the build**, mirroring the `FC_WIFI_AP_*` `static_assert` precedent:

```
HMTL_Fire_Control_API.cpp:158:6: error: #error "FC_OTA_ENABLE requires FC_OTA_PASS. Build with -DFC_OTA_PASS='\"<password>\"' or define it in the untracked wifi_credentials.h. OTA on an ignition controller is never unauthenticated."
```

Copied verbatim from a real failing build, backslashes included. GCC echoes an `#error` string
exactly as the source spells it, and the source spells the flag `-DFC_OTA_PASS='\"<password>\"'`
— those `\"` escapes are what make the value a C string literal, and dropping them is precisely
the trap the message exists to steer you away from. Copy the flag from here, not from memory.

(The `#error` lives in `HMTL_Fire_Control_API.cpp`, not `fc_ota_guard.h`, which holds the guard
rather than the credential check. See "Building and uploading" below for the whole command.)

It is a **separate credential** from the AP/API password, authenticated as HTTP Basic user `ota`.
The AP password is handed to anyone who needs to read `/status`, and reading status must not
confer the ability to replace the firmware.

## Building and uploading

OTA is opt-in per environment. The base `touchcontroller_esp32` / `touchcontroller_esp32_bench`
envs stay **serial-only on purpose**: serial is the recovery path, and it has to keep working on
an image whose OTA endpoint is broken.

The password has to reach the **compiler**, as a `-D`. A bare `FC_OTA_PASS=...` environment
variable does not do that and the build will stop at the `#error` — that name is read only by
`tools/upload_ota.py`, at upload time. Two forms work:

```bash
cd HMTL_Fire_Control/platformio/HMTL_Fire_Control_Wickerman

# Build an OTA-capable image (password is mandatory).
# The inner escaped quotes are what make the value a C string literal -- the same
# form wifi_credentials.h.example uses for FC_WIFI_AP_PASS.
PLATFORMIO_BUILD_FLAGS='-DFC_OTA_PASS=\"<password>\"' pio run -e touchcontroller_esp32_ota

# Upload it over HTTP.  This REBUILDS, so it needs both: the -D for the compiler
# and FC_OTA_PASS in the environment for the upload script, and they must match --
# the device authenticates against the password compiled into the image it is
# running, so a mismatch is a 401.
PLATFORMIO_BUILD_FLAGS='-DFC_OTA_PASS=\"<password>\"' \
  FC_OTA_IP=192.168.1.59 FC_OTA_PASS='<password>' \
  pio run -e touchcontroller_esp32_ota -t upload
```

Or put it in the untracked `wifi_credentials.h` next to the WiFi credentials, which needs no build
flags at all and is the easier option if you build often:

```c
#define FC_OTA_PASS "<password>"
```

To confirm the password actually reached the image rather than a header you forgot to save:

```bash
strings .pio/build/touchcontroller_esp32_ota/firmware.bin | grep '<password>'
```

`tools/upload_ota.py` POSTs the image with `curl` (not Python's `urllib`, which Sequoia's
local-network restriction also blocks) and prints the response body, so a refusal shows you which
guard rejected it rather than looking like a hang.

Alternatively, by hand:

```bash
curl -X POST http://<ip>/update --user ota:'<password>' -F update=@.pio/build/touchcontroller_esp32_ota/firmware.bin
```

Responses:

| Code | Meaning |
|---|---|
| `200` | image accepted; the device is rebooting into it |
| `400` | the upload was aborted before it completed — e.g. a client that dies mid-multipart |
| `401` | bad or missing credentials |
| `409` | a guard refused — the body says which, and names the blocking switch |
| `500` | the flash write failed, or the image was incomplete or invalid |

`GET /status` also reports `switches_raw[]` and `switches_read_ok`, so an operator can see what
would block an upload without having to attempt one.

**`GET /update` returns `404`, even on an OTA build.** The route is registered `HTTP_POST` only, so
a `GET` never reaches the handler — and the `404` it falls through to is the same one a build with
no OTA compiled in returns. Probing the endpoint in a browser proves nothing; neither does
`/documentation` (which lists only `addRESTEndpoint()` routes, and `/update` is not one) nor
`/status` (whose `switches_read_ok`/`switches_raw[]` are served by every build). A real `POST` is
the only HTTP-level answer: an OTA build replies `401`/`409`/`200`, never `404`. See
[API.md §4](API.md).

## Flash budget

Both OTA slots are 1280K and the image uses under half of one, so OTA needed no partition change.

| Build | Flash | Slot use | vs `5fb430f` |
|---|---|---|---|
| `touchcontroller_esp32` at `5fb430f` (before this work) | 621,793 B | 47.4% | — |
| `touchcontroller_esp32_bench` at `5fb430f` | 628,533 B | 48.0% | — |
| `touchcontroller_esp32` (OTA not compiled in) | 622,373 B | 47.5% | +580 B |
| `touchcontroller_esp32_bench` (OTA not compiled in) | 629,133 B | 48.0% | +600 B |
| `touchcontroller_esp32_ota` | 632,401 B | 48.2% | +10,608 B |
| `touchcontroller_esp32_bench_ota` | 639,309 B | 48.8% | +10,776 B |

OTA costs about 10 KB. The largest image leaves **671,411 B (51.2%) of the slot free**, so the
1280K partitioning needs no change.

⚠ The **AVR** builds have no such room. They carry no OTA and no WiFi, but they do compile the
shared sensor code, so a change there can push them over:

| Build | Flash | Use | vs `5fb430f` | Free |
|---|---|---|---|---|
| `touchcontroller` | 30,380 B | 98.9% | +74 B | 340 B |
| `firecontroller` | 30,360 B | 98.8% | +78 B | 360 B |

Deduplicating the poofer-disable sequences is what kept this from being worse — the shared safe
drives replaced two hand-maintained copies. Treat the AVR envs as effectively full: anything added
to `Fire_Control_Sensors.cpp` from here needs a size check before it is assumed to fit.

The last 32–42 B of that is the switch-bank read-failure branch in `sensor_switches()`. AVR reads
switches straight off GPIO and cannot hit that branch, but the compiler does not prove it, so the
code is there. It was kept **unconditional rather than `#ifdef`-ed out on the paths that cannot
fail**, deliberately: the failure handling and the `switches_read_ok = false` on entry are the one
thing standing between an unreadable switch bank and a permitted firmware upload, and a version of
them that only exists on some builds is how that protection gets lost at a merge. Forty bytes is
the right price for one implementation.

## Recovery

Serial flashing remains the recovery path for a bricked OTA:

1. **Power the box off.**
2. **Disconnect the 3V3 feed.** This is not optional — box power arrives regulated on `3V3` and
   back-drives the on-board regulator, so USB and box power must never be present together.
3. Then, and only then, connect USB and flash the serial env:
   ```bash
   pio run -e touchcontroller_esp32 -t upload
   ```

## Notes

- **An OTA reboot cost one framing error at the one receiver that was instrumented.** A controller
  hard reboot produces boot-ROM line chatter on the shared bus, which a listener rejects as a bad
  frame; an OTA reboots the controller by definition, so a framing error around an OTA is expected
  and benign rather than a fault. Recorded here so it is not later mistaken for one.

  **What was actually measured:** one receiver (module 72), one reboot, `+1` on its framing-error
  counter — a single observation from a single bench session on a single bus. Supporting data:
  72's counter was flat across 8.3 h overnight, and all 146 accumulated errors trace to a churn
  window of phantom-touch traffic plus mid-soak reflashes, so the bus was clean enough for that
  `+1` to be attributable rather than noise.

  The same `+1` is **expected** at every other receiver on the bus — they all see the same
  chatter — but that **has not been measured**: no other receiver was instrumented, and the
  counter only increments on corruption *after* a valid STX, so a listener that happens to be
  mid-frame at the reboot could plausibly count differently. Treat "one per receiver" as the
  working expectation, not as a fleet-wide measured fact.
- LoRa is 915 MHz and WiFi is 2.4 GHz, so there is no RF band conflict.
- **Current budget:** WiFi TX peaks around 500 mA on top of everything else, against an LM1117
  rated 800 mA. OTA is the worst case — WiFi busy while the rest of the system runs. Another
  argument for a switching regulator (`WIRING.md` §4).

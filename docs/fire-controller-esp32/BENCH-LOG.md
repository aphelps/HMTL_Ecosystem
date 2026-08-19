# Bench log — 2026-08-17 overnight probe

State of the board and what was proven, so the next session starts from evidence rather than
guesses.

## Board state as left

| | |
|---|---|
| Port | `/dev/cu.usbserial-2110` |
| Firmware | **HMTL_Module**, env `esp32_lora_gw` (new, added to `platformio/HMTL_Module/platformio.ini`) |
| HMTL address | **129** |
| EEPROM config | rs485 only — `recv=5 xmit=19 enable=18` (orientation B) |
| Power | USB only. LM1117 bench-tested good but deliberately **not** wired to `3V3` |
| Command server | stopped; port free |

Restart the link with:
```bash
cd HMTL/python && python3 bin/HMTLCommandServer -d /dev/cu.usbserial-2110 -b 115200 &
python3 bin/HMTLClient -A 129 --poll     # the ESP32 itself — known good
python3 bin/HMTLClient -A 71  --poll     # the trigger boards — currently silent
```

## Proven working

- **ESP32 identified:** ESP32-D0WDQ5-V3 rev 3.0, 16MB flash, MAC `34:ab:95:5c:dc:d4`.
- **Toolchain:** builds and flashes reliably over USB.
- **EEPROM config (single output):** writes and reads back correctly.
- **HMTL_Module runs** and reads its config: `rs485 recv=… xmit=… enable=18`, address 129.
- **Serial ↔ message layer end to end:** polling the ESP32's own address returns a valid
  response — `type:2 (POLL) dev_id:129 addr:129`. This is the important one: it proves the USB
  serial path, the command server, `MessageHandler`, and the EEPROM config are all correct.
- **MPR121:** initialises on **our** pin assignment — `IRQ Pin:4`, `I2C SDA:21 SCL:22`,
  `MPR121: Initialized`. Not yet touched by hand, so touch events are still unconfirmed.

## Not working — RS485 to modules 71 / 72

The ESP32 **transmits**: the server log shows `Forwarding msg to 71`. Nothing ever answers;
every attempt ends in `Data request time limit exceeded`.

**Both UART orientations were tested and both failed**, so `RXD`/`TXD` is very likely *not* the
problem:

| Config | `recv` | `xmit` | Result |
|---|---|---|---|
| A | 19 | 5 | no response from 71 or 72 |
| B | 5 | 19 | no response from 71 or 72 |

This was testable in software because `RS485Socket::init()` calls
`serial->begin(baud, SERIAL_8N1, recvPin, xmitPin)` with the **configured** pins
(`RS485Utils.cpp:93`) — so swapping RX/TX is a config change, not a rewire.

### What that isolates

Everything from the laptop down to the ESP32's UART is proven good. The fault is in the RS485
**physical layer** — one of:

1. **Modules 71/72 not powered**, or not actually connected to A/B.
2. **A/B swapped** between the MAX3485 and the bus — the classic silent RS485 failure.
3. **Termination/bias** — no 120Ω at the ends, or two at one end.
4. **`EN` (GPIO 18) not switching the transceiver**, so the driver never enables.
5. The MAX3485 module's own pad order differing from its silkscreen.

### Cheapest next checks (need a person)

- Confirm 71/72 are powered and their A/B actually land on the same pair.
- Meter `EN` (GPIO 18) during a poll — it must pulse high while transmitting.
- Meter A−B at the ESP32 end during a poll — a driven bus swings a couple of volts; a flat line
  means the transceiver is not driving.
- Swap A/B at one end and retry. One wire, and it is the single most likely cause.

## Other findings this session

- **`ArduinoLibs/platformio/MPR121BasicUse/platformio.ini:74`** begins with `:` instead of `;`,
  which makes PlatformIO fail to parse the whole file — every env in that project was
  unbuildable. Fixed locally; needs pushing.
- **HMTL_Module on ESP32 brings up WiFiBase** and opens an AP (`HMTL_Module` / `12345678`).
  Relevant to [OTA.md](OTA.md): the WiFi integration OTA needs already exists in HMTL_Module,
  it is HMTL_Fire_Control that lacks it. Also relevant to the AP-exposure note in WIRING.md §7.
- The old firmware on the board was `MPR121BasicUse` built from its `esp32dev` env, which sets
  `-DIRQ_PIN=23`. That is where the misleading `IRQ Pin:23` came from — the previous flash, not
  the wiring, which is correctly on GPIO 4.

---

# Session 2 — RS485 bus connected (2026-08-17 evening)

A/B now physically connected between the ESP32's MAX3485 and module 72. No termination
(deliberate — at 28000 baud over bench cable it is unnecessary, and the modules get used in
varying bus configurations).

## Result: still no traffic, in EITHER direction

| Test | ESP32 config | Result |
|---|---|---|
| ESP32 polls 72 | recv=19 xmit=5 (A) | no response; **module 72's console shows nothing arriving** |
| 72 polls ESP32 (129) | recv=19 xmit=5 (A) | no response; ESP32 console shows nothing arriving |
| ESP32 polls 72 | recv=5 xmit=19 (B) | no response; module 72 console shows nothing arriving |

The ESP32 firmware **is** transmitting — the server log shows `Forwarding msg to 72` every time.

## What this rules OUT  ⚠ [PARTIALLY RETRACTED — see Session 2c]

> The A/B-polarity bullet below was WRONG: garbage is silently discarded below `getMsg()`, so
> "module 72 saw nothing" never distinguished inverted from absent. Session 2c has the
> correction; Session 2d confirmed A/B swap WAS the fault.

- **UART orientation (`RXD`/`TXD`).** Both were tested *with the bus connected* this time. Both
  dead in both directions. Last night's test of the same two configs was meaningless because A/B
  were not wired — do not treat that as corroboration.
- **A/B polarity alone.** A pure A/B swap inverts the signal but still delivers edges; the
  receiving module would see *something*. Module 72 saw nothing at all.
- **Anything above the transceiver.** Polling the ESP32's own address (129) still returns a valid
  response, so serial path, command server, MessageHandler and EEPROM config are all good.

## What remains — all need a meter

Ranked by likelihood:

1. **The MAX3485 module is not powered.** Meter VCC→GND on the module itself: expect 3.3V. This
   single fault produces exactly this symptom — dead in both directions, transmitter happily
   sending into nothing.
2. **A/B not landing on the intended pads**, or not making contact. Continuity-check from the
   module's `A`/`B` pads to module 72's RS485 terminals.
3. **`EN` (GPIO 18) not toggling.** Meter it during a poll — it must pulse high while
   transmitting. Stuck low = driver never enables; stuck high = receiver never enables.
4. **The module's pad order not matching its silkscreen.** Continuity-check ESP32 GPIO 19/5/18
   to the pads labelled `RXD`/`TXD`/`EN`.

Note the board is marked `RS485 V2.05` / `127294G_Y1060`, logic side `EN VCC RXD TXD GND`, bus
side `GND A B`.

## Session 2b — instrumented the framing counter (decisive)

**Correction to the section above:** the claim that "module 72 saw nothing, therefore A/B polarity
is ruled out" was **wrong**. Garbage on RS485 is *silently discarded* — `RS485_non_blocking`
rejects byte-pairs failing the form check, bad CRCs and overflows below `getMsg()`, so they never
reach any debug print. A miswired bus and a disconnected one look identical on the console.

`getFramingErrorCount()` (new in ArduinoLibs `bc56ddc`) is the instrument that tells them apart.
Added to `status_update()` in `HMTL_Module.ino` behind `#ifdef USE_RS485`.

### Control — the existing AVR bus is GOOD

Polling **71 through module 72** returns `dev_id:71`. So 72's transceiver, the 71↔72 wiring,
28000 baud, and running without termination are all **proven working**. The ESP32 is the only
suspect part.

### Result — the ESP32 receives literally nothing  ⚠ [CONCLUSION RETRACTED — see below]

13 polls generated on the bus from 72. The ESP32's counter never moved:

```
 * rs485 framing_errors:0 rejects:0     (before traffic)
 * rs485 framing_errors:0 rejects:0     (after 13 polls)
```

**[RETRACTED in Session 2c]** ~~A/B polarity is therefore NOT the fault~~ — this inference was
wrong: the counter only increments after a valid STX (`RS485_non_blocking.cpp:157`), so
inverted-pair and disconnected-bus both read zero. Session 2d proved the pair WAS swapped.

### Remaining causes, narrowed

1. **MAX3485 module unpowered** — meter VCC→GND on the module: expect 3.3V.
2. **A/B not electrically connected to the module** — continuity-check the pads themselves.
3. **`RXD` pad not reaching the ESP32's configured RX pin** — continuity-check.

`EN` stuck is a poor fit: stuck high would leave the ESP32's driver permanently enabled and jam
the bus, but 71↔72 traffic is unaffected — so the ESP32 is almost certainly not driving the bus
at all, consistent with 1 or 2.

## Session 2c — CONCLUSION: A/B are swapped

**Retract everything above that says polarity is ruled out.** Three of my inferences were wrong,
all the same mistake — reading an instrument that could not detect what I was asking it.

### The three bad inferences, and why

1. **"MIN MAX showed nothing on GPIO 18, so the firmware is not asserting EN."**
   The Fluke 289's MIN MAX has **100ms** response; its Peak mode is 250µs. An EN assertion is
   ~14ms. The mode could never have caught it. (The 87V has 1ms MIN MAX — I quoted the wrong meter.)
2. **"A 0x55 blast produced no framing errors at 72, so nothing arrives."**
   `RS485_non_blocking.cpp:157`: `if (!haveSTX_) break;` — bytes before a frame start are discarded
   **without** incrementing `errorCount_`. A raw 0x55 stream contains no STX, so the counter was
   guaranteed to stay 0 regardless of what arrived.
3. **"The framing counter is zero with real frames, so polarity is fine."**
   Same clause. With the pair inverted every byte is bit-complemented, STX never matches,
   `haveSTX_` never goes true, and bytes are dropped silently. **Inverted and disconnected are
   indistinguishable on this counter.** It can only see corruption *inside* an already-started
   frame.

### What the measurements actually establish

| Fact | Evidence |
|---|---|
| GPIO 18 drives | pin toggle test: 3.3V |
| EN wire reaches the module | metered at the module's own EN pad: 3.3V |
| RS485 socket registered | `Sockets configured:2 outputs_found:64 has_rs485:1` |
| Module powered | 3.3V VCC, power LED lit, solidly seated |
| **Transceiver drives the bus** | A/B move from 2.7/1.9 idle to ~1.6V mid-rail when transmitting |
| **The pair reaches module 72** | same voltages measured at 72's terminals |
| 72's receiver works | polling 71 through 72 returns `dev_id:71` |
| 72 never sees a valid frame | framing counter 0, no valid message, no response |

### The fingerprint

```
                  A pad      B pad
  ESP32 end:      1.69 V     1.56 V
  Module 72 end:  1.56 V     1.70 V
```

1.69 pairs with 1.70; 1.56 pairs with 1.56. **ESP32 `A` is wired to 72 `B`, and ESP32 `B` to
72 `A`.** Every other link in the chain is proven good, and an inverted pair is exactly consistent
with "signal present at both ends, no valid STX ever seen."

### Fix

Swap A and B at **one** end. Then poll 72 from the ESP32. Note the counter is not a useful
progress indicator here — with correct polarity it should stay 0 *and* the poll should succeed.

(Depends on 72's readings having been taken in A-then-B order; if they were taken B-then-A the
pair is already correct and this conclusion is void.)

## Session 2d — RESOLVED: A/B swap was the fault

Swapped A and B at one end. Immediate result, with the poll loop already running:

| Test | Result |
|---|---|
| ESP32 polls 72 | **`dev_id:72`**, every poll; 72's console logs `Poll req src:129` |
| ESP32 polls 71 (relayed on the shared bus) | **`dev_id:71`** |
| Blink program to 72's RGB LED via the ESP32 | sent + acked (visual confirmation pending) |
| 72 framing counter | 0 — clean link |
| ESP32 framing counter | 1 — single error, consistent with the hot-swap cutting a frame mid-flight |

**The ESP32 fire controller talks to the legacy HMTL modules over RS485.** Stage 3 of the
bring-up is complete. The voltage-fingerprint method (matching per-wire DC averages end-to-end)
is what found the swap; the framing counter never could have (see 2c).

---

# Session 3 — overnight: config bug fixed, fire control running end-to-end

## The P1 config bug — root cause and fix

`hmtl_write_config()` passed `hmtl_output_size()`'s return straight to `EEPROM_safe_write()` as a
length. Under `-DDISABLE_MPR121` (set by HMTLPythonConfig's esp32 env) the mpr121 case is compiled
out and the size lookup returns **-1** — which wrote a poisoned record (START, len 0xFF, no data,
CRC-of-nothing) and **reported success**. Readback failed CRC at addr=45: the **mpr121/third**
record (earlier notes said "first" — wrong). AVR config-sketch builds never disable MPR121, hence
ESP32-only.

Fixed twice over: `hmtl_write_config` now returns -3 loudly when it cannot size a record (covers
every disabled type), and the esp32 config-sketch env enables MPR121 (the driver builds fine on
ESP32). Verified: full rs485+pixels+mpr121 config round-trips cleanly.

## Pin correction

The **proven** UART mapping (live polls post-A/B-swap) is **RX=GPIO 5, TX=GPIO 19**. The .ino
defaults, the JSON config, and WIRING.md all said the opposite and have been corrected. EEPROM
rewritten to recv=5 xmit=19.

## Fire control firmware — running

`touchcontroller_esp32_bench` env (poofers → 71/72, LIGHTS → 67/absent): boots clean through all
three fatal checks. MPR121 initialized (12 thresholds, IRQ 4, useInterrupt=1), 12 pixels on 25/23,
ProgramManager running sparkle + blink, ~360KB free heap. Verified end-to-end **through the fire
controller's own stack**: polls answered by both 71 and 72; VALUE 255→0 pulse delivered to 71's
poofer output 0 (unloaded); 72's RGB LED left blinking **green** as the visual all-good.

## Safety finding (live demonstration)

At boot: `Switch on 0..3` → `POOFERS ENABLED`. The stock `SWITCH_PIN_1..4` (26/27/32/33) are the
LoRa radio's DIO/RST lines on this board; they idle low, so **all four ignition switches read
closed and the controller arms itself spontaneously**. Bench-harmless; on a real box this is the
fail-unsafe case the docs warned about. The switches MUST move to the MCP23017 before anything
flammable is attached. Deliberately left as-is in the bench env, with a warning comment.

## Also fixed along the way

- `ArduinoLibs/Debug/Debug.cpp` `debug_print_memory()` referenced avr-libc's `__brkval`/
  `__heap_start` unconditionally — any ESP32 build at DEBUG_LEVEL >= 4 calling `DEBUG_MEMORY()`
  failed to link. Now uses `ESP.getFreeHeap()` on ESP32.
- Future I2C collision noted: the ESP32 LCD is `LiquidCrystal_I2C(0x27)` and the Waveshare
  MCP23017 defaults to 0x27 — the expander needs an address jumper when it arrives.

## Board state as left

| Device | State |
|---|---|
| ESP32 | `touchcontroller_esp32_bench` fire control, addr 129, POOF1=71 POOF2=72 |
| Module 72 | instrumented HMTL_Module v29, RGB blinking green |
| Module 71 | stock, on the bus, answering |
| Command server | running on the ESP32 (`/tmp/fc-srv.log`), port 6000 |

---

# Session 4 — review round: interlock landed, board behavior changed

Four self-reviews (Fable subagents) ran against the four PRs; 22 findings total, all addressed
with follow-up commits and per-finding replies. Two mattered beyond bookkeeping:

**The controller no longer arms itself at boot.** The Fire_Control review correctly rejected
"warning comments" as an interlock (the production env shared the radio-line switch pins with
LIVE poofer addresses). Now in firmware, verified on this bench:

- *Seen-open latch:* a switch counts as closed only after being observed open since boot.
- *INPUT_PULLUP:* found by boot-testing the latch — GPIO 27 as bare INPUT **floats and flaps**,
  and one noise "open" would have armed the latch for noise "closes". Pulled up it holds a
  steady open. (Side-effect: strong evidence GPIO 27 is NOT hard-wired to LoRa RST — a driven
  reset line would not float.)
- 20s boot capture: switches 0/2/3 suppressed, 27 latches once then silent, **no POOFERS
  ENABLED**, clean boot to ready.

**The config-write refusal is now atomic.** A config the build cannot size leaves EEPROM
completely untouched (header included). Regression test verified non-vacuous: fails with read
error -5 against the non-atomic version.

## Board state as left (final)

| Device | State |
|---|---|
| ESP32 | `touchcontroller_esp32_bench` @ `4e335e6` (interlock + pullups), addr 129, POOF1=71 POOF2=72, disarmed at boot |
| Module 72 | instrumented HMTL_Module v29; RGB blink program may still be resident |
| Module 71 | stock, on the bus, answering |
| Servers | none running; both USB ports free |

PRs awaiting human review: HMTL#12, ArduinoLibs#14, HMTL_Fire_Control#3, HMTL_Ecosystem#4
(docs — includes this file through Session 3; Session 4 additions ride the same branch).

---

# Session 5 — touch verification: found and fixed an ESP32 crash-on-touch

The one subsystem no review or idle test could reach — a finger on the electrodes — found a
crasher on the first try.

**Bug:** the MPR121 ESP32 ISR wrapped its flag set in `noInterrupts()/interrupts()` — task-context
macros, illegal inside an IRAM ISR. First touch corrupted interrupt state → next I2C transaction
deadlocked → interrupt watchdog reset (`rst:0x8 TG1WDT_SYS_RESET`). A touch-triggered **crash
loop** in which zero touch events ever surfaced; with a finger still near the pad, the board
re-crashed ~3s after each reboot. Fixed in ArduinoLibs (bare flag-set ISRs + `volatile triggered`).

**Verified:** pre-fix, 3 watchdog resets and 0 events in one touch window; post-fix, **7/7 touches
surfaced (pins 0/1/2) with 0 resets** at `DEBUG_LEVEL_MPR121=5`.

Also note for future sessions: with the arming interlock holding all switches off, touch events
produce **no visible output at default debug levels** — the action paths are switch-gated and the
raw prints are DEBUG5. "No output" after a touch is ambiguous unless `DEBUG_LEVEL_MPR121=5` is
set. (This session's capture tooling also failed twice before producing evidence — a heredoc
launch that silently held the port and consumed events, then unmanaged DTR/RTS. The working
pattern: file-based capture script, explicit reset pulse, verify heartbeats before trusting it.)

## Final board state

| | |
|---|---|
| ESP32 | `touchcontroller_esp32_bench` (committed code, standard debug levels), addr 129, disarmed |
| Verified chains | USB↔serial · EEPROM config · RS485→71/72 (polls + poofer pulses) · pixels/programs · **MPR121 touch→IRQ→app** |
| PRs | HMTL#12, ArduinoLibs#14 (now incl. the ISR fix), HMTL_Fire_Control#3, HMTL_Ecosystem#4 — all reviewed, all findings addressed |

---

# Session 6 — 2026-08-18/19: submodule bump validated; fire-control dev stashed

Development on the fire-control module is **paused here by request**; this entry is the resume
record. Everything below was committed and pushed before stashing — there is no uncommitted work.

## Open PRs (the stashed development)

| PR | Branch | What it carries |
|---|---|---|
| HMTL_Fire_Control#4 | `esp32-fire-control-wifi` | WiFi + `/status` API on a core-0 pinned task; WPA2 AP fallback; authenticated runtime config (`/network`, `/appass`); native-harness fix (HMTLProtocol include, stub Socket/pinMode); `fc_is_armed()` + interlock-qualified switch tests |
| EspLibraries#1 | `fire-control-wifi` | WiFiBase upstream: auth on `/network`/`/scan`/`/known`, null-server guards, honest background flag, WPA2 password floor, `authorizeConfigRequest()`, bug fixes |
| HMTL#13 | `wifibase-auth-compat` | HMTL_Module opt-out (`allowUnauthenticatedConfig(true)`), copy-assign removal, stored-network sentinel |
| HMTL_Ecosystem#5 | `fire-control-wifi-docs` | WIRING.md §7 rewritten for the second-core + authenticated-AP design; OTA.md step 1 |
| HMTL_Ecosystem#6 | `bump-submodules-post-merge-2026-08-18` | `.gitmodules` → aphelps remotes + gitlinks to the merged mains; hardware-validated (below) |

All four WiFi PRs are self-review-converged (findings fixed, threads resolved). Approved
decisions baked into the plan/PRs: upstream WiFiBase fixes with auth (not removal),
second-core FreeRTOS server task, password-protected AP with no-reflash configuration.

## Merge order + gotchas on resume

1. EspLibraries#1 first (FC#4 compiles against its `authorizeConfigRequest()`), then HMTL#13
   (or HMTL_Module builds get 403s from the auth default), then FC#4, then the docs (#5) and
   bump (#6). #6's FC-suite gate goes green only after FC#4 merges (the harness fix rides there).
2. **Reflash the ESP32 after FC#4 merges** — the bench image predates the WiFi work.
3. Bench items still owed (from the WiFi plan's Testing Required): AP join + wrong-password
   rejection · `/status` while armed · adversarial client during pilot keepalive · reboot
   persistence after a `/network` join · `/appass` round-trip · blink cadence during bring-up.
4. WiFi builds print the derived AP password on serial only when no NVS/build-flag password is
   set; credentials go in `wifi_credentials.h` (gitignored; `.example` committed).

## Hardware validation performed this session (recorded mains)

ESP32 (addr 129, `/dev/cu.usbserial-2110`) flashed `touchcontroller_esp32_bench` @ FC main
8ee3ca8; trigger board 72 (`/dev/cu.usbserial-FTFO9I0N`) flashed `mini` @ HMTL main 1c4e2de.
Serial POLL → forwarded over RS485 → 72 answered ("Poll req src:129") → response relayed back;
two VALUE pulses handled; `rs485 framing_errors:0 rejects:0`. Board 71 not connected.

Port-opening gotcha re-confirmed: opening either serial port auto-resets the board (DTR on
open) even with setDTR(False) issued post-open — hold BOTH ports open across a whole test
sequence and wait out the boots before sending.

## Worktree state as left

Parent on `main` (gitlink for HMTL_Fire_Control intentionally ahead at the merged main until
#6 lands); HMTL and HMTL_Fire_Control worktrees on their merged mains; EspLibraries on
`master`. All feature branches pushed; nothing uncommitted anywhere.

---

# Session 7 — 2026-08-19: MCP23017 switches integrated; full ignition chain validated

The switch inputs moved off the placeholder GPIOs onto the MCP23017 expander (0x26, A0
jumpered after an i2c-scan caught the factory 0x27), read via a register-level Wire driver on
branch `mcp23017-switch-inputs` with the doc's fail-safe semantics: any bus failure reads all
switches OPEN and freezes the seen-open qualification. LEDs wired and validated (a
shifter-VCC-to-ground miswire was the one hardware fault found). Bus leg re-wired; after an
unplugged-connector detour, address 129 is discoverable by Scan from board 72 — the ESP32
answers bus polls both directions.

**Milestone: full ignition chain live on the bench** — physical switch closes (via PA0-PA3)
arm the controller, MPR121 touch sensors fire the poofer outputs on trigger board 71/72 over
RS485. Switches → I2C → interlock → arming → touch → RS485 → trigger outputs, all real
hardware. (Optocoupler input stage and real rocker switches still to come per WIRING.md §7;
driver native tests owed before the branch PRs.)

---

# Session 8 — 2026-08-19 (day): overnight soak results; reboot-mid-burst hazard demonstrated

**Overnight soak (129 + 96 + 72):** fire controller ran 7.6+ h continuous on the merged WiFi +
MCP23017 build, zero unexpected resets, RSSI −43…−46. WiFi task closed out per Adam
(/ack-tested on FC#4 with per-item evidence/waiver annotations; physically-gated items carried
into a new bench-validation task by the todo-handler session). LED board's 03:17 outage was a
human power cut; rejoined instantly on restore.

**Framing-error timeline (72's counters):** all 146 accumulated errors trace to the previous
evening's churn window (floating-electrode phantom-touch stream while 71 was on the bus, plus
mid-soak reflashes); the overnight bus was pristine — flat for 8.3 h. An FC hard reboot costs
exactly +1 framing error at receivers (boot-ROM line chatter on the RS485 pins) — benign.

**Reboot-mid-burst hazard (empirical, LEDs only):** 30 s TIMED_CHANGE burst to 72 → FC
hard-rebooted at T+5 → FC boots back SILENT (no cancel/off ever sent) → only the actuator-side
30 s timer ends the burn. Plain VALUE outputs have no self-expiry at all, so a reboot after a
non-timed ON latches the output indefinitely. Confirms the hazard the todo-handler session's
boot-time safe-drive fix addresses (riding its OTA branch).

**MCP driver branch complete:** native tests added (scriptable Wire mock; fail-safe contract
pinned; 34/34), rebased onto merged main, pushed — ready for PR flow.

---

## Session 9 — 2026-08-19 (daytime, off-bench): I2C fault-pattern audit

No hardware touched. Triggered by the todo-handler session's OTA self-review, which found a
permit-on-fault bug (stale `switches_read_ok` surviving a failed MCP23017 read — its fix, not
a defect in the switch driver's fail-safe contract). Auditing for the same shape turned up
**four instances in one day of the identical bug pattern**: a consumer that cannot distinguish
*"I know this is fine"* from *"I have no idea"*.

| # | Where | Consumer blind to | Status |
|---|---|---|---|
| 1 | OTA guard reading `switches_read_ok` | flag stale-true across failed read | fix in progress (clear-on-entry, `fc_switches_read_ok()` accessor = single source of truth) |
| 2 | `/status` endpoint switch fields | "all open" vs "I2C bus dead" | noted on `mcp23017-switch-inputs` tracking task — expose error count + health flag when dispatched |
| 3 | Pilot-flame design: absent broadcasts | "pilot proven" vs "no data" | already handled in task design (absent ⇒ unproven, not all-clear) |
| 4 | **MPR121 touch path** (`readTouchInputs`) | failed read vs no-change; `touchStates` frozen at last good value | **P1 task filed — live defect on the fire path** |

**Instance 4 is the serious one — it triggers rather than gates.** `MPR121::readTouchInputs()`
returns the same `false` for "no change" and "I2C read failed" (`Wire.available()<2`), keeping
`touchStates` at its pre-failure value; `triggered` is cleared *before* the failed read and the
chip holds IRQ asserted until a successful status read, so with edge IRQs one failed read can
wedge the driver stale permanently. `checkPulse()` starts poofs as repeat-forever blink
programs (`sendHMTLBlink(..., 0xFFFFFFFF, ...)`) running autonomously on the *remote* module,
cancelled only on the falling touch edge — so an MPR121 fault mid-touch means the cancel is
never sent and the poofer pulses until the operator disarms. Independently source-verified by
the todo-handler session before it raised the task P2→P1 and pinged Adam.

**Defense-in-depth boundary (verified):** a *whole-bus* fault also fails the MCP23017 read →
switch fail-safe forces all switches open → enable-switch cascade `sendCancelAndOff`s every
poof output. Covered. Exposure is specifically an **MPR121-isolated fault** (its SDA stub,
brownout, latch-up) — switches stay armed, stale-touch latch holds.

Bench methods, for the joint session: SDA-to-ground at the expander faults the *whole bus*
(right for the OTA-refusal test — MCP fail-safe disarms in parallel); isolated-MPR121 faulting
needs the MPR121's own SDA stub lifted. Three-part MPR121 test queued in the tracking task:
demonstrate on current fw / verify enable-switch cancel / verify auto-cancel on fixed fw.

Fix direction recorded on the task: read-health tracking in `sensor_cap()`; on sustained
failure treat all pads as **released and actively send the cancels** (a local state drop is
not enough — the blink is latched remotely); consume the `fc_switches_read_ok()`-style single
health flag rather than inventing another.

**Session 9 addendum — field symptom raises instance 4 above the theoretical.** Adam reports
having occasionally observed *sequenced poofing getting stuck*. That is **consistent with, not
confirmation of**, the stale-touch latch — other candidates produce the same symptom (SEQUENCE
program state, the HMTL_NO_OUTPUT tracker, RS485 frame loss dropping a cancel). Recorded as a
correlation to test, not a closed diagnosis; closing on the assumption the symptom is fully
explained would risk leaving a second cause live.

Four falsifiable predictions (written into the P1 task by the todo-handler session) to check
against the next occurrence:
(a) the stuck output follows a **touch**, not an idle period;
(b) it does **not self-recover** — only disarm (enable-switch cascade) or power cycle stops it;
(c) the **touch panel is unresponsive afterwards** until reset (`triggered` cleared before the
    failed read + chip holds IRQ asserted ⇒ edge-IRQ driver wedge);
(d) a **single output latched on**, not the sequence advancing wrongly.
(b)+(c) together are near-diagnostic; (c) alone — dead touch panel after the stuck poof,
recovering only on reset — is essentially this bug and nothing else. Sequence still advancing,
or self-clearing ⇒ cause is elsewhere, keep looking.

Capture review (this session): **no touch-event lines exist in any bench capture** (overnight,
day, evening-churn) — current builds don't emit touch state at their debug level. So existing
logs can neither support nor refute (c), and a future field occurrence won't be diagnosable
from logs either. Instrumentation gap noted on the P1 task: enable touch logging (or a
periodic touch-state sample line) in the next FC bench build so the predictions become
answerable from captures. Joint-session MPR121 test gains an explicit observation step:
**after the induced isolated fault, is the touch panel still responsive?** (prediction (c)).

---

## Session 10 — 2026-08-19 (off-bench): pilot-flame review fallout landing in bench territory

The pilot-flame adversarial review came back CHANGES_SUGGESTED with a fatal design finding
(peer's, module-side: drive-time override wrote the struct but `hmtl_update_output()` only runs
under `if (update)`, so loss-of-flame-while-poofing was never pushed to the pin — being fixed by
forcing update every non-permitted iteration, PWM timer holds the pin not the struct). Two of the
review's findings land on hardware/bridge, which is this session's side:

**1. Bridge amplifies the broadcast hazard off-bus (verified against source).** The peer found
that one broadcast frame — address=ANY, output=HMTL_ALL_OUTPUTS(0xFE), value=255 — opens every
pilot valve and igniter, because 0xFE fan-out reaches ungated actuator classes. My rs485_bridge
makes this *reachable over WiFi without authentication*: serviceUdp() validates only frame
STRUCTURE (startcode/version/length/CRC/size — rs485_bridge_protocol.h:259) and forwards using
the frame's own destination, explicitly not rewriting addressing. No address allow-list, no
output filter. So any device on Acropolis can open every gated output with one datagram to the
bridge port. Filed P2 in WLED_dev todo (slug rs485-bridge-forwards-unauthenticated-broadcast-...);
safety floor = refuse to forward broadcast/ANY-addressed or ALL_OUTPUTS frames, additive to
validation, no config. Stronger options (address allow-list, UDP auth) recorded there too.

**2. No watchdog + AVR reset tri-states pins (independently confirmed).** `grep -rn 'wdt_|watchdog'
HMTL/` returns **zero** — verified this session. Any enforcement whose mechanism is "we rewrite
the solenoid pin every loop pass" has no floor under it: a hang or reset leaves the pin floating,
and on AVR reset every pin tri-states. The durable fix is hardware — a **pull-down on each
solenoid driver input** so a floating/tri-stated line reads OFF (valve closed) — plus a watchdog
so a hung loop resets rather than latching. This is a bench/hardware task for whenever Adam picks
up pilot supervision; a software pin-rewrite and a bridge filter both *reduce* exposure but
neither is a substitute for the pull-down. Recorded on the pilot-flame task as the hardware floor.

Neither finding is closed; both are filed for Adam's direction. Hardware untouched this session.

**Session 10 addendum — de-scope splits the bridge finding (Adam: trusted senders only).**
Adam de-scoped security: assume only intended users put frames on the bus; no auth, no
allow-list, no attacker in the model for now. That cleanly separates the two things the bridge
finding had conflated:
- SECURITY half (UDP auth, address allow-list) — DEFERRED. WLED_dev task stays filed but sits;
  revisit only if the model changes (public network, shared venue, untrusted operators).
- SAFETY half — SURVIVES untouched: output=0xFE (ALL_OUTPUTS) fan-out reaches ungated actuator
  classes and is reachable by ENTIRELY LEGITIMATE traffic (HMTL_Module_API.cpp:88 already builds
  such a message; a routine "all outputs off" hits it). Zero adversaries required. Primary fix is
  module-side (exclude PILOT/IGNITER/POOF from fan-out — in the pilot-flame plan); the bridge's
  share is to not transparently relay an actuator-class ALL_OUTPUTS frame, kept consistent with it.
Related CRC point (peer's, module-side): the HMTL CRC is written but never verified on receive.
~~[CORRECTED — see session 11 EMC correction below] Earlier framing claimed ignition-time bit
errors are the EXPECTED case because a spark igniter fires on the same board as the RS485
transceiver, justifying the magic-plus-complement override payload as noise rejection.~~ This
premise is FALSE: the igniter is a HOT-SURFACE IGNITER (resistive heater), not a spark gap, so
it radiates no broadband RF. The CRC/complement requirement no longer has an established
justification and goes to Adam as "re-justify or drop" (see correction below). Pull-down/watchdog
floor unchanged and still with Adam.

---

## Session 11 — 2026-08-19 (autonomous soak watch): module 129 poll-timeout trend

Soak observation, no action taken (hardware reserved; 129 is telemetry, not an actuator path).
Module **129 is flapping on polls** and the rate is trending UP:
  03:00–08:00  ~15–28% timeout   |   10:00  50% (6/12)   |   11:00 30% (19/63)   |   12:00 30% (8/27)
**Discriminator (the useful part):** module 72 is polled the IDENTICAL way (UDP → bridge master
→ RS485 bus) and is 100% OK across the same window; 96/WLED and the FC are healthy throughout.
So this is NOT the shared WiFi/bridge leg and NOT generic UDP frame loss (those would hit 72's
polls too) — it localizes to **129's own bus segment or the module itself**. The bridge master
poll is single-shot with a 3s timeout and NO retry (soak2.py:16-24), so each FAIL is one lost
round-trip; a per-module ~30% loss on one node while its bus-mate is clean points at 129's leg
(marginal termination/connector) or 129 firmware, not the network.
For Adam at the bench: worth reseating 129's bus connector / checking its termination first —
cheapest thing that fits the signature. Not urgent (no actuator or safety path affected). Will
push a notification only if 129 goes fully offline (as 96 did on the overnight power cut) or the
loss rate stays sustained >60%.

---

## Session 11b — 2026-08-19: EMC framing CORRECTED (Adam: it's a hot-surface igniter)

Correcting a factual error I put into session 10 rather than let it propagate. Adam clarified the
igniter is a **hot-surface igniter (HSI)** — a resistive SiC/SiN element that glows — NOT a spark
generator. That invalidates the "EMC / radiated-RF" justification I wrote for the CRC + magic-plus-
complement override payload: a resistive heater is not an arc source and does not radiate the
broadband RF a spark gap does. The peer's earlier "physics not malice" phrasing was the same error;
both are retracted.

- What SURVIVES (weaker, different in kind): an HSI draws meaningful current, so switching it is a
  CONDUCTED transient / possible supply droop, not radiated EMI. That can still corrupt a frame but
  is a weaker argument and points at supply decoupling + sequencing as much as at frame validation.
- CONSEQUENCE: with security de-scoped AND the radiated-EMI premise false, the CRC/complement
  requirement has no justification we've actually established. NOT being deleted quietly, NOT kept
  on a known-wrong premise — goes to Adam as "re-justify (conducted-transient is the candidate) or
  drop." Peer is folding this into round-2.

Two HSI facts that matter MORE than the CRC point (peer logged both on the pilot-flame task):
1. The 15 s energisation is APPROPRIATE, not suspicious — HSIs need ~15–60 s to reach ignition
   temperature. Open BENCH question for me (hardware, not design): SiC igniters degrade with
   thermal cycling, so **cycle life under repeated 15 s energisations** is worth measuring on the
   bench once hardware is in.
2. SAFETY-RELEVANT — an HSI **stays hot for tens of seconds after de-energising** and can still
   ignite gas while cooling. So a 30 s inter-trial gap is NOT a window where ignition is impossible.
   Any purge premised on "igniter off ⇒ no ignition source" is wrong; safe ordering is close-gas-
   then-wait, not treating the gap as inert. Bears on Adam's open purge question.

**Session 11b addendum — the still-hot fact is a DESIGN HAZARD, not a purge note.** Following the
HSI cooldown through the current design rules (peer's escalation, going to Adam): after 3 failed
attempts the module STOPS retrying, but under the rules as written it must never autonomously
CLOSE the pilot valve — only never open it. So the terminal state of a failed ignition sequence
is: **unburnt gas flowing toward a surface still hot enough to ignite it, with the module having
deliberately stopped intervening.** That is delayed ignition of an accumulated cloud — the exact
hazard conventional gas practice purges against — and worse with an HSI than a spark: a spark that
stopped sparking is inert; an HSI that stopped being driven stays an ignition source for tens of
seconds. This gap exists WHETHER OR NOT a purge is adopted, because "module never opens the pilot"
says nothing about gas already flowing when retries exhaust; stopping the retries is what makes the
hazard the RESTING state.
Design-rule tension this surfaces (for Adam/round-3, peer's call to raise): the rule "module never
closes the pilot valve autonomously" is precisely what makes the hazard terminal — it may conflict
with fail-safe-close and need revisiting. Hardware floor connection: reinforces the default-CLOSED
solenoid + pull-down argument (session 10), and adds that the pilot valve specifically needs a
defined safe terminal state, not just a safe boot state.
Bench-testable (adding to the joint checklist): after a simulated 3-fail exhaustion, observe the
commanded valve state and confirm gas is NOT left flowing toward a (still-hot) igniter — on a
bench-safe surrogate output, never live gas + HSI.

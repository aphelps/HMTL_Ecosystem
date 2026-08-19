# Joint bench session — runnable checklist

Carries the WiFi items waived at the 2026-08-19 close-out (per the todo-handler session's
`bench-validate-the-wifi-items-waived-at-close-out` task) plus the evidence upgrades both
sessions asked for. Each item names who does what: **[A]** = Adam's hands, **[C]** = Claude
drives/observes from the Mac.

## Setup
- [ ] Bus: 129 + 96 + 72 (the soak topology). FC on USB. 72's console via the command server.
- [ ] Confirm soak/captures paused before any reflash ([C]).

## 1. No-known-SSID boot
- [ ] [C] Build `touchcontroller_esp32_bench` with `wifi_credentials.h` renamed away (AP-only).
- [ ] [C] Flash; watch serial ≥5 min: `setup()` completes, no Guru Meditation, sensors + RS485
      behave; WPA2 AP up (softAPIP non-zero).
- [ ] [A] Try to join the AP with a WRONG password from a phone — association must be REJECTED
      (this was the un-testable-without-hands item).
- [ ] [A] Join with the real password; [C] confirm `/status` served over the AP.

## 2. AP-salt equality (proves the __DATE__-salt removal; todo-handler session's spec)
- [ ] [C] Flash a `-DFC_WIFI_AP_PASS=...` flag build → capture the AP name + confirm the flag
      password is required (no serial capture of it — [A] joins with it).
- [ ] [C] Reflash a DEFAULT build (no flag, no NVS) → capture the DERIVED password boot line.
- [ ] [C] Reflash the default build AGAIN → capture the derived password line a second time.
- [ ] **Assertion: the two derived passwords are IDENTICAL** (equality is the test).

## 3. Armed service check (needs arming — [A] grounds PA1+PA2 or closes real switches)
- [ ] [C] `curl /status` while armed: still answers, `armed:true`, surface still read-only.
- [ ] [C] Flame commands + pilot keepalive unaffected by concurrent HTTP load (watch 72's log).

## 4. Adversarial HTTP, unarmed with pilot closed ([A] closes pilot, enable open)
- [ ] [C] `nc <fc-ip> 80` held open sending nothing → the 15s pilot keepalive
      `sendBurst(..., 30*1000)` still goes out on schedule (watch 72's console); pilot never drops.
- [ ] [C] `curl -X POST -F 'f=@-' http://<fc-ip>/info` holding the body open (the unbounded
      `_uploadReadByte()` spin) → record whether the API task ever recovers, AND whether the
      RS485 SEND PATH stays responsive throughout (per the todo-handler session: not just /status).

## 5. Safe-drive + OTA guard (PR#5 @ a2c71ce — semantics FINAL, settle ping 2026-08-19)

Guard permits an upload only when: every switch reads inactive (any active switch refuses,
arming or not) AND the last switch read succeeded (`fc_switches_read_ok()`, cleared on entry,
set only after a completed read) AND the cross-core snapshot is fresh (`published_ms` +
validity, fail-closed) AND an OTA password is compiled in (else `#error` at build). onStart
requests safe-state from core 1 and blocks on the ack; ack timeout aborts (retryable).

### 5a. Boot-time safe-drive — before/after pair, eyes on
- [ ] [C] BEFORE (pre-fix firmware): 30s TIMED_CHANGE burst to 72 output 0, FC hard-reboot at
      T+5. [A] EYES ON 72's LED: stays lit through the reboot, extinguishes only at ≈T+30 —
      upgrades the earlier "receipt inferred" run to observed.
- [ ] [C] BEFORE, **VALUE variant (the stronger case)**: plain VALUE=255 to 72 output 0, FC
      hard-reboot. [A] EYES ON: output stays latched INDEFINITELY (no timer will end it) until
      manually cancelled — demonstrates why safe-drive matters beyond timed bursts.
- [ ] [C] AFTER (PR#5 firmware): repeat BOTH; [A] confirms the output drops at FC boot
      (safe-drive cancels), for the timed and the latched case alike.

### 5b. MCP-fault OTA refusal — THE headline item (empirical twin of the permit-on-fault bug)
- [ ] [A] Hold SDA to ground at the expander (non-destructive; every read NACKs).
      NOTE: this faults the WHOLE bus — MPR121 + LCD included — so the switch fail-safe
      disarms in parallel. That is the intended case here; isolated-device faulting is §8.
- [ ] [C] Attempt an OTA upload. MUST REFUSE. Record the refusal path (which condition tripped).
- [ ] [C] Confirm `/status` shows `switches_read_ok:false` while faulted (snapshot copy — up to
      one loop old by construction; poll twice before judging).
- [ ] [A] Release SDA. [C] Confirm reads recover, `switches_read_ok:true`, and OTA now permits
      (with all switches inactive) — proves refusal was the guard, not a wedge.

### 5c. Any-active-switch refusal
- [ ] [A] Ground exactly one NON-arming switch input (e.g. PA0/lights). [C] Attempt OTA:
      MUST REFUSE — semantics are "every switch inactive", stricter than "not armed".
- [ ] [A] Release. [C] Confirm OTA permits again.

### 5d. Happy path + safe-state-on-start observable
- [ ] [C] With a program RUNNING on 72 (blink), start a permitted OTA. On the 72-side serial
      capture: safe-state frames (cancel/off) arrive BEFORE the transfer starts — verifies the
      onStart ack path sends on the RS485-owning core and actually reaches the bus.
- [ ] [C] Complete the upload; FC reboots into new image; RS485 regression (poll 129→72 both
      directions) passes.

### 5e. Snapshot freshness (host-verified; bench spot-check only)
- [ ] [C] Fail-closed staleness is covered by native tests (3 of 4 verified to FAIL pre-fix) —
      those are the DEFINITIVE freshness test. Bench spot-check only: across two /status polls
      ≥2s apart, `uptime_ms` advances. Caveat on this one's shape — uptime_ms is a firmware-produced
      value, so the check corroborates rather than proves: it would pass vacuously if uptime were
      ever incremented off the core whose liveness it's meant to signal. It's a cheap sanity signal
      for soak tooling (frozen core 1 ⇒ uptime stops), NOT a substitute for the host-side test.

## 6. Stored-network path (the useStored no-op finding)
- [ ] [C] From the AP or LAN: authenticated `/network` join to Acropolis; power-cycle; confirm
      the controller rejoins from SDK-stored credentials with NO compiled-in credentials present.

## 7. Pilot-broadcast staleness (when the FC-half of pilot supervision lands)
- [ ] [C] With a module broadcasting proven-flame and poofs permitted, **[A] pull that module's
      power mid-run** (or [C] disconnect its bus leg).
- [ ] [C] Confirm the controller refuses poof commands after the staleness bound expires —
      silence must read as UNPROVEN, never as the last good report continuing. Record the
      elapsed time between the last heard broadcast and the first refused poof.
- [ ] [C] Restore the module; confirm poofing re-permits only after fresh proven-flame
      broadcasts arrive (not merely on the module reappearing).

## 8. MPR121 isolated fault — stale-touch latch (P1 task; three-part + discriminator)
- [ ] [A] Lift the MPR121's OWN SDA stub (not the shared bus — switches must stay healthy).
- [ ] [C+A] CURRENT firmware: touch a poof pad, induce the fault mid-touch. Expect: poof keeps
      pulsing (bug demonstrated); [A] flips enable switch → cascade cancels (mitigation works).
- [ ] [A] **Prediction (c) observation: is the touch panel responsive after the fault?**
      Dead-until-reset ⇒ stale-touch latch confirmed as the field-symptom cause.
      Still responsive ⇒ RS485 frame loss becomes lead suspect for the field symptom.
- [ ] [C] FIXED firmware (when the P1 lands): same fault ⇒ pads treated released, cancels sent
      automatically, no operator action needed.

## 9. Failed-ignition terminal state (when pilot supervision lands; SAFETY)
Assert on the MEASURED drive line, not the firmware's command variable — the property is "is the
valve-drive output physically de-energised", not "did the code set its command flag to closed".
(Reading back the commanded state would be a vacuous test: it asserts what the code controls, not
the effect it must produce. See the pattern named 2026-08-19 across three PR vacuous tests.)
- [ ] [A] Drive a simulated 3-attempt ignition FAILURE (surrogate output — LED/bench load, NEVER
      live gas + HSI). METER or scope the physical valve-drive line (or eyes-on the surrogate LED):
      after retries exhaust, is the drive output actually LOW / de-energised?
- [ ] [C] Cross-check the commanded state agrees with the measured line — a DISAGREEMENT (command
      says closed, line still driven, or vice-versa) is itself a finding. The measured line is the
      pass/fail; the command read-back only corroborates.
- [ ] Note (HSI physics): the igniter stays ignition-capable for tens of seconds after
      de-energising, so "retries stopped" is NOT "ignition impossible". Terminal state must be
      safe on its own — measured drive de-energised — not rely on the igniter being off.

## 10. Connect-does-not-reset (PR#14 HMTLCommandServer, ESP32-over-USB)

Run cheapest-first: the banner check may make the scope trip unnecessary.

- [ ] [C] **Banner check (cheap, run first).** Connect with the new client while watching the FC
      serial stream. If a boot banner appears, a reset HAPPENED — done, no scope needed, and the
      no-reset guarantee is refuted. Asymmetry, state precisely: presence PROVES a reset; absence
      does NOT prove no reset. The reset pulse is at open(), so there is a race between the port
      becoming readable and the banner being emitted — a banner can be partly or wholly missed.
      One clean connect is suggestive, several more so, but a missed banner is indistinguishable
      from no reset on the screen alone.
- [ ] [A] **Scope (the settler, only if the banner check is clean).** Scope DTR, RTS, and EN
      during a connect. The pre-open DTR/RTS settings + HUPCL-clear are ASSERTED, not demonstrated
      — pyserial's open() DTR-then-RTS ordering can still pass an EN-low pulse. This trace is the
      only thing that distinguishes "no reset" from "reset whose banner I missed".
- [ ] [C] Reset-CAUSE code does NOT help here: an EN/DTR auto-reset reports `rst:0x1
      (POWERON_RESET)`, the SAME code as a real power cycle (RTC can't tell "supply came up" from
      "EN released"; esptool resets show 0x1 too). Only SW/watchdog classes (0x3 SW_RESET, 0xc
      SW_CPU_RESET, RTCWDT/TG*WDT) discriminate, and an EN reset produces none — so do NOT read an
      observed POWERON_RESET as "no connect-reset". [Correction 2026-08-19: an earlier note called
      a captured POWERON_RESET mild positive evidence; that was wrong.]
- [ ] [C] AVR DTR-cap reset is NOT software-suppressible — for AVR modules, connect WILL reset;
      plan captures around that (hold the port open across the whole sequence).

## 11. Frame-truncation resync (PR#14 d27b320 — PROVISIONAL, pending re-review confirmation)
Status: the fix (truncated frame at a read boundary → reader resynchronises past it instead of
dying or silently dropping the body) was INFERRED from the diff by the peer session (no skip
markers + a resync test present), NOT yet re-reviewed. Treat this item as provisional; the peer
will confirm or report the fix is narrower than it looks. Do not run/rely on it as settled until then.
- [ ] [C] Send a BODY-BEARING frame (NOT a poll — a poll is exactly 8 bytes and straddles nothing,
      which is how the original guard was vacuous) engineered to straddle a serial read boundary
      into 72's bridge path.
- [ ] [A] Pass/fail is the FAR END's physical response — the target output actually changing (eyes
      on LED / metered drive line). NOT the sender reporting success, and NOT the receiver's own
      parse-log line: the bug produced a header-only item + stray text that a receiver log would
      happily describe as "a message arrived", so a log-reading test passes on the broken code.
- [ ] Pairs with the §5d/§10 wire instrumentation on 72 — same setup, no new rig.

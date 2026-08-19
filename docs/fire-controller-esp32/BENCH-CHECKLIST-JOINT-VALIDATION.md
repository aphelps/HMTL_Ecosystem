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
- [ ] [C] Fail-closed staleness is covered by native tests (3 of 4 verified to FAIL pre-fix).
      Bench spot-check: across two /status polls ≥2s apart, `uptime_ms` advances — the implicit
      liveness signal soak tooling relies on (frozen core 1 ⇒ uptime_ms stops advancing).

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

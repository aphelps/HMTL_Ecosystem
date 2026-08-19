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

## 5. Burst-demo evidence upgrade (for the boot-time safe-drive PR)
- [ ] [C] Re-run: 30s TIMED_CHANGE to 72 output 0, FC hard-reboot at T+5.
- [ ] [A] EYES ON 72's output-0 LED: lit through the FC reboot, extinguishes at ≈T+30 —
      upgrades "receipt inferred" to observed.

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

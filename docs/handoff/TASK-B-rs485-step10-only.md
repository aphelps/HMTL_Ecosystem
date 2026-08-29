# TASK B (REDUCED) — RS485 bridge: load and hitch watch only

**Ten of eleven steps are discharged by bench evidence.** Verified against the primary source
(`HMTL_Ecosystem/docs/led-driver-esp32/BENCH-LOG.md`, Session 1, 2026-08-19) by the Mac Mini
todo-handler agent on 2026-08-29 — the quote was read at source, not taken on trust.

Full plan (all 11 steps, if a result looks wrong and you need the surrounding context):
`WLED_dev/todo_plans/rs485-bridge-hardware-bring-up-on-real-esp32-legacy-hmtl-bus.md` on the Mac Mini.

## What the bench evidence covers

> **MOSTLY DISCHARGED BY BENCH EVIDENCE, 2026-08-19.** Raised by the laptop agent; I read the
> primary source rather than taking the quote —
> `HMTL_Ecosystem/docs/led-driver-esp32/BENCH-LOG.md`, "Session 1 — 2026-08-19". Board 1 is a
> SparkFun ESP32 LoRa 1-CH Gateway with MAX3485, running the RS485 bridge at address 96.
>
> **Covered — steps 5 through 9.** "UDP probe → bridge(96) → RS485 @28000 → legacy module 72 →
> poll response relayed back to the probe. VALUE pulses on 72's output 0 handled
> (`hmtl_handle_msg` ×2). Bridge counters and 72's `framing_errors:0 rejects:0` agree." Plus, at
> session close, blink PROGRAMs to module 71 outputs 0-3 at four rates with program-cancel and
> value-off cleanup. That is the master path, the slave path, the response relay and the poll
> exchange — against an **unreflashed legacy module**, which is this task's acceptance criterion.
>
> **The pin difference is immaterial.** Step 1 says GPIO 16/17/18; the bench ran 5/19/18 under the
> `led_driver` profile. The bridge takes its pins from runtime config (`uart2, rx5/tx19/en18` per
> Session 2), so the code path under test is identical — the numbers in step 1 are wiring
> instructions, not an assertion being tested. Not a gap.
>
> **The transport matches too.** This plan is UDP throughout (port 21331); the bench run was a UDP
> probe. The laptop flagged HTTP as a possible mismatch — that concern applies to *its* separate
> `POST /hmtl` task, not to this one.
>
> **STILL OUTSTANDING: step 10 only — and the same log makes it MORE worth doing, not less.**
> Session 1 records: *"One frame of a 4-frame burst (150 ms spacing) was silently lost and
> succeeded on retry — one-shot UDP has no delivery guarantee."* That is ~25% loss at a *gentle*
> rate. Step 10 pushes 200 back-to-back with the LEDs on a busy effect, which is precisely the test
> that would characterise whether that loss is the rate limiter behaving, or something worse.
> Closing this task on the strength of the log would retire the one check that bears on the only
> anomaly the log actually found.


Ten steps, in dependency order. Each gives **who runs it**, the **exact command**, **what pass looks
like**, and **what a failure most likely means**. Steps 1-3 must pass before 4-10 mean anything.

Mapping to the original six checks carried over from the merged task, so nothing was dropped:
old (1)→steps 3+4, (2)→step 6, (3)→step 7, (4)→step 8, (5)→step 3, (6)→step 9. Steps 0, 5 and 10 are new.

## The one remaining step

- [ ] **(10) [C→A] Load and hitch watch.** With the LEDs running a busy effect, push sustained UDP:
  ```bash
  for i in $(seq 1 200); do python3 tools/rs485_bridge_probe.py --host <ip> --emit rgb --addr <module> --rgb 0,255,0 --no-wait; done
  curl -s http://<ip>/json/info | python3 -c 'import json,sys; u=json.load(sys.stdin)["u"]; [print(k,"=",v) for k,v in u.items() if k.startswith("RS485")]'
  ```
  *Pass:* no reboot (WLED's uptime keeps climbing), no watchdog, `tx-drop` growth is bounded and explained
  by the rate limit, and **[A]** sees no visible LED stutter.
  *Why this is worth a step:* `sendMsgTo` blocks while it flushes the UART — roughly 48 ms per frame at
  28000 baud with Gammon byte-stuffing — which is why transmission is rate-limited to **one frame per
  `loop()`**. Under enough offered load the queue drops rather than the strip stalling, and `tx-drop` is
  the counter that says so. A reboot here is the finding; a rising `tx-drop` is the design working.

**Code follow-ups this runbook exposed — both now fixed.** The ACK guard (a poll *response* was
decoded as a fresh request and answered) and the response addressing (the header carried the bridge's
own address, which a stock `HMTL_Module` discards) landed in
`[[fix-hmtl-poll-path-defects-bridge-mishandles-poll-responses-and-misaddresses-its-own]]`, host-tested
with a negative control per fix. Steps 8 and 9 above are written against the fixed behaviour.

## Why this one is NOT a formality

Session 1 of the same bench log records: *"One frame of a 4-frame burst (150 ms spacing) was
silently lost and succeeded on retry — one-shot UDP has no delivery guarantee."* That is roughly
25% loss at a gentle rate. This step is the only check that distinguishes "the rate limiter
behaving as designed" from something worse under sustained load. Closing the task on the strength
of the log would retire precisely the test aimed at the only anomaly the log found.

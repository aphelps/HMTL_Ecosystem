# Fire Controller — WiFi and status API

How to actually use the ESP32 fire controller's network interface: get it on a network, find it,
read status, and change its WiFi without reflashing.

Implemented by `HMTL_Fire_Control_Wickerman/HMTL_Fire_Control_API.cpp` (`touchcontroller_esp32`
and `touchcontroller_esp32_bench` envs) on top of `EspLibraries/WiFiBase`.

**Read [WIRING.md](WIRING.md) §7 first if you are anywhere near gas.** The API is read-only with
respect to ignition — nothing reachable over HTTP can arm, fire, or change a poofer address — and
the web server runs in a FreeRTOS task pinned to core 0 so HTTP can never delay the flame path in
`loop()`. What HTTP *can* do is repoint the controller's WiFi (with the password) and deny the
status API (without it).

---

## 1. The 60-second version

```bash
# 1. Watch serial at boot to learn the AP name, the default password, and the IP
pio device monitor -e touchcontroller_esp32_bench
#    API: AP ssid=FIRE-CONTROL-1A2B default pass=fire-9c41e0d7
#    API: up, AP=FIRE-CONTROL-1A2B IP=10.0.0.57

# 2. Read status (no auth needed)
curl -s http://10.0.0.57/status | python3 -m json.tool

# 3. List every endpoint the running image has
curl -s http://10.0.0.57/documentation
```

Everything else on this page is detail on those three, plus the AP-fallback join flow.

An image built with `-DFC_WIFI_AP_SSID`/`-DFC_WIFI_AP_PASS` needs no serial capture for step 1 — its
AP name and password are whatever the build set, and the boot line reads `pass=<configured>` instead
of printing one. See §3, [Building with known AP credentials](#building-with-known-ap-credentials).

## 2. Getting the controller onto a network

Three ways, in the order the firmware tries them:

| Source | How | Survives reflash? |
|---|---|---|
| Runtime join via `/network` | authenticated request over the AP, below | Yes (ESP32 NVS) |
| `wifi_credentials.h` | copy `wifi_credentials.h.example`, set `FC_WIFI_SSID`/`FC_WIFI_PASS`; gitignored | No |
| Build flags | `-DFC_WIFI_SSID=...` `-DFC_WIFI_PASS=...` | No |

The fallback AP has its own pair, `FC_WIFI_AP_SSID`/`FC_WIFI_AP_PASS`, settable the same two ways —
§3.

At boot the API task first retries **the network last joined at runtime** (the SDK-stored
credentials — note a *failed* `/network` attempt overwrites them too, see §3), then any compiled-in
network. With none of them reachable it raises its own
access point (§3). A failed bring-up is retried every 30s from the API task — it never blocks
`loop()`, so the controller keeps running flame effects with no network at all.

### Finding the IP

No mDNS and no fixed address. Read `API: up, AP=... IP=...` off serial at boot — printed at DEBUG1,
so it appears on production images too — and the 10s status line repeats it. Failing serial access,
find it on the router's DHCP lease list (the ESP32 default hostname on this core is
`esp32-XXXXXX`, the last three MAC bytes, unless the router shows the MAC) or scan the subnet for
something answering `/status`:

```bash
for i in $(seq 2 254); do
  curl -s -m 0.3 "http://10.0.0.$i/status" | grep -q armed && echo "10.0.0.$i"
done
```

## 3. AP fallback and the join flow

With no known network in range the controller comes up as its own **WPA2** access point:

- **SSID:** the `FC_WIFI_AP_SSID` build flag if the image sets it, otherwise `FIRE-CONTROL-XXXX`
  with `XXXX` derived from the ESP32's efuse MAC — stable per board and unique on a bench with
  several of them.
- **Password:** never open. Precedence is **NVS (set at runtime via `/appass`) → `FC_WIFI_AP_PASS`
  build flag → a per-device default derived from the MAC and a fixed salt**. The derived default is
  **stable**: same board, same value, across reflashes and rebuilds — write it down once. (It was
  salted with `__DATE__` until 2026-08-19, which made it change on every build from a different
  day; that is gone, because re-reading serial after a reflash needs exactly the access you do not
  have when you need the AP.) Only the derived default is printed on serial — it is the only one you
  have no other way to learn; a password you configured yourself prints as `pass=<configured>`, so
  the boot line tells you which regime the board is in without echoing a secret. A sub-8-char
  password from NVS is refused (WPA2 floor) and the derived default is used instead, so the AP is
  never open and never dead; a sub-8-char or over-23-char `FC_WIFI_AP_PASS` cannot get that far —
  it fails the **build** (below).
- **Address:** the ESP32 softAP default, `192.168.4.1`.

### Building with known AP credentials

Set both flags and the AP's name and password are known before the board is ever powered on — no
serial capture to get onto it, which is the point:

```bash
PLATFORMIO_BUILD_FLAGS="-DFC_WIFI_AP_SSID='\"FIRE-CONTROL-WICKERMAN\"' \
                        -DFC_WIFI_AP_PASS='\"burningman26\"'" \
  pio run -e touchcontroller_esp32
```

Or permanently, appended to the env's existing `build_flags` in
`platformio/HMTL_Fire_Control_Wickerman/platformio.ini`:

```ini
[env:touchcontroller_esp32]
build_flags =
    %(GLOBAL_BUILDFLAGS)s
    %(ESP32_TOUCH_FLAGS)s
    -DFC_WIFI_AP_SSID='"FIRE-CONTROL-WICKERMAN"'
    -DFC_WIFI_AP_PASS='"burningman26"'
```

Both forms need the inner quotes — the value is a C string literal, not a bare token. The same two
names also work as `#define`s in the gitignored `wifi_credentials.h` (copy
`HMTL_Fire_Control_Wickerman/wifi_credentials.h.example`), which is the better home for anything you
would not want committed.

| Flag | Range | Unset |
|---|---|---|
| `FC_WIFI_AP_SSID` | 1–32 chars (the ESP32 softAP limit) | `FIRE-CONTROL-XXXX` from the MAC |
| `FC_WIFI_AP_PASS` | 8–23 chars (the range `/appass` also accepts) | derived per-device default, printed at boot |

Out-of-range values **fail the build** (a `static_assert` in `HMTL_Fire_Control_API.cpp`) rather
than being truncated at runtime. That is deliberate: a truncated name or password is a credential
you do not have, discoverable only off the serial console of a board that may already be installed
— exactly the failure these flags exist to prevent. Note `/appass` can still change the password at
runtime on a flag-built image; the flag only sets the *initial* one.

This same password is the HTTP Basic password (user `admin`) for every mutating or
SSID-disclosing endpoint.

Join a network from the AP — associate with `FIRE-CONTROL-XXXX`, then:

```bash
curl -s -u admin:fire-9c41e0d7 \
  'http://192.168.4.1/network?ssid=MyNetwork&passwd=MyPassword'
# {"connected":true,"ssid":"MyNetwork","local_IP":"10.0.0.57","elapsed":2184}
```

On success the controller is on both interfaces at once, so the request answers over the AP even
though the station link just came up. The credentials are persisted by the ESP32 WiFi driver, so
**after a power cycle it rejoins that network directly and the AP does not come up** — verify with
`curl http://<lan-ip>/status`. A wrong password answers `400` with `"connected":false` within the
connect timeout (8s — some access points report the auth failure sooner), and the controller stays on the AP
for this session. But note the failed attempt has **already replaced the driver-stored
credentials** (the ESP32 core persists a `WiFi.begin()` config before it tries to connect), so the
network you were on is gone: the next boot retries the *wrong* one before falling back to the AP.
Re-issue `/network` with the right credentials rather than rebooting.

There is deliberately **no WiFiManager captive portal**: it blocks indefinitely inside startup,
which is not acceptable on an ignition controller. The AP plus `/network` replaces it.

## 4. Endpoints

Port **80**. Response bodies are `application/json` — including `/documentation`'s doc dump — with
two exceptions: the `404` is `text/plain` (§7) and the `401` is the WebServer's bare auth challenge.
Handlers accept both `GET` and `POST`; arguments are query-string or form fields interchangeably.

| Endpoint | Auth | What it does |
|---|---|---|
| `/status` | none | Controller status snapshot — armed, switches, uptime, WiFi (§5) |
| `/info` | none | WiFi-level view: connected, station SSID/IP, whether the AP is up, AP SSID/IP |
| `/documentation` | none | Lists the endpoints registered in the running image, with their args |
| `/network?ssid=&passwd=` | **Basic** | Join a network and store it. Blocks up to the 8s connect timeout |
| `/known` | **Basic** | Lists stored SSIDs (authenticated because it discloses them) |
| `/scan` | **Basic** | Scans for nearby networks. Blocks for seconds |
| `/appass?pass=` | **Basic** | Set the AP/API password, ≥8 and ≤23 chars. Applies **next boot** |
| `/update` (POST) | **Basic, user `ota`** | Firmware upload. Present only in the `*_ota` build envs, and behind the ignition guards in [OTA.md](OTA.md) |

`/status` and `/appass` are this project's; the rest come from WiFiBase and are shared with
HMTL_Module.

Auth is HTTP Basic, username **`admin`**, password as in §3 — `curl -u admin:<password>`. With no
password configured at all the authenticated endpoints answer `403
{"error":"no auth password configured"}` rather than running unauthenticated; on this build a
password always exists (the derived default), so that state means something went wrong in setup.

`/appass` deliberately does not yank the live AP out from under the client mid-request:

```bash
curl -s -u admin:fire-9c41e0d7 'http://192.168.4.1/appass?pass=newsecret1'
# {"stored":true,"applies":"next boot"}
```

Reboot, then both the AP association and HTTP auth require the new value. A `400` means the length
check failed; a `500 {"error":"NVS write failed"}` means the write did not land and the **old
password is still in force** — do not reboot assuming the new one works.

### Blocking behaviour worth knowing

`/network` and `/scan` block for seconds *inside the request*, and the server is single-threaded:
while one is in flight, other API requests wait. This costs nothing on the flame side (it is core
0), but do not script `/scan` in a status poller.

## 5. `/status` response

```json
{
  "armed": false,
  "switches": [false, false, false, false],
  "switches_raw": [false, false, false, false],
  "switches_read_ok": true,
  "uptime_ms": 412530,
  "wifi": {"connected": true, "ssid": "MyNetwork", "ip": "10.0.0.57", "rssi": -58}
}
```

| Field | Meaning |
|---|---|
| `armed` | The same predicate `handle_sensors()` gates ignition on: pilot **and** enable both closed |
| `switches[0]` | Igniter |
| `switches[1]` | Pilot |
| `switches[2]` | Enable |
| `switches[3]` | Program mode (`PROGRAM_MODE_SWITCH` — this build's `CONTROL_SINGLE_QUINT` mode replaces the lights switch with it) |
| `switches_raw[]` | The same four switches **before** the arming interlock — the physical reading. Differs from `switches` for a switch closed since boot |
| `switches_read_ok` | The switch bank was actually read. `false` means the values above are not evidence of anything |
| `uptime_ms` | `millis()` at the last publish — increments per `loop()`, so a frozen value means `loop()` stopped |
| `wifi.*` | Read live on the server task, not from the snapshot |

The `switches` values are the **interlock-qualified** states, not raw pin levels: a switch that has
been closed since power-on reads `false` until it has been seen open for a continuous second
(`SWITCH_OPEN_LATCH_MS`). That is intentional — see WIRING.md §7 — so a switch left on across a
reboot shows `false` here until it is cycled, and that is correct, not a reporting bug.

`switches_raw` exists because that interlock points the wrong way for anything asking *"is this
switch physically active?"* — a stuck-closed switch reads `false` in `switches`. The OTA guard
reads raw for exactly this reason (see [OTA.md](OTA.md)), and it is reported here so an operator
can see what would block an upload without attempting one.

`switches_read_ok` is the difference between *"nothing is active"* and *"we could not tell"*.
The ignition path resolves an unreadable switch bank to all-open-and-do-not-arm, which is right
for arming and is a **permit-on-fault** for anything asking whether it is safe to act. Read this
field before believing the two arrays above.

`armed`, `switches` and `uptime_ms` come from a snapshot `loop()` publishes on core 1 under a
spinlock; a response is always one self-consistent set of values, never fields sampled mid-update.
The snapshot is one `loop()` iteration old at worst.

## 6. Serial output

`fc_api_setup()` prints one AP line at boot, at DEBUG1 so production images show it. The name is
always there; the password only when it is the derived default:

```
API: AP ssid=FIRE-CONTROL-1A2B default pass=fire-9c41e0d7   # nothing configured
API: AP ssid=FIRE-CONTROL-WICKERMAN pass=<configured>       # FC_WIFI_AP_PASS or /appass
```

`API: AP pass too short; using the derived default` means a stored (NVS) password failed the WPA2
8-char floor and the derived default is in force instead.

The API task then prints a WiFi line every 10s at DEBUG3, which `ESP32_TOUCH_FLAGS` enables for this
file specifically (`-DDEBUG_LEVEL_API=3`) so production images print it even though they build at
`DEBUG_LEVEL=2`:

```
API: wifi connected:1 ssid:MyNetwork ip:10.0.0.57 rssi:-58
```

`API: wifi startup failed, retrying` every 30s means no known network **and** the AP did not come
up. On this build that should be unreachable — any too-short password is replaced by the derived
default before the AP is configured (and an out-of-range build flag never links at all), and the AP
bring-up itself always reports success — so treat this line as a firmware bug, not a configuration
problem.

## 7. Troubleshooting

| Symptom | Likely cause |
|---|---|
| `403 {"error":"no auth password configured"}` | Should be unreachable: the password is set before bring-up, and a failed bring-up leaves no server to answer at all. Firmware bug — report it |
| `401` / browser auth prompt | Wrong password. Username is `admin`; the password is the **AP** password |
| Endpoint answers `404 Endpoint /x not defined` | Not in this image — check `/documentation` |
| `/status` reachable but `armed` never true | Expected until each switch has been seen open ≥1s since boot (§5) |
| No `/status`, AP not visible, serial silent about WiFi | Non-ESP32 build — the AVR envs compile the API away entirely |
| AP visible but joining fails | Wrong password. On a default-built image it is the `default pass=` value on the boot line; on a flag-built one it is `FC_WIFI_AP_PASS`, and a `/appass` call outranks both |
| AP name is not `FIRE-CONTROL-XXXX` | The image sets `FC_WIFI_AP_SSID` — check the build's flags, and the `API: AP ssid=` boot line |
| Build fails on `FC_WIFI_AP_SSID`/`FC_WIFI_AP_PASS` `static_assert` | The flag value is out of range (§3), or is missing its inner quotes so it is not a string literal |

## 8. What is deliberately absent

- No arm, fire, ignite, poofer-address or program endpoint, and none should be added — see
  WIRING.md §7's scope warning. Ignition writes stay on the physical switches and RS485.
- No OTA endpoint in the **default** envs. It is compiled in only by the `*_ota` envs, has its
  own mandatory password separate from the AP/API one, and sits behind ignition-specific guards —
  see [OTA.md](OTA.md). The serial envs stay OTA-free on purpose: serial is the recovery path.
- No espota / `ArduinoOTA`, deliberately — one transport, one set of guards ([OTA.md](OTA.md)).
- No TLS. Treat the API as bench/LAN-only and assume anyone on the network can read status.

# Apple Device Battery Support

Research for Impuls 1.4.6 — Apple Device Battery Center. Written 11 August 2026,
before any 1.4.6 implementation exists.

## Scope of this document

This matrix describes **what Impuls, a Developer-ID macOS application, can obtain
from a Mac** using supported public APIs, plus a small, isolated best-effort
layer over public IOKit. It is deliberately not a claim about the Apple
ecosystem as a whole: a verdict of `Unavailable` here means *no supported
Mac-side interface was found for Impuls*, not that no API exists anywhere on any
Apple platform.

Two product decisions bound the research:

- **No companion applications.** Impuls 1.4.6 ships for the Mac only. A device
  is supported when the Mac can read it without installing anything on that
  device.
- **No private Apple frameworks in production.** A private framework found
  during research may be documented here; it may not be built on.

## Categories

| Category | Meaning |
| --- | --- |
| `Public API` | Documented Apple API, stable contract, no undocumented key. |
| `Best effort` | Public API surface, undocumented property or layout. Every field optional, absence is normal, no lifecycle depends on it. |
| `Experimental` | Works against an undocumented Apple protocol implemented by Impuls itself. Isolated in one provider, behind a flag, marked Beta in the UI. |
| `Unavailable for Impuls on macOS` | No supported Mac-side interface found. |
| `Not applicable` | The device has no battery. |

`Requires companion` is not used as a working category: the owner's decision is
that no companion application is developed, so nothing may depend on one.

## Method

Sources were consulted in this order: Apple Developer Documentation and Apple
headers on this machine, then the upstream repositories of the protocols
involved, then current open-source macOS projects, and only then articles and
forum threads. Where a claim rests on observation rather than documentation, it
says so.

Live inspection was done on the development Mac (Apple Silicon, macOS 15+) with
`ioreg` and `system_profiler`. **What that inspection could and could not show is
recorded honestly below** — at the time of writing no Bluetooth accessory was
connected to this Mac, so no accessory battery property could be observed
first-hand. Those rows are marked unverified and are the first entries in
`QA_APPLE_DEVICES_1.4.6.md`.

---

## Mac — this computer

Already implemented in 1.4.x and unchanged by 1.4.6. It is listed because the
matrix must show that the Mac's own numbers do not all come from one place.

| Data point | Verdict | How |
| --- | --- | --- |
| Discovery, device kind | `Public API` | `IOPSCopyPowerSourcesList` / `IOPSGetPowerSourceDescription`; a portable Mac is the one with an internal battery power source |
| Charge percentage | `Public API` | `kIOPSCurrentCapacityKey` / `kIOPSMaxCapacityKey` |
| Power source, charging state | `Public API` | `IOPSGetProvidingPowerSourceType`, `kIOPSIsChargingKey`, `kIOPSIsChargedKey`, `kIOPSIsFinishingChargeKey` |
| Time to empty / to full | `Public API` | `kIOPSTimeToEmptyKey`, `kIOPSTimeToFullChargeKey` |
| Battery condition | `Public API` | `kIOPSBatteryHealthKey`, `kIOPSBatteryHealthConditionKey` |
| Adapter wattage | `Public API` | `IOPSCopyExternalPowerAdapterDetails` |
| Change notifications | `Public API` | `IOPSNotificationCreateRunLoopSource` |
| Cycle count | `Best effort` | `AppleSmartBattery` IORegistry entry, `CycleCount` |
| Voltage, amperage, temperature, capacity pair | `Best effort` | same entry, used only to supplement values missing from `IOPowerSources` |
| Physical connector (MagSafe vs USB-C) | `Unavailable for Impuls on macOS` | no stable public property; `ChargeConnectionDetector` deliberately reports only "external power" |

The split matters: `IOKitPowerSourceProvider` is the documented path and
`IOBatteryRegistrySupplement` is the cautious best-effort one, and 1.4.6 must
keep them apart rather than describing the whole module as public API.

---

## Magic Mouse, Magic Keyboard, Magic Trackpad

| Data point | Verdict | Notes |
| --- | --- | --- |
| Discovery | `Best effort` | `IOServiceMatching("AppleDeviceManagementHIDEventService")` over public IOKit |
| Product / model name | `Best effort` | `Product` property on the same service |
| Battery percentage | `Best effort` | `BatteryPercent` property, read with `IORegistryEntryCreateCFProperty` |
| Charging state | `Unavailable for Impuls on macOS` | no property found that reliably distinguishes charging from idle; a cabled Magic accessory must not be reported as charging by inference |
| Multiple components | `Not applicable` | single battery |
| Permission | none required | IORegistry read, no TCC prompt, no entitlement, no Bluetooth authorization |
| Change notifications | to be determined in phase 03 | IOKit service-matching / termination notifications are public; per-property change notification is not assumed |

`BatteryPercent` is readable through a public IOKit API, but the property name
itself is not a documented compatibility promise. It gets the same treatment
`CycleCount` already gets in `IOBatteryRegistrySupplement`: optional, defensively
parsed, absence is a normal state, and nothing in the module's lifecycle depends
on it existing.

Verified on this Mac: the service class `AppleDeviceManagementHIDEventService`
exists (4 instances). **Not verified:** no instance carried `BatteryPercent`,
because no Bluetooth accessory was connected during the inspection.

Implemented in 1.4.6 by `IORegistryAccessoryProvider` (phase 03). What the
implementation commits to, and what it refuses to do:

- an accessory is listed only when it is **Apple by vendor identifier**
  (`VendorID == 0x05AC`), falling back to a `Manufacturer` string only where no
  numeric identifier exists. The word "Apple" in a product name proves nothing
  and is never used as evidence;
- an accessory is listed only when it has a **stable hardware identifier**
  (`DeviceAddress` or `SerialNumber`) to derive its identity from. The registry
  entry ID is not used: it is reassigned on every reconnect, so it cannot
  recognise a returning device or carry a preference, and it is not a user
  identifier;
- an accessory is listed only when it has a **usable reading**. A node with no
  battery value produces no device;
- **charging state is not reported at all** for accessories. No property was
  found that reliably distinguishes charging from idle, and a cabled Magic
  Keyboard is not evidence;
- every property is optional and defensively typed. A value of the wrong type,
  an out-of-range percentage, a boolean where a number was expected, or a
  numeric width the driver changed all read as *absent*;
- built-in keyboards and trackpads are excluded by transport, in addition to
  being excluded already by having no battery property;
- the provider is **event-driven for arrival and departure** (IOKit matching and
  termination notifications, plus a single read after the Mac wakes) and polled
  for the level itself — 10 s while the panel is open, 10 min while it is closed
  — because the registry does not notify on a level or AirPods topology change.

---

## AirPods, AirPods Pro, AirPods Max

| Data point | Verdict | Notes |
| --- | --- | --- |
| Discovery | `Best effort` | same IORegistry path, only while connected |
| Product / model name | `Best effort` | `Product` property |
| Overall battery | `Best effort` | `BatteryPercent`, when the system publishes it |
| Left / Right / Case battery | `Best effort`, availability dependent | shown only if the system publishes per-component values; public macOS data can retain a last-known component after it is returned to the case |
| Charging state | only if reliably provided | otherwise omitted, never inferred |
| Component freshness | macOS report time only | there is no physical-presence timestamp; Impuls labels when macOS reported the value and never claims that is when the component was measured |

Rejected alternatives, and why:

- **CoreBluetooth / GATT Battery Service `0x180F`.** CoreBluetooth is a
  Bluetooth Low Energy API. AirPods connect as Classic Bluetooth audio devices,
  so they are not enumerable this way, and using CoreBluetooth would trigger a
  Bluetooth permission prompt for data it cannot deliver. A real
  `CoreBluetoothAccessoryProvider` can be added later if some accessory needs
  it; it is not how AirPods are read.
- **`/usr/sbin/system_profiler SPBluetoothDataType`.** This does report
  per-component AirPods levels, and it is not a private API. It is rejected by
  owner decision: the Power module has no subprocess, no helper and no shell
  command today, `SECURITY.md` says so, and per-component AirPods values are not
  worth becoming the first module to break that.
- **Parsing Bluetooth proximity-pairing advertisement packets.** Undocumented
  wire format, needs Bluetooth permission, and is what other projects use to get
  these numbers. Not production-safe for Impuls.

### Measured on hardware, 11 August 2026 — this path does not work for AirPods

AirPods Pro connected and in use, macOS showing "Right Battery Level: 93 %" in
its own Bluetooth section. What the registry contained at that moment:

- `ioreg -r -k BatteryPercent -l` — **no nodes at all**;
- a search of the entire registry for any key containing `Percent` — nothing
  battery-related;
- `AppleDeviceManagementHIDEventService` — **one** node, the Mac's own internal
  trackpad, carrying no battery property of any kind;
- the string "AirPods" — **absent from the registry entirely**;
- `IOBluetoothDevice` — present, with address and connection-handle properties
  and no battery;
- the historical `DeviceCache` in `com.apple.Bluetooth.plist`, where these
  values used to live — **gone**; both the system and per-user files exist and
  contain no device cache.

Impuls's own provider, run against the live registry, reported: one matching
service node, zero devices publishing a battery. That is the correct behaviour
— it invents nothing — but it means **the implemented path returns nothing for
AirPods on this macOS**.

The value the user sees comes from `bluetoothd`. The only non-private route to
it is `system_profiler SPBluetoothDataType`, which was originally excluded
because the Power module has no subprocess. Given the measurement above, that
exclusion was revisited deliberately and narrowed rather than dropped:
`system_profiler` is now allowed **only** as the accessory fallback, only where
the registry produced nothing.

### The `system_profiler` fallback — hardware validated

| Data point | Verdict | Notes |
| --- | --- | --- |
| Discovery | `Best effort`, hardware validated | connected devices only; a disconnected accessory has no value here and is not listed |
| Product name | `Best effort`, hardware validated | the device's own Bluetooth name |
| Battery percentage | `Best effort`, hardware validated | measured against macOS: both reported 87 % for the same AirPods Pro at the same moment |
| Left / Right / Case | `Best effort`, availability dependent | the keys exist (`device_batteryLevelLeft` / `Right` / `Case`), but they are not presence flags and may retain a last-known component |
| Charging state | `Unavailable` | nothing in this output says an accessory is charging |

How the process is run, since this is the first subprocess in Impuls: a fixed
absolute path (`/usr/sbin/system_profiler`), a fixed argument list, no shell at
any point, an empty environment, bounded stdout and stderr, a five-second
deadline with termination, and no output of any kind in production logs.
Malformed or oversized output is an ordinary provider failure.

Cost, measured on this Mac: **0.08–0.12 s** wall clock and about **2 KB** of
JSON. The source has no independent cache: a manual refresh and opening the
panel each request a real read, while the provider coalesces concurrent requests.
The scheduler polls every 10 s while the panel is open and every 10 min while it
is closed.

### Measured component latency, 12 August 2026

With AirPods Pro connected, a one-second sampler initially saw no battery object
for 30 seconds. A later fresh read reported left 100 %, right 100 % and case
28 %. After the right bud was returned to the case, another 30-second sampler
continued to receive all three values. macOS Bluetooth Settings showed the same
100 / 100 / 28 result, and the JSON exposed no separate property that identifies
whether an individual bud is physically present.

Therefore Impuls can remove a component as soon as macOS removes its key, but it
cannot infer presence from an unchanged value, charging level or elapsed time.
For this source, `lastUpdated` records when Impuls observed the macOS report; the
UI deliberately says "Reported by macOS" rather than claiming a fresh physical
measurement. Expected application latency is one real read on manual refresh or
panel open, then at most the 10-second active cadence **after macOS changes its
own report**. The upstream delay itself is unbounded and was already longer than
30 seconds in this measurement.

The JSON form is used rather than the text form because its keys are stable
identifiers; the text output is localised and would tie the parser to the
language the Mac is set to. **The schema remains compatibility-sensitive**: it
is not a documented interface, and every field is optional in the parser.

Magic Mouse, Magic Keyboard and Magic Trackpad remain untested: none was paired
to this Mac. The finding above does not disprove that path for them — HID
accessories are a different service family from audio devices — but it does
remove the assumption that it works, and QA rows 3.1–3.3 are now the only
evidence that would settle it.

Unverified on this Mac: no AirPods were connected during the original phase 01 inspection.
`system_profiler SPBluetoothDataType` listed one paired but not connected device
with a `Case Version` field, which is consistent with AirPods being paired; no
battery value was observable in that state.

What phase 03 implemented, given that: the provider reads
`BatteryPercentLeft`, `BatteryPercentRight` and `BatteryPercentCase` **if the
system publishes them**, and falls back to the single `BatteryPercent` value
when it does not. The two are never mixed — where per-component values exist the
overall one is a summary of them, and adding it as a fourth battery would show
the same charge twice.

Whether those three keys are published on current macOS **has not been
confirmed on hardware**. The code handles both outcomes without a change, and
row 4.1 of the QA matrix is the check that decides which one is real. Nothing in
the interface promises components that did not arrive.

---

## iPhone and iPad

| Data point | Verdict | Notes |
| --- | --- | --- |
| Public Apple Mac-side API | none found | no supported public API exposes a paired iPhone or iPad battery to a Mac application |
| Discovery | `Experimental` | Impuls's own client for the system `usbmuxd` socket at `/var/run/usbmuxd` |
| Device name and model | `Experimental` | `lockdownd` device values, read-only, minimum fields |
| Battery percentage | `Experimental` | authenticated `lockdownd` `GetValue`, domain `com.apple.mobile.battery`, key `BatteryCurrentCapacity` |
| Charging state | `Experimental` | same domain: `BatteryIsCharging` and `ExternalConnected` |
| Transport | USB preferred, Network fallback | both are descriptors and routes supplied by the system usbmuxd daemon; Impuls talks only to its local UNIX socket |
| Trust | existing pairing only | Impuls does not pair, does not write pairing records, and explains the "Trust This Computer" step instead of showing an error |

Decisions behind this row:

- `MobileDevice.framework` is Apple-private. It is the path other Mac apps use
  for this data. It is documented here and not used.
- The protocol Impuls will speak is Apple's own undocumented device protocol.
  Implementing it ourselves keeps the licence clean and the dependency count at
  zero; it does **not** turn an undocumented protocol into a public API. It is
  therefore isolated in one provider so that an Apple-side change breaks the
  iPhone row and nothing else — not the Mac battery, not the accessories, not
  the panel.
- iOS 17 moved *developer* services (debugserver, instruments, XCUITest) behind
  a RemoteXPC/QUIC tunnel. The battery value used here is instead a lockdown
  `GetValue` domain reached over usbmuxd. Hardware proved that path on current
  iOS after an authenticated TLS session; no developer tunnel is involved.
- Read-only and least privilege at the protocol level: only what the Battery
  Center needs. No installs, no profiles, no settings changes, no backups, no
  user data, no serial number, no IMEI, no Apple ID, no installed-app list.
  Any identifier needed to hold a connection or deduplicate a device stays out
  of the UI, the logs, feedback and backups.

The research began without attached hardware. It is now verified on one iPhone
and one iOS version over both USB and macOS Wi-Fi sync. The provider remains
disabled by default and marked Beta; iPad remains untested.

### The protocol sequence, as implemented

Phase 04 implemented the client. This is the exact sequence, and what is known
about each step today:

| # | Step | Status | Evidence |
| --- | --- | --- | --- |
| 1 | Connect to the UNIX socket `/var/run/usbmuxd` | **Proven** | No root or entitlement. Impuls opens no direct LAN socket; when Finder Wi-Fi sync is enabled, macOS owns discovery and may route this local exchange over the local Wi-Fi network. |
| 2 | `ListDevices` over the usbmux plist framing (16-byte little-endian header, then an XML plist) | **Proven over USB and Network** | With one cable-connected phone the daemon published USB and Network descriptors for the same raw identifier; after cable removal, the Network descriptor remained. |
| 3 | Device selection, accepting only `USB` and `Network` | **Proven** | Unknown connection types and malformed IDs are ignored. Entries sharing the raw identifier are one physical device; USB is tried first and Network is the fallback. |
| 4 | `ReadPairRecord` → is this Mac trusted? | **Proven over USB and Network** | Read-only; Impuls never creates or modifies a pair record. |
| 5 | `Connect(deviceID, port 62078)` → lockdownd | **Proven over USB and Network** | Network used the current transient Network DeviceID from a fresh list, never a hardcoded value. |
| 6 | `QueryType` → confirm lockdownd | **Proven over USB and Network** | Both returned `com.apple.mobile.lockdown`. |
| 7 | Authenticated session, pinned TLS and battery `GetValue` | **Proven over USB and Network** | The same stack returned a battery matching the physical iPhone screen on both routes. |

### Measured on hardware, 11 August 2026 — iPhone on iOS 26.5.2, USB, trusted

The sequence was walked with the shipping client. Redacted trace:

```text
ListDevices                   OK — 1 USB device
ReadPairRecord                OK — record present; contents redacted
Connect lockdownd (62078)     OK
QueryType                     OK — com.apple.mobile.lockdown
GetValue DeviceName           OK — value returned without a session
GetValue ProductType          OK — value returned without a session
GetValue battery              REFUSED — Error = GetProhibited
StartSession                  OK — SessionID returned, EnableSessionSSL = true
```

So the answer to the question phase 04 stopped on: **the battery domain is
refused outside a session, and the device demands a TLS upgrade to have one.**
Not a dead end — `StartSession` succeeded with the pair record this Mac already
has — but a cost.

### The stopping point, and how it was passed

Step 7 is where current iOS refuses, and it was measured rather than assumed.
The session it demands was then implemented, and it works:

```text
PEM decode (PKCS#8)      OK — a pair record carries PRIVATE KEY, not
                              RSA PRIVATE KEY; the envelope is unwrapped
SecCertificate           OK
SecKey                   OK
SecIdentityCreate        OK — in memory, no keychain of any kind
StartSession             OK — EnableSessionSSL = true
TLS configuration        OK — Secure Transport over the existing stream
TLS handshake            OK
Peer validation          OK — anchored on the pair record, else pinned to the
                              device certificate byte for byte
Battery request          OK — 65 %, charging, on iOS 26.5.2
```

Three things about that implementation are worth stating plainly, because each
was a decision rather than a default:

- **the identity is built entirely in memory.** `SecIdentityCreate` takes a
  certificate and a key directly, so the user's login keychain is not touched,
  no temporary keychain file is created, and the pairing private key never
  reaches disk. The earlier assumption that a keychain import was unavoidable
  was wrong. One caveat found by CI rather than by reading: the function is
  declared publicly only in the **macOS 26 SDK**. It has existed in the
  framework since 10.12 and runs on every macOS Impuls supports, but building
  against a 16.x SDK fails to find it, so the project now builds with Xcode 26;
- **Secure Transport is legacy, not private.** Network.framework configures TLS
  when a connection is established and cannot upgrade a stream already carrying
  a protocol, which is exactly what lockdownd requires. Secure Transport is
  public Security-framework API, so it costs nothing in signing or notarization
  — it costs maintenance, and it is confined to one file
  (`LockdownTLSChannel.swift`) that nothing else in Impuls imports;
- **the peer is verified, not waved through.** Trust is evaluated with the pair
  record's own certificates as the only anchors; if that fails — these
  certificates are self-signed and carry no hostname — the peer's leaf must be
  byte-for-byte the device certificate this Mac was given when it paired. There
  is no third branch that accepts an unverified peer.

### Measured on hardware, 12 August 2026 — iPhone over Wi-Fi, USB disconnected

Finder's **Show this iPhone when on Wi-Fi** setting was enabled for the trusted
phone. This is a prerequisite owned by macOS and the user: Impuls cannot enable
or change it. Experiment A established what the system daemon provides:
with the cable attached, `ListDevices` contained separate USB and Network route
entries carrying one raw identifier; after cable removal, the Network entry
remained. Its numeric DeviceID differed from the USB DeviceID, proving again
that DeviceID is a transient route handle and not device identity.

Experiment B then used a freshly listed Network descriptor through the same
`/var/run/usbmuxd` socket:

```text
Physical USB cable       disconnected
ReadPairRecord           available
Connect 62078            OK
QueryType                OK
StartSession + pinned TLS OK
Battery                  100 %, matching the iPhone screen
Charging                 false
ExternalConnected        false
DeviceName / ProductType available
Total                    0.257 s
Open descriptors         3 → 3
Open usbmuxd sessions    0 after the request
```

No Bonjour or direct TCP implementation is needed. Production uses usbmuxd
`Listen` messages for fast topology changes and retains the existing 60-second
active / 15-minute idle cadence for battery reads. A phone exposed over both
routes is grouped by its existing raw identifier, read over USB first, and
falls back to Network if the cable disappears before Connect. The resulting
opaque identity is unchanged; only the presented connection changes between
USB and Wi-Fi.

Impuls itself still talks only to the local system daemon. For a paired iPhone,
macOS may transmit device data over the local Wi-Fi network through its system
device-sync mechanism. There is no LAN scan by Impuls, no direct network socket,
and no internet or cloud service involved.

The production provider was then hardware validated for automatic Wi-Fi
discovery with USB physically absent, a locked-device battery read, USB
preference while USB and Network descriptors coexist, automatic USB → Wi-Fi
fallback, one stable opaque identity, deduplication, and clean FD/socket/task
lifecycle. A MacBook reboot with USB absent also rediscovered the phone and read
its battery automatically.

One Wi-Fi OFF → ON sequence did not restore the Network descriptor: Finder did
not see the phone either, and usbmuxd published no route Impuls could consume.
After the Finder setting was enabled and the iPhone rebooted, macOS restored the
system Wi-Fi transport. This is an observed macOS/Finder limitation, not a
production-provider failure and not a reason to add Bonjour polling or direct
TCP fallback.

### What this still is not

Production support. One phone, one iOS version, one session. The provider stays
behind a flag that is not exposed in Settings, and the capability above is
`Experimental Beta, hardware validated` — which is a different sentence from
"it works".

### The earlier reasoning, kept Historically many lockdown
values were readable immediately after connecting; modern iOS answers most
`GetValue` requests only inside an authenticated session — `StartSession` using
the material in the pair record, followed by a TLS upgrade of the same socket
with the host certificate and private key from that record. The refusal is
visible in the reply as `SessionInactive` or `InvalidHostID`, and the client
classifies both as "session required" rather than as a failure.

Phase 04 deliberately stopped before the session; phase 04.1 implemented it
after a measurement showed the path was open. The original reservations, and
what happened to each:

- ~~the TLS upgrade needs a client identity built from PEM key material inside
  the pair record, and producing a `SecIdentity` without importing the key into
  a keychain is awkward~~ — **wrong**. `SecIdentityCreate` does exactly this,
  in memory, and has been public API since macOS 10.12;
- the API that wraps an existing stream in TLS with a client certificate —
  Secure Transport — has been deprecated since macOS 10.15. **Still true**, and
  now an accepted, quarantined cost;
- both of those would be built against an undocumented protocol, unverifiable
  in CI, and maintained across iOS releases indefinitely;
- it is a large amount of machinery for one number. **Still true**, and the
  hardware test is what justified paying for it.

The provider is wired in, tested against a scripted peer, validated once on
hardware, and still **off** by default: gated behind a flag that is not exposed
in Settings, so no user can turn it on by accident and no socket is opened
without it.

---

## Apple Watch, Vision Pro, Apple Pencil, AirTag, Siri Remote

Each of these is `Unavailable for Impuls on macOS`: **no supported public
Mac-side battery interface was found**. The reason differs per device, and the
scope of each search is stated so a future reader can re-check the right thing.

| Device | Status | Reason, and what was searched |
| --- | --- | --- |
| Apple Watch | Unavailable for Impuls on macOS | The Watch is paired to an iPhone, not to the Mac. Searched: Mac-side Bluetooth and IORegistry surfaces, Continuity-related public APIs. A watchOS application can read its own battery (`WKInterfaceDevice`), but that requires a companion, which is out of scope. |
| Apple Vision Pro | Unavailable for Impuls on macOS | Searched for any Mac-side interface; none found. Mac Virtual Display is a display connection and carries no battery state. |
| Apple Pencil | Unavailable for Impuls on macOS | The Pencil is served by an iPad, not by a Mac. No Mac-side interface found; the iPad shows its level through system UI rather than an API a third party could relay. |
| AirTag | Unavailable for Impuls on macOS | No Mac-side interface found. Find My does not publish a battery percentage to third parties; if any signal were ever available it would be categorical (`Battery OK` / `Low Battery`), which is why the model must be able to carry a categorical status instead of a fabricated percentage. |
| Siri Remote | Unavailable for Impuls on macOS | Paired to an Apple TV. No Mac-side interface found. |

HomePod, Apple TV and desktop Macs are `Not applicable`: no battery. The model
may know such devices exist; the Battery Center does not list a card that can
only say "no data".

---

## Third-party dependency review

### libimobiledevice

Checked upstream on 11 August 2026.

- Licence: the library is **LGPL-2.1**; the bundled command-line tools are
  **GPL-2.0**. The two are not interchangeable, and the tools are unusable for a
  closed-source application regardless of packaging.
- Transitive components for this use: `libplist`, `libusbmuxd`,
  `libimobiledevice-glue`, `libtatsu`, plus a TLS backend (OpenSSL, GnuTLS or
  MbedTLS).
- Upstream's own service status page is stale — it states it covers services
  "until iOS 13.5" — so current-iOS behaviour would have to be established by
  testing regardless of which path is taken.

**Decision: not used in Impuls 1.4.6.** Not because of any single blocking fact,
but because the combination is a poor trade for one battery number:

- a third-party LGPL dependency in a project that currently pins exactly one
  dependency and adds none lightly;
- five additional native libraries plus a TLS backend to build, bundle and keep
  current;
- packaging complexity: universal binaries, install names, embedding, and
  per-dylib signing inside the app bundle;
- signing and relinking considerations that would have to be worked through
  carefully for the Developer ID and notarization path (the exact requirements
  depend on the packaging and signing scheme chosen, and were not established
  here — this document does not claim a particular entitlement is required);
- long-term maintenance and compatibility with future iOS and macOS releases;
- a materially larger attack surface for a feature that is one row in a panel;
- the project's preference for a minimal dependency footprint.

`THIRD_PARTY_NOTICES.md` therefore needs no change for 1.4.6.

### Other candidates

- **`jkcoxson/idevice`** (MIT, Rust) implements the same protocol family
  including diagnostics. The licence is clean, but adding a Rust toolchain to a
  SwiftPM build, to CI, and to the signed bundle is a larger change than writing
  the small read-only client Impuls actually needs. Recorded, not adopted.
- **`devicectl` / Xcode command-line tools** are not redistributable with an
  application and are not a public API. Not usable.

## Private APIs found and deliberately not used

- `MobileDevice.framework` (private) — the direct route to iPhone/iPad
  diagnostics on the Mac, used by other tools in this space.
- Bluetooth proximity-pairing packet parsing — undocumented wire format used by
  some accessory-battery apps.

Both are recorded here so the next reader does not have to rediscover them, and
neither is present in Impuls.

---

## Architecture decision for 1.4.6

This is the brief for phase 02. It follows the shape suggested in the task, with
the provider names corrected to describe the mechanism each one actually uses.

```text
DevicePowerCenter                    @MainActor, ObservableObject
├── LocalMacDeviceProvider           adapter over the existing PowerMonitor
├── IORegistryAccessoryProvider      public IOKit, best-effort properties
└── MobileDeviceBatteryProvider      own usbmux/lockdown client, USB, Beta
```

The accessory provider is deliberately **not** called
`BluetoothAccessoryProvider`: it reads IORegistry and does not open
CoreBluetooth, and a name that promised Bluetooth would misdescribe both the
mechanism and its permission profile. A real `CoreBluetoothAccessoryProvider`
can be added beside it later if some accessory genuinely needs GATT.

Binding constraints for phases 02–05:

1. `.power` stays the module's internal identifier. Settings, backup, migrations
   and module order must not break.
2. `PowerMonitor` is not rewritten. It becomes the source behind
   `LocalMacDeviceProvider`, keeping its ownership rules: disabled module means
   no observation and no timer; `setActive(true)` while the panel is open keeps
   the fast local refresh; IOKit notifications stay the event source.
3. A battery is a **component of a device**, not a field on a snapshot. Devices
   with left/right/case batteries are the normal case, not a special case.
4. Capabilities distinguish percentage, charging state and categorical status,
   so a device that can only report "low" is representable without inventing a
   number.
5. Identity, deduplication and freshness are first-class: canonical identity per
   device, provider priority per field, timestamps compared before merging, and
   fresh data never overwritten by stale data. Two devices are not merged on a
   matching name alone.
6. Every provider is an optional enhancement with failure isolation. A provider
   that throws, times out or is denied permission must not affect the Mac
   battery or any other module.
7. External providers do no work at all when the module is off or the user has
   not enabled Apple devices. External refresh is far more frugal than the local
   Mac's: event-driven where possible, backing off when a device is unreachable,
   and quiet while the panel is closed.
8. The clock is injectable, so staleness is testable without `sleep`.
9. Device identifiers never reach the UI, ordinary logs, feedback diagnostics or
   exported backups.

## Future providers

The model leaves room for additional sources — a real CoreBluetooth provider, or
one day a companion-supplied source — but 1.4.6 builds none of them, and nothing
in the architecture depends on one existing.

## Sources

- Apple: [IOPowerSources](https://developer.apple.com/documentation/iokit/iopowersources_h),
  [UIDevice.batteryLevel](https://developer.apple.com/documentation/uikit/uidevice/batterylevel)
- [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice) — licences, components
- [libimobiledevice service status](https://libimobiledevice.org/status/) — states coverage only to iOS 13.5
- [pymobiledevice3 iOS 17 tunnels guide](https://github.com/doronz88/pymobiledevice3/blob/master/docs/guides/ios17-tunnels.md) — which services moved behind RemoteXPC
- [pymobiledevice3 diagnostics service](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/services/diagnostics.py) — diagnostics_relay battery query shape
- [jkcoxson/idevice](https://github.com/jkcoxson/idevice) — MIT alternative implementation, diagnostics support
- [WhatBattery](https://github.com/darrylmorley/whatbattery) — current macOS project; documents `BatteryPercent`, and its iPhone path via the private `MobileDevice.framework`
- Local inspection of this Mac: `ioreg -r -c AppleDeviceManagementHIDEventService -l`,
  `ioreg -r -k BatteryPercent -l`, `system_profiler SPBluetoothDataType`

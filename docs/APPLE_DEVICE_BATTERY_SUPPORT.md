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
  slowly for the level itself — 60 s while the panel is open, 10 min while it is
  closed — because the registry does not notify on a level change.

---

## AirPods, AirPods Pro, AirPods Max

| Data point | Verdict | Notes |
| --- | --- | --- |
| Discovery | `Best effort` | same IORegistry path, only while connected |
| Product / model name | `Best effort` | `Product` property |
| Overall battery | `Best effort` | `BatteryPercent`, when the system publishes it |
| Left / Right / Case battery | `Best effort`, availability dependent | shown only if the system publishes per-component values on that service; if it does not, Impuls shows the overall value or nothing |
| Charging state | only if reliably provided | otherwise omitted, never inferred |
| Case value freshness | must be marked | a closed case stops updating; the last value is shown with its age or not at all, never as realtime |

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

Unverified on this Mac: no AirPods were connected during inspection.
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
| Battery percentage | `Experimental` | `com.apple.mobile.diagnostics_relay`, IORegistry query of the device's `AppleSmartBattery` entry |
| Charging state | `Experimental` | same response (`ExternalConnected` / `IsCharging` / `FullyCharged` keys) |
| Transport | USB first | Wi-Fi sync is a later, separate step and is not a blocker for 1.4.6 |
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
  a RemoteXPC/QUIC tunnel. Lockdown services over usbmux were not removed, and
  `diagnostics_relay` is a lockdown service. Whether it answers a battery query
  on current iOS without a tunnel is the single question phase 04 must answer on
  real hardware before anything ships enabled.
- Read-only and least privilege at the protocol level: only what the Battery
  Center needs. No installs, no profiles, no settings changes, no backups, no
  user data, no serial number, no IMEI, no Apple ID, no installed-app list.
  Any identifier needed to hold a connection or deduplicate a device stays out
  of the UI, the logs, feedback and backups.

Nothing here is verified: there was no USB-connected iPhone or iPad during this
research. The provider ships disabled, marked Beta, only if phase 04 proves it
on hardware; otherwise 1.4.6 ships without it and this document records why.

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

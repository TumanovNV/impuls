# Impuls 1.4.6 — Development Handoff

Written for an agent or developer with no access to the conversation that
produced this work. Read this, then `APPLE_DEVICE_BATTERY_SUPPORT.md`, then
`QA_APPLE_DEVICES_1.4.6.md`.

## Current state

| | |
| --- | --- |
| Checkpoint | 12 August 2026 |
| Branch | `agent/apple-device-center-1.4.6` |
| Base branch | `release/1.4.5` (**not** `main`) |
| Phase 04.1 implementation HEAD | `8159b5b` |
| Phase 05 working tree base | `f4cffc9` |
| `main` | `5672689` — Impuls 1.4.4 |
| `release/1.4.5` | `efb3742` — 1.4.5, still unmerged into `main` |
| `Scripts/version` | `VERSION=1.4.5` — **not yet bumped**; 1.4.6 is not a release |
| Tests | 254, 0 failures (`swift test -c release`) |

1.4.6 is unreleased. Phase 05 (UI, Settings, localization, accessibility) is
implemented in the working tree and has passed automated review, but the visual,
VoiceOver and remaining hardware QA below are still open. Do not merge PR #33
until those checks are complete. The external-device path remains opt-in; with it
off, the Mac battery and desktop Power layouts stay on the unchanged 1.4.5 path.

### The 1.4.5 backup branch

`backup/1.4.5-local-handoff` exists because three files — `docs/DESIGN_AUDIT_2026.md`,
`docs/audits/macos-floor-1.5.0.md` and `impuls-1.4.5-design.patch` — were only
ever in a local working tree and then a local git stash. They are not on
`release/1.4.5`. That branch is their only copy on the remote. **Do not merge it
into 1.4.6**; it belongs to whoever finishes 1.4.5.

## Completed phases

### Phase 01 — research and capability matrix — `cd1abea`

Established what a Developer-ID Mac application can actually read, per data
point rather than per device, and wrote `docs/APPLE_DEVICE_BATTERY_SUPPORT.md`
and `docs/QA_APPLE_DEVICES_1.4.6.md`. Decided against libimobiledevice (LGPL
library plus five native dependencies, packaging, signing, maintenance, attack
surface) and against `MobileDevice.framework` (private).

### Phase 02 — domain model and coordinator — `48ff2d4`, `c29b8a1`, `6e5358b`

Hardware-neutral device model where a battery is a *component* of a device;
`AppleDeviceNormalizer` as the only place a number becomes a percentage;
identity that never carries a raw hardware identifier; `DeviceSnapshotMerger`
for dedup, source priority and freshness; `DevicePowerCenter` owning providers
behind two switches; `DeviceRefreshScheduler` owning cadence so providers do
not; `LocalMacDeviceProvider` adapting the untouched `PowerMonitor`.

### Phase 03 — Apple accessories over IORegistry — `6bde0a9`

`AppleDeviceManagementHIDEventService` + `BatteryPercent`, with four rules that
can only *remove* a device: Apple by vendor identifier, a stable hardware
identifier, a usable reading, and a transport that is not the Mac's own.
Charging state is never claimed for accessories.

### Phase 04 — USB mobile-device transport — `b70ba0a`, `5fe3bb6`

Own Swift client for the system `usbmuxd` socket: framing, bounded frames,
timeouts, cancellation, and the full `ListDevices → ReadPairRecord → Connect →
QueryType → GetValue` sequence. Read-only and least-privilege at the protocol
level. `5fe3bb6` added the hardware probes that measured what follows.

### Phase 04.1 — AirPods fallback and the iPhone TLS session — `8159b5b`

Two hardware findings turned into implementations: `system_profiler` as the
accessory fallback where the registry is silent, and the authenticated TLS
session the battery domain requires.

### Phase 05 — UI, Settings, localization and accessibility

The Power pane now keeps the original This Mac layout when external devices are
off and adds an opt-in device switcher and detail card when they are on. The card
renders only components that actually arrived, gives every component its own
timestamp and freshness state, and marks iPhone/iPad as Beta only when the hidden
mobile-device flag is enabled.

Settings now owns the external-device opt-in, discovery and manual refresh,
per-device visibility and ordering, and forgetting devices that are disconnected
or hidden. Those presentation preferences use only keyed opaque identities, are
local to this Mac and are excluded from settings backup snapshots. Permission and
trust states are user-facing sentences, not transport errors. English and Russian
tables are complete, controls keep keyboard focus, and accessibility values contain
device names, real readings and states but never device identifiers.

## Hardware validation already performed

One Mac, one iPhone, one pair of AirPods, on 11 August 2026. Everything below
was observed; nothing below is inferred.

### AirPods Pro

- macOS displayed the battery in its own Bluetooth section while the IORegistry
  published **nothing**: no `BatteryPercent` node, no key containing `Percent`
  that relates to a battery, and no mention of "AirPods" anywhere in the
  registry. The historical `DeviceCache` in `com.apple.Bluetooth.plist` is gone;
- `system_profiler SPBluetoothDataType -json` returned a real value;
- three consecutive readings matched macOS exactly as the charge fell:
  **89 → 88 → 87**;
- runtime **0.08–0.12 s**, output about **2 KB**;
- only components the system actually published were shown — one bud was in the
  case, so exactly one component existed and exactly one was displayed;
- provider status: **Best effort, hardware validated**.

Only this model was tested. Nothing here says AirPods Max or the original
AirPods behave the same way.

### iPhone, iOS 26.5.2, over USB

```text
ListDevices                   OK
ReadPairRecord                OK (this Mac already trusted)
Connect lockdownd (62078)     OK
QueryType                     OK — com.apple.mobile.lockdown
GetValue battery, no session  REFUSED — Error = GetProhibited
StartSession                  OK — EnableSessionSSL = true
PKCS#8 private key            unwrapped (a pair record carries PRIVATE KEY,
                              not RSA PRIVATE KEY)
SecIdentityCreate             OK — entirely in memory, no keychain of any kind
TLS handshake                 OK (Secure Transport over the existing stream)
Peer validation               OK — anchored on the pair record, else pinned to
                              the device certificate byte for byte
Battery read                  OK — 65 %, later 69 % while charging
Charging state                OK — charging = true, external = true
Five consecutive reads        65 % each, 0.02 s each, open descriptors 3 → 3
```

Provider status: **Beta candidate, hardware validated**. One device, one iOS
version. Not production support.

No UDID, HostID, SystemBUID, certificate, private key or serial number appears
in this document, in any log, in any error, or in any exported file — that is
tested, not just intended.

## Hardware QA still required

Unit tests and fixtures prove parsing and lifecycle. They prove nothing about
hardware. These remain open, and `docs/QA_APPLE_DEVICES_1.4.6.md` is the list of
record:

- iPhone disconnect and reconnect;
- iPhone locked, then unlocked;
- cable pulled during a request;
- comparing the percentage against the iPhone's own screen;
- iPad over USB;
- Magic Mouse, Magic Keyboard, Magic Trackpad — the IORegistry path has **never**
  been exercised against real hardware;
- other AirPods models;
- sleep and wake with external devices connected;
- several external devices at once.

## Decisions already made

Do not relitigate these without a reason.

**Mac.** `PowerMonitor`, `PowerSnapshot`, `IOKitPowerSourceProvider` and
`IOBatteryRegistrySupplement` are unchanged and stay that way.
`LocalMacDeviceProvider` adapts them. A desktop Mac is a device with no battery,
not the absence of a device.

**AirPods.** The IORegistry path proved unusable on the tested system. The
fallback is `/usr/sbin/system_profiler` through `Process` directly: fixed
absolute path, fixed arguments, JSON output, empty environment, bounded stdout
and stderr, a deadline that terminates the child, no raw output in logs, and the
parser separated from the process runner. Best effort, never authoritative.

**Magic accessories.** The IORegistry path stays. Untested on hardware.

**iPhone/iPad.** Impuls's own Swift implementation of
`usbmuxd → lockdownd → StartSession → TLS → GetValue`. Not
`MobileDevice.framework`, not libimobiledevice, no shell, no helper process.

**TLS.** Secure Transport is used only inside `LockdownTLSChannel.swift`,
because the protocol needs a TLS upgrade of a stream that already carries
lockdown traffic and Network.framework cannot do that. It is legacy but public
API. Do not let Secure Transport details rise above the transport layer.

**Identity and privacy.** Raw identifiers never leave the resolver and transport
boundary. This Mac is `.localMac` with no derivation at all. External devices
get an HMAC keyed with random bytes kept in this Mac's Keychain.
`AppleDeviceIdentity` is not `Codable`, redacts itself when printed, and appears
in no backup and no feedback report.

## Feature flags and settings

| | |
| --- | --- |
| `MobileDeviceBatteryProvider.isEnabled` | environment `IMPULS_MOBILE_DEVICE_BATTERY=1`, or `UserDefaults` key `experimentalMobileDeviceBattery` |
| Default | **off**, and not exposed in Settings |
| Why | validated on one phone and one iOS version; a switch in Settings would be a promise |
| `SettingsStore.showsExternalAppleDevices` | persisted, defaults to `false`, `decodeIfPresent` so 1.4.5 settings and backups migrate |
| External-device UI | opt-in, discovery, manual refresh, per-device visibility/order and forget are exposed in the Apple Devices settings tab |
| Local-only presentation state | keyed identity order and hidden state; never included in `ImpulsSettingsSnapshot` or backups |

With the flag off, the release bundle opens no socket to `usbmuxd` at all, and
the launch smoke test still shows zero network sockets.

## Test state

254 tests, 0 failures. Groups:

| Group | What it covers |
| --- | --- |
| Domain and normalization | 0/1/100/nil/−1/101/255/NaN/Infinity, components, categorical status, capabilities |
| Identity | `.localMac`, keyed derivation, stability, redaction |
| Dedup and merge | one iPhone over two transports, source priority, stale versus fresh, identical names not merged |
| Scheduler | event-driven never polled, cadence, exponential back-off with a ceiling |
| Lifecycle | module and external switches, late updates after stop, failure isolation, last good snapshot |
| IORegistry fixtures | numeric widths, wrong types, `Int.max`, missing keys, future keys, non-Apple vendor, built-in transport |
| `system_profiler` fixtures | current output shape, all three components, missing battery, malformed object, unknown fields, several devices, duplicates, out-of-range |
| usbmux framing | length below header, four-gigabyte length, zero length, truncated plist, non-dictionary payload |
| lockdown | error vocabulary, refused port, wrong service, session states |
| PEM / PKCS#8 | valid material, malformed, mislabelled, truncated DER, oversized, mismatched key and certificate |
| TLS | no session, `EnableSessionSSL` false and true, bounded handshake, nothing to pin against |
| Privacy | no pairing material or identifier in any error or diagnostic string |
| Process boundary | real child processes: one that never exits, one that floods its pipe, one that fails, one that is missing |
| Presentation | component omission, per-reading age and freshness, Beta labels, identifier-free accessibility values |
| Settings privacy | local visibility/order persistence, backup exclusion, bounded key validation, explicit opt-in before refresh |

**What unit tests do not prove:** that any of it works on hardware. The hardware
probes in the suite skip themselves when nothing is attached, which is what CI
does.

## Toolchain

The device layer needs the **macOS 26 SDK** to compile: the in-memory TLS
identity uses `SecIdentityCreate`, which that SDK declares publicly and the
16.x SDKs do not. The symbol has been in the Security framework since macOS
10.12 — an older SDK simply cannot see it, and the build fails rather than
misbehaving. This was found by CI, not by reasoning, which is why CI now selects
Xcode 26.3 explicitly in both `build.yml` and `release.yml`; the GitHub
`macos-15` image ships it alongside the 16.x default.

`platforms: [.macOS(.v15)]` is unchanged, so what a user needs to *run* Impuls
is exactly what it was. What changed is what a machine needs to *build* it.

## Validation commands

```bash
swift build -c release
swift test -c release
./Scripts/bundle.sh release        # ad-hoc signs unless IMPULS_DEVELOPER_ID_APPLICATION is set
./Scripts/dmg.sh
```

`.github/workflows/build.yml` enforces the project invariants with literal
`grep`s — read it before changing anything it names.

## Support levels, stated honestly

| Level | What is at this level |
| --- | --- |
| Production-supported | This Mac's battery and power, unchanged from 1.4.5 |
| Best effort, hardware validated | AirPods via `system_profiler` |
| Best effort, not hardware tested | Magic Mouse, Keyboard, Trackpad via IORegistry |
| Experimental Beta, hardware validated | iPhone and iPad over USB, behind a flag that is off |
| Unavailable | Apple Watch, Vision Pro, Apple Pencil, AirTag, Siri Remote — no Mac-side path found |
| Not applicable | HomePod, Apple TV, desktop Macs — no battery |

# Remaining before merge

Phase 05 implementation and automated tests are complete. Do not reopen phases
01–04.1 without evidence, and do not merge PR #33 until the following manual
review is recorded in `docs/QA_APPLE_DEVICES_1.4.6.md` where applicable:

- compare the unchanged local Mac and desktop Power layouts against 1.4.5;
- inspect the multi-device layout with long names, missing components and stale
  readings in light and dark appearances;
- verify keyboard focus and VoiceOver for the switcher, cards, refresh, visibility,
  reorder and forget controls, including that no identifier is announced;
- check Increase Contrast, Reduce Motion and Reduce Transparency;
- exercise external opt-in, refresh, permission/trust and disconnect paths with
  available hardware, without marking unobserved hardware scenarios as passed.

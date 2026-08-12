# Impuls 1.4.6 — Code Map

Only the files the device layer touches. Everything else in `Sources/Impuls` is
unchanged by 1.4.6. Paths are relative to `Sources/Impuls/Services` unless
stated otherwise.

## Existing Mac power — unchanged, do not rewrite

```text
PowerMonitor.swift               Module lifecycle: enabled → observing, active → fast timer.
PowerSnapshot.swift              This Mac's snapshot, PowerNormalizer, time formatting.
IOKitPowerSourceProvider.swift   Public IOPowerSources, plus its change notification.
IOBatteryRegistrySupplement.swift Best-effort AppleSmartBattery values IOPowerSources omits.
```

## Device domain

```text
AppleDevice.swift                Kinds, battery components, connection, availability,
                                 data sources with priority, capabilities, freshness,
                                 AppleDeviceSnapshot.
AppleDeviceIdentity.swift        Identity with no raw identifier in it, and the resolver
                                 that is the only place one exists. Not Codable, redacts
                                 itself when printed.
AppleDeviceNormalizer.swift      The only place a number becomes a percentage; component
                                 construction; display names; derived capabilities.
Model/AppleDevicePresentation.swift  Localized symbols, labels, per-reading freshness and
                                     identifier-free accessibility vocabulary for the UI.
DeviceClock.swift                Injectable clock, so staleness is testable without sleep.
```

## Coordination

```text
DevicePowerCenter.swift          Owns providers behind two switches (module, external
                                 devices), merges, publishes, keeps the last good list.
DeviceSnapshotMerger.swift       Pure dedup, per-field source priority, freshness, order.
DeviceRefreshScheduler.swift     Cadence and back-off. Event-driven providers are never
                                 polled — which is how PowerMonitor keeps its own rhythm.
DeviceBatteryProviding.swift     Provider protocol (@MainActor, state) and
                                 DeviceBatterySource (not @MainActor, I/O). The split is
                                 enforced by a test.
DevicePowerLog.swift             Bounded debug logging, off unless IMPULS_DEVICE_LOG=1,
                                 plus the per-provider diagnostic snapshot.
```

## This Mac, as a device

```text
LocalMacDeviceProvider.swift     Adapter over PowerMonitor. A desktop Mac arrives with no
                                 components and a real externalPower — a device without a
                                 battery, not a missing device.
```

## Accessories

```text
AppleAccessoryBatteryProvider.swift  Two sources: the registry first, system_profiler for
                                     what it left empty. IOKit arrival/departure
                                     notifications, one read after wake, 10 s active /
                                     10 min idle polling and one in-flight read at a time.
IORegistryAccessorySource.swift      The registry walk, off the main actor.
IORegistryAccessoryMapper.swift      Property dictionary → device, or nothing. Four rules
                                     that can only remove a device.
SystemProfilerAccessorySource.swift  The only subprocess in Impuls: fixed path, fixed
                                     args, no shell, empty environment, bounded output,
                                     deadline. No internal cache; every requested read runs.
SystemProfilerAccessoryParser.swift  The JSON, and AppleAccessoryNaming shared with the
                                     registry mapper.
```

## iPhone and iPad over USB and macOS Wi-Fi sync — experimental

```text
MobileDeviceTransport.swift       UNIX socket to /var/run/usbmuxd, both framings, bounded
                                  lengths, per-call timeouts, error vocabulary.
MobileDeviceClient.swift          USB/Network descriptors and the sequence: ListDevices →
                                  pair record → Connect → QueryType → StartSession (+TLS)
                                  → GetValue. Unknown transports are ignored.
MobileDeviceBatteryProvider.swift The provider, the flag that keeps it off, and
                                  MobileDeviceBatterySource. Groups USB and Network routes
                                  by raw identifier, prefers USB, falls back to Network, and
                                  maps the chosen route to one opaque-identity snapshot.
MobileDeviceTopologyMonitor.swift A local usbmuxd Listen subscription for Attached/Detached
                                  events, bounded reconnect back-off and synchronous close
                                  on stop. Topology is fast; battery polling stays sparse.
LockdownPairRecord.swift          Pair record parsing, PEM, PKCS#8 unwrapping, a bounded
                                  DER reader, and the in-memory SecIdentity.
LockdownTLSChannel.swift          The only file that knows Secure Transport exists.
                                  Handshake with a deadline, peer pinned to the pairing.
```

## Wiring outside Services

```text
Model/NotchViewModel.swift        Creates DevicePowerCenter beside PowerMonitor; both
                                  follow the .power module switch. Mirrors sanitized
                                  device state into Settings and wires explicit refresh.
Notch/NotchController.swift       setActive on open and close, next to the existing stores.
Settings/SettingsStore.swift      showsExternalAppleDevices, default false, migrating;
                                  local keyed visibility/order state excluded from backup.
Settings/AppleDeviceSettingsPane.swift  Opt-in, discovery, refresh, visibility, ordering,
                                       forget confirmation and plain-language status.
UI/PowerPane.swift                Original local Mac/desktop layout when external devices
                                  are off; device switcher and accessible detail card when on.
```

## Tests

```text
Tests/ImpulsTests/AppleDevicePowerModelTests.swift  Model, normalization, identity, Fixtures.
Tests/ImpulsTests/AppleDevicePresentationTests.swift Presentation, age/freshness, component
                                                     omission and accessibility privacy.
Tests/ImpulsTests/DevicePowerCenterTests.swift      Dedup, freshness, order, lifecycle,
                                                    scheduler, the actor-boundary guard.
Tests/ImpulsTests/IORegistryAccessoryTests.swift    Registry fixtures, provider lifecycle,
                                                    system_profiler fixtures, two hardware
                                                    probes that skip themselves.
Tests/ImpulsTests/LockdownPairRecordTests.swift     PEM, PKCS#8, DER, identity, privacy.
                                                    Certificate and keys are throwaway.
Tests/ImpulsTests/MobileDeviceProtocolTests.swift   Framing, hostile peers, session and TLS
                                                    states, USB/Network parsing, routing,
                                                    topology events and hardware probes.
Tests/ImpulsTests/MobileDeviceBatteryProviderTests.swift  Feature-gate and topology-driven
                                                          provider lifecycle.
Tests/ImpulsTests/PowerMonitorTests.swift           The 1.4.5 suite, untouched.
Tests/ImpulsTests/SettingsStoreTests.swift           External opt-in and local-only device
                                                     presentation preference privacy.
```

Hardware probes are named `testHardwareProbe…`. They call `XCTSkip` when nothing
is attached, so CI and an ordinary machine are unaffected, and they print a
redacted trace when hardware is present.

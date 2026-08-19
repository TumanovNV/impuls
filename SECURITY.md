# Security Policy

## Supported versions

Only the latest published Impuls release receives security fixes.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting / Security Advisories for this
repository. Do not open a public issue for an unpatched vulnerability and do not
include user data, credentials, or exploit payloads in public discussions.

## Security boundaries

- Impuls initiates update checks only through `UpdateService.swift`; the pinned
  Sparkle 2.9.5 framework owns the download and installation transport;
- the update feed is the fixed HTTPS GitHub Releases asset URL and archive links
  are generated only for versioned assets in `TumanovNV/impuls`;
- the appcast is Ed25519-signed, archive verification is mandatory before
  extraction, signed-feed failures never expire, and the private key exists only
  in protected release infrastructure;
- automatic downloads, unattended installation, Sparkle's system profiling,
  and device identifiers are disabled. "System profiling" here means
  the profile Sparkle can attach to an update check; it is unrelated to the
  local `system_profiler` call the Battery Center makes for Apple accessories,
  described below, which never leaves the Mac;
- version statistics are a separate third boundary owned only by
  `VersionTelemetryService.swift`; without `allowed` consent and a validated,
  build-configured HTTPS `/v1/heartbeat` endpoint it cannot construct a request;
- its payload type exposes only schema, a random installation UUID, current app
  version and an optional correctly observed previous version; CI and unit tests
  pin that allow-list, the one-hour attempt throttle and zero requests for
  `unknown` or `denied`;
- the random UUID is stored as a device-only Keychain item and has no hardware
  or user input. The collector HMACs it with an owner secret before SQLite,
  rejects extra/malformed fields and bodies over 2 KiB, rate limits requests,
  and does not log IP or User-Agent as product analytics;
- the private owner dashboard may make one server-originated, unauthenticated
  request to the fixed GitHub latest-release API to label aggregate data. It
  follows no redirect, accepts only a bounded stable release tag, sends no
  telemetry or credentials, and atomically retains the last validated version
  locally when GitHub is unavailable;
- feedback uses no in-app network request: a length-bounded report is copied
  locally and the system browser may open only the exact Impuls new-issue URL;
- feedback diagnostics are allow-listed and never inspect user content, paths,
  logs, device identifiers, or clipboard history;
- no private frameworks or process injection;
- the Battery / Power module reads this Mac through public IOPowerSources plus
  a best-effort supplement from the public IORegistry. No SMC client, no helper,
  no shell, no USB entitlement, no network path; live readings stay in memory;
- Apple accessories — AirPods, Magic Mouse, Keyboard and Trackpad — are read
  from the public IORegistry, and, where the registry publishes nothing, from
  `/usr/sbin/system_profiler`. That process is launched directly by `Process`
  with an absolute path and a fixed argument list: no shell at any point, no
  user input in the arguments, an empty environment, bounded stdout and stderr,
  a deadline that terminates the child, and nothing from either stream in a log.
  Both sources are best effort: a missing value is a missing value;
- the iPhone and iPad provider is experimental, disabled by default and gated
  behind a Beta feature flag that is not exposed in Settings. When enabled it
  speaks Apple's device protocol over the **local** `/var/run/usbmuxd` UNIX
  socket to `lockdownd` on a device the user has already trusted. Impuls does no
  Bonjour discovery, LAN scan or direct TCP connection. The user must enable
  **Show this iPhone when on Wi-Fi** in Finder before macOS can publish the
  Network route; Impuls cannot enable or change that system setting. macOS may
  then route the paired-device exchange over the local Wi-Fi network through
  its system synchronisation mechanism; no internet or cloud service is
  involved. USB is preferred when both system routes exist. Impuls reads the
  existing pair record and never creates or modifies one, installs nothing,
  changes no setting on the device, and requests only a battery percentage,
  charging and external-power flags, a device name and a model identifier;
- the TLS session that protocol requires is built entirely in memory:
  `SecIdentityCreate` from the pair record's certificate and key, with no
  keychain of any kind involved and no key material written to disk. The peer is
  verified against that same pair record — anchored trust, or the device
  certificate matched byte for byte — and there is no path that accepts an
  unverified peer. Secure Transport is confined to one adapter file;
- pairing material is never persisted by Impuls and never reaches the interface,
  logs, feedback reports or backups; raw identifiers — UDID, serial number,
  Bluetooth address — exist only inside the transport and identity boundary,
  and the identity derived from them is not serialisable;
- external device discovery is off until the user turns it on: an update cannot
  produce a new permission prompt or a new connection by itself;
- Apple Music metadata uses its scripting interface plus bounded distributed
  player notifications; the
  Hardened Runtime bundle carries the explicit Apple Events Automation
  entitlement and macOS remains the permission authority;
- web music is created only by the explicit Open Web Player action, uses the
  system WebKit engine, allows main-frame HTTPS navigation only within the
  selected provider and its authentication domains, and hands unrelated links
  to the default browser;
- subframes — captcha, consent and sign-in widgets — are allowed ordinary
  HTTPS; the native receiver independently requires `frameInfo.isMainFrame`,
  so a subframe cannot submit state, artwork or diagnostics to Impuls;
- the page bridge accepts bounded playback metadata only from an HTTPS page of
  the currently selected provider and never inspects passwords, cookies, or
  authentication tokens;
- cover art is handed over by the page as bounded bytes and validated through
  ImageIO; the application itself makes no request for it;
- no embedded GitHub tokens or release credentials;
- release credentials belong only in protected GitHub Actions secrets;
- optional clipboard persistence uses AES-GCM and keeps the device-only archive
  key in macOS Keychain; clipboard persistence remains disabled by default;
- CI rejects Impuls-owned networking APIs outside the update service, the
  explicit WebKit music boundary, and the opt-in version-statistics service;
  it proves the web view is lazily constructed,
  pins the Sparkle version and revision, validates security Info.plist keys,
  verifies the embedded framework, and checks that no MediaRemote/perl helper is
  bundled;
- release CI creates a symlink-preserving ZIP, signs and verifies both the feed
  and archive, then publishes them with checksums only after all tests pass;
- full-resolution image operations reject dimensions above a defined pixel
  budget before decoding, and oversized clipboard payloads are not retained.
- local stores use bounded streaming reads, and meeting links are restricted to
  known HTTPS providers before macOS is asked to open them.
- screenshot and note writes run on bounded serial queues instead of the UI
  thread; media artwork is byte-, dimension-, and display-size bounded.
- generated-file Undo verifies a streaming SHA-256 content digest in addition
  to size, modification date, and filesystem resource identity.

## Known limitations

Public releases are still ad-hoc signed and not notarized. Gatekeeper therefore
cannot authenticate the publisher on first installation. The ad-hoc build uses
the minimum temporary Library Validation exception required to load the
separately signed Sparkle framework; the Developer ID path does not carry that
exception. This is a transition limitation, not a condition to bypass silently.

The Sparkle signing key is the update channel's root of trust until Developer ID
is available. Losing every protected copy would prevent safe updates to existing
1.2.9 installations.

Because public releases are ad-hoc signed, macOS may ask for Automation access
again after an update. A stable Developer ID signature is still the long-term
fix for durable TCC identity across releases.

Web music depends on the provider's current HTML and Media Session behaviour.
A provider can change its controls, authentication flow, playback policy, or
WebKit support without notice. Impuls does not bypass DRM, subscriptions,
regional restrictions, or provider access rules. Where a provider's playback
depends on a DRM module WebKit does not implement — Spotify's web player and
Widevine — the source is not offered rather than shipped as a tab that signs in
but never plays. A provider may also refuse to sign a user in inside an
embedded web view; Impuls surfaces that message instead of hiding it.

The current whole-repository audit starting point is
[`knowledge-base/00-project/pre-audit-baseline-1.4.12.md`](knowledge-base/00-project/pre-audit-baseline-1.4.12.md).
The 1.4.10 version-statistics audit remains historical evidence for that subsystem; it does not override the current 1.4.12 code, tests, CI, privacy or release contracts.
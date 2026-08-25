# Privacy and Local Data Model

The operator's source Russian-language privacy policy is published at
[`/privacy/`](https://tumanovnv.github.io/impuls/privacy/). Localized privacy
notices are also published under the corresponding `/en/privacy/`,
`/de/privacy/`, `/fr/privacy/`, `/es/privacy/`, `/ja/privacy/`, and
`/zh-hans/privacy/` routes. The old `/site-privacy.html` address is a legacy
`noindex` handoff only and is not the canonical policy.

This document is the technical inventory of application data flows and local
storage. It complements, but does not replace, the operator policy. Website and
legal-page generation/routing is documented in
`knowledge-base/07-web/legal-privacy.md`.

Impuls is designed to work locally. It has no advertising, automatic
crash-report upload, remote configuration, account system, or device
fingerprinting. It includes one minimal first-party version statistic, disabled
until the user explicitly enables it. That statistic never contains Impuls
content, account data, or hardware identifiers. Project-support eligibility is
also local-only and is not telemetry.

## Network access

On first launch, Impuls asks whether it may check for updates. Existing update
consent decisions are preserved during migrations. If the user declines, Impuls
performs no update request. The setting can be changed later.

When allowed, Sparkle checks the fixed HTTPS feed at:

`https://github.com/TumanovNV/impuls/releases/latest/download/appcast.xml`

After the user accepts an available update, Sparkle downloads the versioned ZIP
from the same repository's GitHub Release. GitHub may redirect that download to
its release-asset CDN. GitHub receives the IP address required for an internet
connection, ordinary TLS/HTTP metadata, and a User-Agent containing application
information. Sparkle's system profiling — the profile it can attach to an
update check — is explicitly disabled. Impuls sends no clipboard data, notes,
snippets, files, calendar content, playback data, analytics identifiers,
hardware serial numbers, or device identifiers through the update channel.

Update archives are stored in temporary system storage, authenticated before
extraction, and cleaned by Sparkle after installation. Impuls does not place
update installers in the Downloads folder. Automatic download and unattended
installation are disabled by default and remain subject to update consent.

Web music is a separate, user-initiated network boundary. Choosing a source in
the Music pane is local and performs no request. Only the explicit **Open Web
Player** action creates a system `WKWebView` and opens the selected provider's
official HTTPS site: Yandex Music, VK Music, or YouTube Music. The site
receives the ordinary connection data it would receive in a browser, including
the IP address, TLS/HTTP metadata, cookies, and the WebKit User-Agent. Its own
privacy policy and subscription terms apply.

Impuls injects a small local bridge into that web player to read the title,
artist, album, playback state, duration, and position exposed by the page and to
forward the user's play, pause, previous, next, and seek actions. Playback data
stays in application memory and is not sent to Impuls, GitHub, or another
provider. Password fields and authentication tokens are never read by the
bridge. WebKit stores the provider's normal cookies and website data locally so
the user does not need to sign in after every launch.

## Optional version statistics

Version statistics are a third network boundary, separate from updates and web
music. The consent state is `unknown`, `allowed`, or `denied`. New and upgraded
installations start at `unknown`; `unknown` and `denied` make no statistics
request. The choice can be changed under **Settings → Data and Privacy**. A
release build also needs an owner-configured HTTPS collector endpoint; source
code contains no hard-coded live production endpoint, and a build without the
endpoint cannot make the request even after consent.

The configured endpoint is embedded in the built application's `Info.plist` and
must pass the release workflow's fail-closed HTTPS/exact-`/v1/heartbeat`
validation. Exact current production host/topology is an operational fact and
must be verified from the actual release/private operations source rather than
copied from an old release into this technical document.

When allowed and configured, Impuls sends at most one `POST /v1/heartbeat`
attempt per hour **for the same app version**, outside the critical launch
path. The attempt timestamp and attempted version are persisted before
transport, so a failed request/relaunch cannot bypass the limit. When the
running app version changes, the new version can make one immediate attempt
instead of waiting for the previous version's cooldown. A best-effort
in-process scheduler may propose another attempt roughly hourly while Impuls is
running; `VersionTelemetryService` remains the sole throttle owner.

The JSON body has an exact allow-list. The version strings below are
illustrative, not a statement of the currently released version:

```json
{
  "schema": 1,
  "installation_id": "random-uuid",
  "app_version": "1.2.3",
  "previous_version": "1.2.2"
}
```

`previous_version` is omitted unless Impuls previously recorded a real running
version and can identify an actual transition. It is never guessed from the
current release number.

The installation UUID is generated randomly and stored as a device-only item in
the user's macOS Keychain so it is stable across launches. It is not derived
from a serial number, UDID, MAC address, Mac name, Apple ID, account, or other
hardware/user value. Disabling statistics stops requests but keeps the local ID,
so enabling the setting later continues the same pseudonymous installation. The
ID can be removed by deleting the `io.tumanov.impuls.version-statistics`
Keychain item; a new one is then generated if statistics are enabled again.

The collector receives normal connection metadata such as an IP address and
User-Agent at the transport layer, as any HTTPS server does, but neither is a
payload field or stored as product analytics. Before database storage, the raw
installation UUID is replaced with a server-side HMAC-SHA256 digest using an
owner secret. The product database stores only that digest, `first_seen`,
`last_seen`, current version, and an available previous version. Collector and
reverse-proxy deployment instructions disable or anonymize access logs for this
route.

The stable installation pseudonym and connection metadata are treated as
personal data where applicable law requires that classification; the product
does not describe them as fully anonymous. Installation and transition records
are deleted after 365 days without a heartbeat. The collector enforces this
retention in the same transaction that records new heartbeats.

The heartbeat never includes clipboard contents, notes, snippets, file names or
paths, calendar data, music/playback data, device names, serial numbers, UDIDs,
hardware identifiers, installed applications, logs, project-support counters,
or other user content. A timeout, server error, or malformed response has no
effect on Impuls operation.

## Feedback and project support

Impuls includes a voluntary feedback window. The app prepares the report locally
and shows exactly what will be shared. Basic technical context is optional and
contains only the Impuls version, macOS version, and processor architecture. It
never adds clipboard contents, notes, snippets, file names, file paths, calendar
data, logs, hardware serial numbers, device identifiers, or project-support
eligibility state.

Impuls does not upload the report. After an explicit button press, it copies the
report to the pasteboard and asks the default browser to open a fixed public
GitHub new-issue page. The user can review and edit the report again before
submitting it. GitHub issues are public and are governed by GitHub's own privacy
terms. No report, rating, or draft is retained by Impuls or sent automatically.

After sustained deliberate use, Impuls may also present a bounded project-support
prompt offering the project's GitHub page or the existing Feedback window. Its
eligibility is calculated entirely on the Mac from coarse local counters/state
such as first meaningful use, active-use days, meaningful-use count, prompt
state and shown count. These values are not sent to Impuls, GitHub or the
version-statistics collector and are excluded from portable backup. Automatic
presentation is capped at two appearances for the lifetime of that local state.
Opening GitHub happens only after an explicit user action and Impuls does not
query GitHub to determine whether a star was actually given.

Settings also offers voluntary support of Impuls development through two fixed
external pages: CloudTips at `https://pay.cloudtips.ru/p/e04ac53f` and Boosty at
`https://boosty.to/tumanovnv/donate`. Impuls opens a page in the system default
browser only after the user explicitly chooses that provider. Information the
user enters on the provider page is processed by that provider under its own
terms and privacy policy. Impuls does not receive card or payment credentials,
the selected amount, payment success or failure, or provider account state. It
stores no provider choice, payment state or entitlement, sends no payment
telemetry, and does not change any feature after the browser handoff.

## Local data

- notes and snippets are stored in `~/Library/Application Support/Impuls`;
- saved clipboard screenshots are stored in `~/Pictures/Impuls` when available;
- shelf references, preferences, version-statistics consent and the last
  observed/attempted app-version state are stored in macOS UserDefaults;
- the explicit interface-language preference is stored locally as
  `app.language.v1`; Impuls uses macOS `AppleLanguages` only when the user
  explicitly selects/clears an app-language override. No language pack is
  downloaded;
- project-support eligibility/decision counters are stored locally in
  UserDefaults, excluded from portable backup, and never transmitted;
- the selected music source is stored in macOS UserDefaults; web login cookies
  and website data are managed locally by the system WebKit data store;
- clipboard history is held in memory by default and is not uploaded;
- if the user explicitly enables persistence, clipboard history is stored as
  an AES-GCM encrypted local archive; its random encryption key is kept in the
  user's macOS Keychain and the archive is removed when persistence is disabled;
- pinned clipboard entries, retention limits, monitoring pause, and application
  exclusions are processed locally; excluded applications are stored only as
  bundle identifiers in settings;
- concealed password-manager entries are excluded;
- an exported backup is a user-selected local JSON file containing settings,
  snippets, and notes; Impuls never uploads it;
- Impuls Actions searches the live clipboard, snippet, and note stores locally;
  it creates no separate search database and sends no query or result anywhere;
- the Battery / Power module reads live power state locally from macOS public
  IOPowerSources and, when available, further values from the local IORegistry.
  It stores no power telemetry, adapter identifiers, or hardware serial numbers
  and sends none of this information anywhere;
- when the user turns on Apple devices — off by default — Impuls also reads the
  batteries of connected Apple accessories. Values come from the local
  IORegistry and, where the registry publishes nothing, from a local
  `/usr/sbin/system_profiler` call for Bluetooth accessory information. That
  call is made directly, with a fixed argument list and no shell, and its output
  is read, parsed and discarded on this Mac;
- an experimental, separately gated provider can read the battery of an iPhone
  or iPad already trusted by this Mac, over USB or the device-sync route macOS
  exposes when the user enables **Show this iPhone when on Wi-Fi** in Finder.
  Impuls does not enable or change that macOS setting. It talks only to the local
  `/var/run/usbmuxd` UNIX socket: it performs no LAN scan, resolves no Bonjour
  service and opens no direct TCP connection. For a paired iPhone, macOS may
  transmit device data over the local Wi-Fi network through its system device
  synchronisation mechanism. No internet or cloud service is involved. Impuls
  asks the device only for a battery percentage, charging and external-power
  flags, a name and a model identifier. It does not pair, alter the existing
  pairing, install anything, or request contacts, photos, messages, installed
  apps, backups, the phone number, the IMEI or the Apple ID. The pairing
  certificates used for the required secure session are read, used in memory,
  and never stored by Impuls, written to a keychain, or written to disk;
- device identifiers — UDID, serial numbers, Bluetooth addresses — are used only
  where the protocol requires them and are never shown in the interface, written
  to logs, added to a feedback report or included in an exported backup. What
  Impuls keeps for recognising a device again is a value derived with a random
  key held on this Mac, which is meaningless anywhere else;
- if the user explicitly enables low-battery alerts, Impuls evaluates fresh
  external-device readings locally at fixed 20 % and 10 % thresholds. A
  component confirmed to be charging is suppressed, and several low components
  of one device are grouped into one notification. The notification may contain
  the device's display name and real percentage. Alert state contains only the
  Mac-local opaque device key, component kind, fired/re-arm flags and a cleanup
  timestamp; it is bounded, never exported and contains no percentage or device
  name. No alert data is uploaded or included in version statistics;
- OCR, background removal, image conversion, resizing, and PDF creation run on
  the Mac with Apple system frameworks. Impuls does not upload source files or
  generated files. Sharing occurs only when the user explicitly chooses AirDrop
  or a service from the macOS Share menu.

## System permissions

- Calendar access is requested only from the Calendar module or Settings;
- Apple Events Automation is requested only after the user asks Impuls to read
  or control the installed Apple Music application;
- web music uses the selected provider's official site and does not require
  Apple Events Automation or Accessibility access;
- notification permission is requested only after the user explicitly enables
  low-battery alerts in Apple Devices Settings. If macOS denies access, device
  monitoring continues without alerts and Impuls does not repeatedly request
  authorization.

Notes and snippets are not encrypted by Impuls. FileVault is recommended for
protection at rest. Secrets, passwords, recovery codes, and private keys should
not be stored in the scratchpad.

# Privacy Policy

Impuls is designed to work locally. It has no analytics, advertising, telemetry,
automatic crash-report upload, remote configuration, account system, or device
identifier.

## Network access

On first launch, Impuls asks whether it may check for updates. Existing 1.2.8
decisions are preserved during migration. If the user declines, Impuls performs
no update request. The setting can be changed later.

When allowed, Sparkle checks the fixed HTTPS feed at:

`https://github.com/TumanovNV/impuls/releases/latest/download/appcast.xml`

After the user accepts an available update, Sparkle downloads the versioned ZIP
from the same repository's GitHub Release. GitHub may redirect that download to
its release-asset CDN. GitHub receives the IP address required for an internet
connection, ordinary TLS/HTTP metadata, and a User-Agent containing application
information. Sparkle's system profiling — the profile it can attach to an
update check — is explicitly disabled. Impuls sends no clipboard
data, notes, snippets, files, calendar content, playback data, analytics
identifiers, hardware serial numbers, or device identifiers.

Update archives are stored in temporary system storage, authenticated before
extraction, and cleaned by Sparkle after installation. Impuls does not place
update installers in the Downloads folder. Automatic download and unattended
installation are disabled.

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

## Feedback

Impuls 1.2.6 includes a voluntary feedback window. The app prepares the report
locally and shows exactly what will be shared. Basic technical context is
optional and contains only the Impuls version, macOS version, and processor
architecture. It never adds clipboard contents, notes, snippets, file names,
file paths, calendar data, logs, hardware serial numbers, or device identifiers.

Impuls does not upload the report. After an explicit button press, it copies the
report to the pasteboard and asks the default browser to open a fixed public
GitHub new-issue page. The user can review and edit the report again before
submitting it. GitHub issues are public and are governed by GitHub's own privacy
terms. No report, rating, or draft is retained by Impuls or sent automatically.

## Local data

- notes and snippets are stored in `~/Library/Application Support/Impuls`;
- saved clipboard screenshots are stored in `~/Pictures/Impuls` when available;
- shelf references and preferences are stored in macOS UserDefaults;
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
  snippets, and notes; Impuls never uploads it.
- Impuls Actions searches the live clipboard, snippet, and note stores locally;
  it creates no separate search database and sends no query or result anywhere.
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
  or iPad connected by cable and already trusted by this Mac. It talks to the
  local `usbmuxd` socket — no network is involved — and asks the device for a
  battery percentage, a charging flag, a name and a model identifier, and for
  nothing else. It does not pair, does not alter the existing pairing, installs
  nothing, and never requests contacts, photos, messages, installed apps,
  backups, the phone number, the IMEI or the Apple ID. The pairing certificates
  it uses to open the required secure session are read, used in memory, and
  never stored by Impuls, written to a keychain, or written to disk;
- device identifiers — UDID, serial numbers, Bluetooth addresses — are used only
  where the protocol requires them and are never shown in the interface, written
  to logs, added to a feedback report or included in an exported backup. What
  Impuls keeps for recognising a device again is a value derived with a random
  key held on this Mac, which is meaningless anywhere else;
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
- notification permission is not requested in Impuls 1.2.6 and remains reserved
  for optional reminder functions in a later update.

Notes and snippets are not encrypted by Impuls. FileVault is recommended for
protection at rest. Secrets, passwords, recovery codes, and private keys should
not be stored in the scratchpad.

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
information. System profiling is explicitly disabled. Impuls sends no clipboard
data, notes, snippets, files, calendar content, playback data, analytics
identifiers, hardware serial numbers, or device identifiers.

Update archives are stored in temporary system storage, authenticated before
extraction, and cleaned by Sparkle after installation. Impuls does not place
update installers in the Downloads folder. Automatic download and unattended
installation are disabled.

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
- OCR, background removal, image conversion, resizing, and PDF creation run on
  the Mac with Apple system frameworks. Impuls does not upload source files or
  generated files. Sharing occurs only when the user explicitly chooses AirDrop
  or a service from the macOS Share menu.

## System permissions

- Calendar access is requested only from the Calendar module or Settings;
- Accessibility is requested only when the user explicitly enables support for
  standard system media-key events;
- notification permission is not requested in Impuls 1.2.6 and remains reserved
  for optional reminder functions in a later update.

Notes and snippets are not encrypted by Impuls. FileVault is recommended for
protection at rest. Secrets, passwords, recovery codes, and private keys should
not be stored in the scratchpad.

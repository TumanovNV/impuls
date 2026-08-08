# Privacy Policy

Impuls is designed to work locally. It has no analytics, advertising, telemetry,
crash-report upload, remote configuration, account system, or device identifier.

## Network access

On first launch, Impuls asks whether it may check for updates. If the user
declines, Impuls performs no update request. The setting can be changed later.

When allowed, Impuls sends an HTTPS GET request to:

`https://api.github.com/repos/TumanovNV/impuls/releases/latest`

GitHub receives the IP address required for an internet connection, ordinary
TLS/HTTP metadata, and a User-Agent containing the installed Impuls version.
Impuls sends no clipboard data, notes, snippets, files, calendar content,
playback data, analytics identifiers, or hardware serial numbers.

## Local data

- notes and snippets are stored in `~/Library/Application Support/Impuls`;
- saved clipboard screenshots are stored in `~/Pictures/Impuls` when available;
- shelf references and preferences are stored in macOS UserDefaults;
- clipboard history is held in memory and is not uploaded;
- concealed password-manager entries are excluded.
- an exported backup is a user-selected local JSON file containing settings,
  snippets, and notes; Impuls never uploads it.
- Impuls Actions searches the live clipboard, snippet, and note stores locally;
  it creates no separate search database and sends no query or result anywhere.

## System permissions

- Calendar access is requested only from the Calendar module or Settings;
- Accessibility is requested only when the user explicitly enables support for
  standard system media-key events;
- notification permission is not requested in Impuls 1.2.0 and remains reserved
  for optional reminder functions in a later update.

Notes and snippets are not encrypted by Impuls. FileVault is recommended for
protection at rest. Secrets, passwords, recovery codes, and private keys should
not be stored in the scratchpad.

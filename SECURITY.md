# Security Policy

## Supported versions

Only the latest published Impuls release receives security fixes.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting / Security Advisories for this
repository. Do not open a public issue for an unpatched vulnerability and do not
include user data, credentials, or exploit payloads in public discussions.

## Security boundaries

- all application networking is confined to `UpdateService.swift`;
- the only allowed endpoint is the fixed HTTPS GitHub Releases API URL;
- update requests use an ephemeral session, reject cross-endpoint redirects,
  cap response size while bytes arrive, require an exact matching release-tag
  URL, and do not permit parallel checks;
- feedback uses no in-app network request: a length-bounded report is copied
  locally and the system browser may open only the exact Impuls new-issue URL;
- feedback diagnostics are allow-listed and never inspect user content, paths,
  logs, device identifiers, or clipboard history;
- no private frameworks or process injection;
- no embedded GitHub tokens or release credentials;
- release credentials belong only in protected GitHub Actions secrets;
- optional clipboard persistence uses AES-GCM and keeps the device-only archive
  key in macOS Keychain; clipboard persistence remains disabled by default;
- CI rejects networking APIs outside the update service and checks that no
  MediaRemote/perl helper is bundled;
- automatic in-app installation is disabled until Developer ID signing,
  notarization, and signed update archives are configured.
- full-resolution image operations reject dimensions above a defined pixel
  budget before decoding, and oversized clipboard payloads are not retained.
- local stores use bounded streaming reads, and meeting links are restricted to
  known HTTPS providers before macOS is asked to open them.
- screenshot and note writes run on bounded serial queues instead of the UI
  thread; media artwork is byte-, dimension-, and display-size bounded.
- generated-file Undo verifies a streaming SHA-256 content digest in addition
  to size, modification date, and filesystem resource identity.

## Known limitations

Development releases are ad-hoc signed and not notarized. Gatekeeper therefore
cannot authenticate their publisher. This is a distribution limitation, not a
condition to bypass silently.

The latest documented review is
[`docs/audits/1.2.6-security.md`](docs/audits/1.2.6-security.md).

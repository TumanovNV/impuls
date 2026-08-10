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
- automatic downloads, unattended installation, system profiling, analytics,
  and device identifiers are disabled;
- feedback uses no in-app network request: a length-bounded report is copied
  locally and the system browser may open only the exact Impuls new-issue URL;
- feedback diagnostics are allow-listed and never inspect user content, paths,
  logs, device identifiers, or clipboard history;
- no private frameworks or process injection;
- Apple Music metadata uses its scripting interface plus bounded distributed
  player notifications; the
  Hardened Runtime bundle carries the explicit Apple Events Automation
  entitlement and macOS remains the permission authority;
- web music is created only by the explicit Open Web Player action, uses the
  system WebKit engine, allows main-frame HTTPS navigation only within the
  selected provider and its authentication domains, and hands unrelated links
  to the default browser;
- subframes — captcha, consent and sign-in widgets — are allowed ordinary
  HTTPS, because the bridge is installed for the main frame only and a subframe
  therefore cannot reach Impuls at all;
- the page bridge accepts bounded playback metadata only from an HTTPS page of
  the currently selected provider and never inspects passwords, cookies, or
  authentication tokens;
- cover art is handed over by the page as bounded bytes and validated through
  ImageIO; the application itself makes no request for it;
- no embedded GitHub tokens or release credentials;
- release credentials belong only in protected GitHub Actions secrets;
- optional clipboard persistence uses AES-GCM and keeps the device-only archive
  key in macOS Keychain; clipboard persistence remains disabled by default;
- CI rejects Impuls-owned networking APIs outside the update service and the
  explicit WebKit music boundary, proves the web view is lazily constructed,
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

The latest documented review is
[`docs/audits/1.3.1-web-music-boundary.md`](docs/audits/1.3.1-web-music-boundary.md).

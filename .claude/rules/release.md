---
paths:
  - "Scripts/**"
  - ".github/workflows/**"
  - "docs/releases/**"
  - "Package.swift"
  - "Package.resolved"
---

# Release and build plumbing

These files carry the project's security guarantees. Read the whole workflow before
editing a step, and prefer plan mode over an in-place fix.

## Version and notes move together

`Scripts/version` holds a single line, `VERSION=x.y.z`. Both workflows read it with
`sed` and then require `docs/releases/x.y.z.md` to exist and be non-empty. Bumping the
version without writing release notes fails validation before anything is built.

## What release.yml does

Tags `v<version>`, builds the app, produces the DMG and ZIP with their SHA-256 files,
generates `appcast.xml` with Sparkle's `generate_appcast`, signs it with the EdDSA key
from repository secrets, verifies the signature and enclosure, then creates the GitHub
Release with all artifacts. It refuses to run when the tag already exists.

Never create tags or releases by hand, and never move the signing key out of secrets.

## Sparkle settings that must not drift

`Scripts/bundle.sh` writes these into `Info.plist`, and the build verifies every one:

| Key | Value |
| --- | --- |
| `SUFeedURL` | `…/releases/latest/download/appcast.xml` |
| `SUPublicEDKey` | `/fAb0WKLYV8FTT+VkvGKgtIXfsiVG74NlJ+to0BusDg=` |
| `SUEnableAutomaticChecks` | `false` |
| `SUAutomaticallyUpdate` | `false` |
| `SUAllowsAutomaticUpdates` | `false` |
| `SUEnableSystemProfiling` | `false` |
| `SUVerifyUpdateBeforeExtraction` | `true` |
| `SURequireSignedFeed` | `true` |
| `SUSignedFeedFailureExpirationInterval` | `0` |

Updates stay opt-in and verified. A change that makes them automatic contradicts the
privacy model stated in `PRIVACY.md` and on the site.

## Dependencies

Sparkle is pinned with `exact: "2.9.5"`, and CI also greps the resolved revision in
`Package.resolved`. Do not add dependencies, and do not bump Sparkle without updating
both files plus the audit note in `docs/audits/`.

## Signing

`bundle.sh` uses Developer ID when `IMPULS_DEVELOPER_ID_APPLICATION` is set and an
ad-hoc signature otherwise. `codesign --force --deep` is banned — CI checks for its
absence, because deep signing masks a broken nested signature instead of failing.

## The smoke test

On pull requests the built app is launched with `CI=true` and then inspected with
`lsof`: any open socket fails the job. If a change makes the app talk to the network
at launch, that is the check that will catch it.

---
paths:
  - "Scripts/**"
  - ".github/workflows/**"
  - "docs/releases/**"
  - "knowledge-base/13-qa/release-evidence/**"
  - "knowledge-base/13-qa/behavioral-qa-matrix.md"
  - "Package.swift"
  - "Package.resolved"
---

# Release and build plumbing

These files carry the project's security and release guarantees. Read the whole workflow before editing a step, and prefer plan mode over an in-place fix.

## Version, notes and QA evidence move together

`Scripts/version` holds a single line, `VERSION=x.y.z`.

A release candidate also needs:

```text
docs/releases/x.y.z.md
knowledge-base/13-qa/release-evidence/x.y.z.md
```

The release notes describe user-facing changes. Release QA evidence records the real manual/mixed hardware/TCC/service result for that version. The Behavioral QA Matrix is only the scenario inventory and must never be treated as proof that a release passed.

`knowledge-base` CI runs `Scripts/check-release-qa-evidence.py`. Starting with 1.4.12, `not-recorded` is forbidden and every non-automated matrix row must be classified explicitly. Never invent a manual `pass` from unit tests, old screenshots or a similar previous release.

## What release.yml does

The workflow builds the app, produces the DMG and ZIP with their SHA-256 files, generates `appcast.xml` with Sparkle's `generate_appcast`, signs it with the EdDSA key from repository secrets, verifies the signature and enclosure, then creates or updates the GitHub Release.

If `v<version>` / the GitHub Release already exists, the current workflow deliberately **reissues** the release metadata and uploads the rebuilt assets with `--clobber`; it does not fail merely because the tag already exists. Treat `workflow_dispatch` or a `release.yml` change as potentially release-affecting for the current version.

Never create production tags/releases by hand during the normal flow, and never move the signing key out of secrets.

## Sparkle settings that must not drift

`Scripts/bundle.sh` writes these into `Info.plist`, and build/release CI verifies the important values:

| Key | Value |
| --- | --- |
| `SUFeedURL` | `…/releases/latest/download/appcast.xml` |
| `SUPublicEDKey` | `/fAb0WKLYV8FTT+VkvGKgtIXfsiVG74NlJ+to0BusDg=` |
| `SUEnableAutomaticChecks` | `false` |
| `SUAutomaticallyUpdate` | `false` |
| `SUAllowsAutomaticUpdates` | `true` |
| `SUScheduledCheckInterval` | `86400` |
| `SUEnableSystemProfiling` | `false` |
| `SUVerifyUpdateBeforeExtraction` | `true` |
| `SURequireSignedFeed` | `true` |
| `SUSignedFeedFailureExpirationInterval` | `0` |

`SUAllowsAutomaticUpdates=true` means the Sparkle capability is available. It does **not** make updates automatic by default: automatic checks and `SUAutomaticallyUpdate` remain false, and the app's user-controlled update policy must continue to gate automatic behavior.

Updates stay opt-in and verified. A change that makes them unsolicited contradicts the privacy/update model stated in the current code, tests and public documentation.

## Release QA evidence

For a version bump:

1. copy `knowledge-base/13-qa/release-evidence/TEMPLATE.md` to the version file;
2. record the exact candidate/release commit;
3. record generic reproducible Mac/hardware/TCC environments without serials, UDIDs, hostnames or user content;
4. account for every `mixed`, `manual-macos`, `manual-hardware` and `manual-service` matrix row;
5. choose `certified`, `ship-with-known-gaps` or `blocked` truthfully;
6. run `python3 Scripts/check-release-qa-evidence.py --all`.

`certified` is stronger than green CI: all manual/mixed rows must be `pass` or justified `not-applicable`, and a real Mac environment must be recorded. `ship-with-known-gaps` is allowed only when the unresolved gaps remain explicit. `blocked` means do not call the candidate ready.

## Dependencies

Sparkle is pinned with `exact: "2.9.5"`, and CI also checks the resolved revision in `Package.resolved`. Do not add dependencies, and do not bump Sparkle without updating both files plus the relevant supply-chain/security documentation.

## Signing

`bundle.sh` uses Developer ID when `IMPULS_DEVELOPER_ID_APPLICATION` is set and an ad-hoc signature otherwise. `codesign --force --deep` is banned — CI checks for its absence, because deep signing masks a broken nested signature instead of failing.

## The smoke test

On pull requests the built app is launched with `CI=true` and then inspected with `lsof`: any open socket fails the job. If a change makes the app talk to the network at launch, that is the check that will catch it.

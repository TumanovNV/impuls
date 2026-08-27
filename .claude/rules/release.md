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

Two jobs. `release` (`contents: read`) requires every Apple secret up front, builds the app **once**, signs it with the Developer ID, notarizes and staples it, packages the DMG with `Scripts/dmg.sh --no-build`, signs the DMG with the same Developer ID (`hdiutil create` leaves it unsigned and Apple rejects unsigned submissions), notarizes and staples that too, builds the update ZIP from the same stapled bundle, then generates and verifies `appcast.xml` with Sparkle's EdDSA key. `publish` (`contents: write`, no Apple credentials) downloads those artifacts, re-checks their SHA-256 and creates or updates the GitHub Release.

The push trigger watches `Scripts/version` only. Editing `release.yml` no longer re-publishes the current version — that used to be a live foot-gun.

`publish` runs only from `main`, and only on a `Scripts/version` push or a `workflow_dispatch` with `publish_release` explicitly on. The default manual dispatch is a signed/notarized release candidate: artifacts, no tag, no release. If `v<version>` already exists the publish job still **reissues** metadata and uploads with `--clobber`.

The release path is fail-closed — there is no ad-hoc fallback, and the built app is checked for `Developer ID Application` authority, Hardened Runtime, a secure timestamp and no ad-hoc flag. The notarized code directory hash is carried through to the extracted ZIP and the app inside the DMG, so nothing can rebuild the bundle after Apple accepted it.

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

`bundle.sh` uses Developer ID when `IMPULS_DEVELOPER_ID_APPLICATION` is set and an ad-hoc signature otherwise. That fallback is for local builds only; `release.yml` refuses to start without the full Apple secret set. `codesign --force --deep` is banned — CI checks for its absence, because deep signing masks a broken nested signature instead of failing.

Secret names (values live only in GitHub Secrets): `IMPULS_DEVELOPER_ID_P12_BASE64`, `IMPULS_DEVELOPER_ID_P12_PASSWORD`, `IMPULS_DEVELOPER_ID_APPLICATION`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, plus the existing `SPARKLE_EDDSA_PRIVATE_KEY`. The certificate is imported into an ephemeral keychain in `$RUNNER_TEMP` and deleted by an `if: always()` step.

## The smoke test

On pull requests the built app is launched with `CI=true` and then inspected with `lsof`: any open socket fails the job. If a change makes the app talk to the network at launch, that is the check that will catch it.

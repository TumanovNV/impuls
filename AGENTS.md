# AGENTS.md

Instructions for coding agents working on Impuls. Read this before changing anything.

Impuls is a native macOS utility that turns the area around the MacBook notch, or the top edge of another Mac/display, into a local workspace for Actions search, music, file shelf, clipboard history, snippets, calendar, translator, notes and power/device status. Swift 6 toolchain, SwiftUI on top of AppKit, macOS 15 or newer. The product is local-first.

## Current project context

Do not use a historical release handoff as the current project state.

Start with:

1. `PROJECT-MANIFEST.json` — routing-only machine-readable map of stable project topology and canonical owners.
2. `knowledge-base/10-ai/AI-INDEX.md` — task-oriented documentation entrypoint.
3. `knowledge-base/00-project/project-status.md` — current shipped baseline.
4. `knowledge-base/10-ai/invariants.md` — concise project invariants.
5. `knowledge-base/12-reference/README.md` — schema/type/performance reference routes.
6. `knowledge-base/13-qa/README.md` — behavioral verification and release-evidence routes when platform/hardware behavior matters.
7. The implementation and tests for the area you are changing.

The root manifest is a routing aid, not a duplicate implementation database. Do not put persisted keys, performance constants, live endpoints, production topology, addresses or secrets into it.

At Documentation v1.3 the baseline in `main` is Impuls 1.4.11. Always verify `Scripts/version` when the exact version matters.

Historical technical documents under `docs/` remain valuable evidence, especially the 1.4.6 device-battery and 1.4.7 multi-display documents, but they are not automatically current state.

## Commands

```bash
swift test -c release
./Scripts/bundle.sh release
./Scripts/dmg.sh
python3 Scripts/check-project-manifest.py
python3 Scripts/check-knowledge-base.py
python3 Scripts/generate-knowledge-map.py --check
python3 Scripts/check-documentation-freshness.py
python3 Scripts/check-release-qa-evidence.py --all
# PR/diff-aware documentation check:
python3 Scripts/check-documentation-guardian.py --base <base-sha>
open build/Impuls.app
```

`Scripts/bundle.sh` signs with Developer ID when `IMPULS_DEVELOPER_ID_APPLICATION` is set and falls back to an ad-hoc signature otherwise. Never assume the current public signing/notarization state from old notes; verify the current workflow and artifact.

## Hard invariants

`.github/workflows/build.yml` enforces important parts of these rules. If code and this summary disagree, inspect the current CI contract before changing either.

1. **Network access has three explicit owners.** `UpdateService.swift` owns the opt-in Sparkle channel. `WebMusicPlayer.swift` may open only the official HTTPS site selected by the user, and only from the explicit Open Web Player action; launching Impuls or merely selecting a source must not construct `WKWebView`. `VersionTelemetryService.swift` owns the separately consented version-only heartbeat to an optional build-configured HTTPS collector. Network APIs are banned elsewhere unless the architecture is deliberately changed and reviewed.
2. **No private media APIs and no injection.** `/usr/bin/perl`, `MediaRemote`, `dl_load_file` and `DynaLoader` must not appear in `Sources` or `Scripts`. Native Apple Music metadata uses permitted scripting/notification mechanisms; web metadata comes only from the selected provider page after explicit user action.
3. **Sparkle is pinned.** `exact: "2.9.5"` in `Package.swift` and the matching revision in `Package.resolved`. Adding, bumping or replacing a dependency is a reviewed architecture/security change.
4. **The panel follows system appearance.** Semantic colours come from the project's theme system. The collapsed tab is the deliberate black exception so it visually merges with the physical cutout.
5. **Actions selection never follows the pointer.** Hover is visual affordance only; it must not silently replace explicit selection.
6. **Localization is complete.** Every `localized("…")` key must exist in both `Resources/en.lproj/Localizable.strings` and `Resources/ru.lproj/Localizable.strings`.
7. **Version, release notes and release QA evidence travel together.** `Scripts/version` holds `VERSION=x.y.z`, `docs/releases/x.y.z.md` must exist and be non-empty, and `knowledge-base/13-qa/release-evidence/x.y.z.md` must account for the release's manual/mixed Behavioral QA rows. From 1.4.12 onward `not-recorded` is forbidden.
8. **The website has CI-sensitive literals.** `docs/index.html` is part of the GitHub Pages production contract. Read `.claude/rules/website.md` and current CI before editing it.
9. **Feedback collects nothing automatically.** `FeedbackService.swift` must not grow hidden networking, hardware identifiers or user-content collection. Feedback is explicit and user-visible.
10. **Sparkle is opt-in and verified.** Automatic checks and automatic installation default to false; system profiling stays false. Automatic installation requires update-check consent. Signed feed and verify-before-extraction remain enabled.
11. **Bounded reads everywhere.** Files, pasteboard payloads and other potentially large inputs go through the project's bounded abstractions and explicit limits.
12. **Background work is owned and bounded.** New timers/pollers/tasks/queues require lifecycle, cadence/tolerance, cancellation and documentation review. Presentation surfaces never create duplicate shared work.
13. **Slow I/O stays off the main actor.** Disk, process, socket and device reads must not freeze observable/UI state.
14. **Resource budgets are contracts.** Raising/removing size/count/cadence/timeout/backpressure limits requires explicit review and tests, not a magic-number edit.
15. **QA inventory is not pass evidence.** A Behavioral QA row, unit test or historical screenshot does not prove a particular release passed real hardware/TCC. A `pass`/`fail`/`blocked` manual result must be tied to a truthful release-specific environment without serials, UDIDs or secrets.

## Device and power invariants

These are standing rules for anything touching Apple-device discovery or power data:

1. `.power` stays the module's internal identifier because settings, backup and migrations depend on it.
2. `PowerMonitor` is the established local-Mac power path; external-device support adapts around it rather than duplicating it.
3. No private Apple frameworks. Secure Transport, where used, remains isolated to its public/legacy boundary.
4. Raw device identifiers — UDID, serial, Bluetooth address, pairing material — never reach UI, ordinary logs, feedback or backups. `AppleDeviceIdentity` is an intentional boundary.
5. External-device discovery is off until the user enables it. An update or presentation surface must never create a new prompt or connection by itself.
6. Device I/O must not run on the main actor.
7. Missing data stays missing. Never fabricate 0%, a guessed charging state or a category rendered as a number.
8. iPhone/iPad discovery is controlled by the user-facing device-discovery setting. With discovery off there must be no topology socket, usbmuxd traffic or read.
9. Best-effort system tools use fixed executable paths, fixed arguments, no shell/user argument injection, bounded output and timeouts.

See `knowledge-base/02-modules/README.md`, `knowledge-base/06-security/security-model.md`, `knowledge-base/12-reference/background-concurrency-registry.md`, `knowledge-base/12-reference/resource-budget-registry.md`, `knowledge-base/13-qa/behavioral-qa-matrix.md`, `knowledge-base/13-qa/release-evidence/README.md`, `docs/APPLE_DEVICE_BATTERY_SUPPORT.md` and the relevant tests before changing this area.

## Layout

| Path | What lives there |
| --- | --- |
| `PROJECT-MANIFEST.json` | routing-only machine-readable map for cold-start agents |
| `Sources/Impuls/App` | lifecycle, app glue, Menu Bar controller, localization |
| `Sources/Impuls/Model` | shared application/panel state |
| `Sources/Impuls/Notch` | display topology, per-display windows, geometry, pointer tracking |
| `Sources/Impuls/Services` | stores, system adapters and business logic; no UI |
| `Sources/Impuls/Settings` | native settings and related windows |
| `Sources/Impuls/UI` | module panes and `Theme.swift` |
| `Sources/ImpulsLauncher` | executable target |
| `Tests/ImpulsTests` | Swift tests |
| `Resources` | localization and entitlements/resources |
| `Scripts` | build, packaging, versioning and maintenance scripts |
| `docs` | public website, release notes, audits and historical technical material |
| `knowledge-base` | current structured project knowledge for humans and AI |

## Architecture conventions

- Comments are in English and explain why, especially trade-offs and rejected approaches.
- UI numbers come from the existing theme/geometry system, not taste.
- Stores/services do not import SwiftUI; panes do not touch the filesystem directly.
- One responsibility per file where practical.
- A new shipped module requires a new tab/destination, store/service, pane, RU/EN strings, tests and an update to the module catalog **and `PROJECT-MANIFEST.json`**.
- **Shared services, per-display presentation.** `NotchViewModel` and stores are shared. Each display owns only presentation state/window/view/geometry. Do not create a store, timer or monitor per display. Exactly one surface is active.
- `PointerWatcher` is a shared sampler with per-display zones; do not add a timer per display.
- Menu Bar is a presentation/workspace surface over existing state, not a reason to start providers, permissions, polling or networking.

## Performance / concurrency documentation rule

Before adding or changing a repeating timer, poller, debounce, delayed retry, long-lived `Task`, observer/socket, queue or actor boundary, read `knowledge-base/12-reference/background-concurrency-registry.md` and update it when the contract changes.

Before raising/removing a size, count, cadence, timeout or backpressure limit, read `knowledge-base/12-reference/resource-budget-registry.md`. Prefer bounded/lazy/streaming designs over removing a limit.

The semantic `Documentation Guardian` checks sensitive changed lines during PR CI. The historical freshness guard separately checks whether curated canonical docs are newer than their tracked source. Do not bypass either with meaningless Markdown edits or a fake `last_reviewed`: establish the real code/test contract and make the smallest truthful documentation update.

## Release flow

1. Bump `VERSION` in `Scripts/version`.
2. Write `docs/releases/<version>.md` with a Russian section, then `---`, then a short English summary.
3. Copy `knowledge-base/13-qa/release-evidence/TEMPLATE.md` to `knowledge-base/13-qa/release-evidence/<version>.md` and record the exact candidate/release commit, real test environments and one result for every manual/mixed QA row.
4. Add/update a security audit if networking, permissions, updates or stored data changed.
5. Update the relevant files under `knowledge-base/` when architecture/current state changed.
6. Update Behavioral QA when a change introduces a new platform/hardware/TCC/lifecycle verification scenario; then update the candidate release evidence so the new manual obligation is explicit.
7. Choose the truthful release decision: `certified`, `ship-with-known-gaps` or `blocked`. Do not invent passes to remove a gap.
8. Run `python3 Scripts/check-release-qa-evidence.py --all` together with the normal repository checks.
9. Open a pull request and let CI pass.
10. Merge to `main`; the release workflow performs the normal tag/build/appcast/release process.

Do not create production tags/releases manually during the normal flow, and never commit signing keys, secrets or raw device identifiers to QA evidence.

See `knowledge-base/05-release/release-process.md` and `knowledge-base/13-qa/release-evidence/README.md` for the current release documentation.

## Documentation rule

**Code changes and project knowledge travel together.**

If a change alters stable project topology — shipped modules, canonical owners, network owners, permission domains or major repository routes — update `PROJECT-MANIFEST.json` in the same change. Keep it routing-only.

If a change alters architecture, module ownership, networking, permissions, persistence, device identity, background work/concurrency, resource budgets, release semantics or the current shipped baseline, update the corresponding document under `knowledge-base/` in the same change. Long-lived architectural decisions require an ADR under `knowledge-base/08-decisions/`.

If a change introduces a new user-visible platform/hardware/TCC/lifecycle edge, update `knowledge-base/13-qa/behavioral-qa-matrix.md` even when part of the deterministic core is unit-tested. If a release is being prepared, the version-specific evidence file must classify that row too.

If a new canonical architecture/reference owner is introduced, consider adding it to `Scripts/documentation-freshness.json` so historical drift is machine-detectable.

`last_reviewed` changes only after actual review against source/tests/CI. It is evidence, not a version-bump ritual.

If documentation conflicts with code/tests/CI, establish the actual contract first and then fix the stale document. Never preserve an obsolete statement just because it is written down.

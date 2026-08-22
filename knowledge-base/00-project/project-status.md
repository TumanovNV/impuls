---
title: Project Status
type: status
status: active
documentation_version: 1.3
app_version: 1.4.15
last_reviewed: 2026-08-22
tags: [impuls, status, current]
---

# Текущее состояние проекта

## Baseline

**Current release candidate: 1.4.15. Latest published production release at release-preparation time: 1.4.14.** Источник версии — `Scripts/version`.

**Current documentation baseline: 1.3.**

Release `1.4.15` packages the already-merged localization wave (PR #75) and local-first project-support flow (PR #76). The product now ships seven interface localizations (`en`, `ru`, `de`, `fr`, `es`, `zh-Hans`, `ja`), an in-app language selector with safe automatic self-relaunch, and a bounded project-support/feedback prompt whose eligibility stays entirely on the Mac and is capped at two automatic appearances. The release notes disclose that Russian and English remain the primary localizations and that the five added translations were prepared with AI assistance and have not yet received full native-speaker proofreading. The 1.4.15 release decision is `ship-with-known-gaps`: automated CI is required before merge, while unperformed manual hardware/TCC/service scenarios remain explicit `not-run` in version-specific evidence rather than being inferred from partial feature QA.

Release `1.4.14` remains the last confirmed published artifact while this release PR is under review. It contains the Power Center redesign, Apple-accessory detection fixes, branding refresh, version-aware What's New fix and version-statistics follow-up. Tag `v1.4.14` and its public GitHub Release exist with DMG, ZIP, checksums and a signed appcast. Developer ID signing and Apple notarization were not claimed for that release.

After the 1.4.15 release workflow succeeds, this document should be updated to mark 1.4.15 as the published production baseline rather than silently assuming publication from the version bump alone.

## Current product surface

- native macOS 15+ Swift/SwiftUI-on-AppKit application;
- 9 panel modules;
- one shared service graph + per-display presentation surfaces;
- configurable Menu Bar workspace;
- native Menu Bar battery status presentation for resolved Mac/compatible Apple-device state;
- onboarding / What's New;
- local backup/restore for portable settings + snippets + notes;
- opt-in signed Sparkle updates;
- separate opt-in version statistics;
- Power/Battery center with explicitly enabled external Apple devices;
- seven interface localizations — `en`, `ru`, `de`, `fr`, `es`, `zh-Hans`, `ja` — each carrying both `Localizable.strings` and `InfoPlist.strings`;
- an in-app interface-language setting owned by `AppLanguageService`, applied on the next launch through a confirmed self-relaunch;
- a local-first project-support prompt: eligibility is computed entirely on the Mac, it appears only after sustained deliberate use and only once Impuls has returned to idle, it is capped at two automatic appearances for the lifetime of the local state, GitHub and Feedback open only after an explicit user action, and it adds no telemetry and no network boundary. Canonical owner: [Settings, Onboarding, Feedback and Project Support](../01-architecture/settings-onboarding-feedback.md).

## Documentation coverage 1.3

The knowledge base contains:

- application lifecycle, state ownership and multi-display architecture;
- storage/persistence, permissions and networking boundaries;
- Mermaid system/data/release/security diagrams;
- detailed pages for all 9 modules plus Menu Bar;
- macOS TCC and signing/distribution;
- build/test/module-development SOPs;
- update/release pipeline;
- threat model, data classification and privacy boundaries;
- ADR-001…005;
- AI routing and change-impact matrix;
- formal schema/migration registry;
- core type ownership reference;
- CI-checked generated Type → Tests → Docs map with **34 curated core owners**, including the 1.4.12 `MenuBarStatusItemPresentation` → deterministic tests → Menu Bar canonical-doc route;
- formal split between public software documentation and private production operations documentation;
- background work / concurrency registry with cadence, cancellation and MainActor boundaries;
- centralized input/resource/cadence budgets;
- behavioral QA matrix for automated, real-macOS, hardware and service-dependent scenarios;
- machine-readable source/test → Behavioral QA impact mapping with fail-closed handling for unmapped behavioral source changes;
- diff-aware QA impact reports that identify exact `DISP-*`, `PERM-*`, `PWR-*`, `DATA-*`, `ACT-*`, `TR-*`, `MUS-*`, `UI-*`, `SUP-*` and `REL-*` contracts affected by a change;
- per-release QA evidence records that bind manual/mixed scenarios to real environments, outcomes and known gaps;
- a machine-checked release QA policy that requires an evidence file whenever the version baseline changes and forbids historical `not-recorded` results from 1.4.12 onward;
- Documentation Guardian v2 with 11 semantic contract families, including privacy/device identity, telemetry payload/privacy, update/signing integrity, ownership/actor boundaries and module topology in addition to the original background/resource/persistence/network/permission/dependency rules;
- Git-history freshness guard with **21 curated canonical mappings**, including Menu Bar, Privacy Boundaries, Signing & Distribution, State & Ownership and the Core Type Reference;
- weekly periodic review-age enforcement for curated high-risk docs;
- explicit collector SQLite schema versioning and ordered migration boundary using `PRAGMA user_version`;
- production website architecture and design-system documentation for RU/EN GitHub Pages.

## Current architectural anchors

1. one `NotchViewModel` per process;
2. exactly one active display surface;
3. three Internet network owners;
4. sensitive permission prompts only after explicit user action;
5. local-first content and bounded reads;
6. raw device identities never cross presentation/privacy boundary;
7. signed update verification independent of Apple Developer ID availability;
8. persisted-format changes require explicit compatibility/migration review;
9. public app/software facts and private production runtime facts have separate canonical owners;
10. presentation surfaces must not multiply timers/providers/services;
11. slow disk/process/device I/O stays off the main actor;
12. performance limits and wake-up cadences are documented review contracts, not anonymous magic numbers;
13. collector database versions are explicit, ordered and fail closed on unknown future or malformed legacy schemas;
14. a QA scenario inventory never implies a release passed it; manual/hardware/TCC pass claims require per-release evidence tied to an explicit environment;
15. behavioral source/test ownership is machine-routed to Behavioral QA IDs; a newly changed tracked behavioral source must have a QA route or a narrow documented exemption;
16. privacy identity, telemetry payload, update-signing integrity, actor ownership and shipped module topology changes create machine-enforced canonical documentation review obligations;
17. Menu Bar status rendering is a pure presentation boundary over already-resolved shared state; `MenuBarStatusItemPresentation` must not become a provider/network/polling owner;
18. project-support eligibility remains machine-local, does not become telemetry/networking, and automatic prompting stays bounded to at most two appearances for the lifetime of the local state.

## Documentation automation

Six repository checks now protect documentation and QA drift:

```text
Scripts/check-knowledge-base.py
Scripts/generate-knowledge-map.py --check
Scripts/check-documentation-guardian.py --base <base-sha>
Scripts/check-documentation-freshness.py
Scripts/check-qa-impact.py --base <base-sha>
Scripts/check-release-qa-evidence.py --release-gate
```

The first validates Markdown/frontmatter/local links/fenced diagrams/baseline metadata. The second verifies the committed source→tests→docs reference against the curated manifest and actual repository files; the current map contains 34 verified owners. The third is Documentation Guardian v2: it inspects added and removed source lines across 11 narrow semantic contract families and requires the appropriate canonical owner in the same diff. The protected families include background/concurrency, resource budgets, persistence/schema, networking, permissions, dependencies, privacy/device identity, telemetry payload/privacy, update/signing integrity, ownership/actor boundaries and shipped module topology. The fourth uses full Git history to prove that 21 curated canonical mappings are not older than their tracked implementation. When a document and its tracked source share their latest commit they travelled together, so only the ancestry and review-age rules apply; a `last_reviewed` written before a commit that lands after midnight in a positive UTC offset is a timezone artefact, not drift.

The fifth maps the actual Git diff through `Scripts/qa-impact-rules.json`, reports impacted Behavioral QA IDs, fails when a changed tracked behavioral source has no route, requires every matrix scenario to be covered by the map, requires automated QA IDs to have a mapped test route, and on version-bump diffs verifies that impacted non-automated IDs exist in that version's Release QA Evidence. The sixth validates the full release evidence contract and rejects a release candidate whose decision is `blocked`.

The weekly scheduled knowledge-base workflow additionally enables freshness review-age policy. It does not make ordinary PRs fail merely because calendar time passed. QA impact validation runs configuration-only when no meaningful diff base exists.

These guards are intentionally conservative: they do not pretend automation can understand architecture or simulate real hardware/TCC. Their job is to make high-risk changes, stale ownership, unmapped behavioral code and missing manual evidence impossible to overlook during an AI/PR workflow. Guardian and freshness routes deliberately use curated owners rather than repository-wide heuristics so ordinary implementation edits remain quiet.

## Collector schema state

Collector SQLite schema is explicitly versioned as schema `1` with `PRAGMA user_version`. The historical unversioned database is treated as schema `0` and is adopted only after exact supported table-column validation; existing telemetry rows are preserved. Unknown future versions and malformed legacy shapes fail closed. Future schema changes must add ordered migrations and deterministic tests before deployment. See [Schema & Migration Registry](../12-reference/schema-migration-registry.md).

## Release QA evidence state

Release `1.4.11` has a truthful retrospective evidence record because the structured hardware/TCC evidence system did not exist at release time. Missing historical rows are recorded as `not-recorded`; they are not silently converted to pass.

Starting with `1.4.12`, every version baseline must include `knowledge-base/13-qa/release-evidence/<version>.md`. Every `mixed`, `manual-macos`, `manual-hardware` and `manual-service` matrix scenario must be classified explicitly. A release may be `certified`, `ship-with-known-gaps` or `blocked`, but certification requires all manual/mixed rows to be `pass` or justified `not-applicable` and at least one real Mac environment. The CI shipping gate rejects `blocked` candidates.

The 1.4.13 release used `ship-with-known-gaps`: the hardening build passed a release-owner smoke test on a real Mac, while scenario-specific manual/hardware/TCC/service checks that were not performed remained visible as `not-run`. The 1.4.14 release also used `ship-with-known-gaps`: a real Mac mini manual pass confirmed the Power Center's Apple accessory detection and desktop no-battery handling while remaining scenario-specific manual/hardware/TCC/translation/web-player/update checks stayed explicit `not-run`.

The 1.4.15 candidate likewise uses `ship-with-known-gaps`. The maintainer manually exercised the new localization/self-relaunch and project-support paths on a real Mac before release preparation, but the current `UI-07` and `SUP-01` matrix rows include additional subconditions not all captured as one complete durable scenario, so they remain conservatively classified `not-run` in the release evidence. Full native-speaker proofreading of the five AI-assisted translations is also an explicit known gap disclosed to users.

The QA impact layer sits before that gate: it tells reviewers and agents which scenario IDs a candidate's changed source/tests may affect and verifies that impacted manual/mixed IDs are represented in the candidate evidence. It does not change their result or claim they passed.

See [Behavioral QA Change Impact Traceability](../13-qa/change-impact-traceability.md) and [Release QA Evidence](../13-qa/release-evidence/README.md).

## Operational documentation

Production telemetry runtime/topology is intentionally not duplicated here. The private infrastructure vault owns current host/network/service/backup/dashboard operational facts; this repository owns the software contract. See [Public / Private Operations Boundary](../12-reference/operations-boundary.md).

## Next documentation work

The broad documentation foundation, release evidence, source/test→QA traceability, Guardian v2, 34-owner Type→Tests→Docs map and 21 high-risk freshness mappings are now in place. There is no value in expanding these registries by file count alone.

Future documentation work should primarily travel with product changes. Add a new curated type/freshness owner only when a new subsystem gains durable architectural responsibility or an actual drift incident exposes a missing route. Preserve concrete real-Mac release evidence for future versions and refine Guardian/QA matchers only when a real product change exposes a gap or false-positive pattern.

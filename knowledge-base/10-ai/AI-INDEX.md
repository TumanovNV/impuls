---
title: IMPULS AI Index
type: ai-index
status: active
documentation_version: 1.4
app_version: 1.4.15
last_reviewed: 2026-08-24
tags: [impuls, ai, agents, index, qa]
---

# IMPULS AI Documentation Index

## Обязательный старт

Перед изменением проекта: `AGENTS.md` → root `PROJECT-MANIFEST.json` → этот индекс → relevant subsystem/reference docs → code/tests/CI. Manifest — routing-only; старые handoff/release docs используются как history, не как current source of truth. Точная текущая версия принадлежит `Scripts/version`, а не копии номера в агентском entrypoint.

## Core map

- [Current Status](../00-project/project-status.md)
- [Pre-Audit Baseline — 1.4.12](../00-project/pre-audit-baseline-1.4.12.md)
- [Architecture](../01-architecture/architecture-overview.md)
- [System Diagrams](../01-architecture/system-diagrams.md)
- [Module Catalog](../02-modules/README.md)
- [Settings, Onboarding, Feedback and Project Support](../01-architecture/settings-onboarding-feedback.md)
- [Localization](../04-development/localization.md)
- [Security Model](../06-security/security-model.md)
- [Dependency / Supply Chain](../06-security/supply-chain.md)
- [Release Pipeline](../05-release/release-pipeline.md)
- [Release Architecture Ledger](../11-history/release-architecture-ledger.md)
- [Website Architecture](../07-web/website.md)
- [Website Legal and Privacy Localization](../07-web/legal-privacy.md)
- [Website Design System](../07-web/design-system.md)
- [Collector](../07-web/version-statistics-collector.md)
- [Current Limitations](../09-known-issues/current-limitations.md)
- [ADRs](../08-decisions/README.md)
- [Change Impact Matrix](change-impact-matrix.md)
- [Documentation Guardian](documentation-guardian.md)

## Precision reference layer

- [Machine-Readable Project Manifest](../12-reference/project-manifest.md)
- [Reference Index](../12-reference/README.md)
- [Schema & Migration Registry](../12-reference/schema-migration-registry.md)
- [Core Type Reference](../12-reference/core-type-reference.md)
- [Generated Type → Tests → Docs Map](../12-reference/generated-type-test-doc-map.md)
- [Background Work & Concurrency Registry](../12-reference/background-concurrency-registry.md)
- [Input & Resource Budget Registry](../12-reference/resource-budget-registry.md)
- [Public / Private Operations Boundary](../12-reference/operations-boundary.md)
- [Behavioral QA Matrix](../13-qa/behavioral-qa-matrix.md)
- [Behavioral QA Change Impact Traceability](../13-qa/change-impact-traceability.md)
- [Release QA Evidence](../13-qa/release-evidence/README.md)

## Routing

### Module
Read exact module page → generated type map → source + mapped tests. Include localization/schema/permission/network/performance/security docs when those contracts change. Before finishing a behavioral source/test diff, run QA impact traceability against the real PR base and review the reported scenario IDs.

### Settings / onboarding / feedback / project support

Read [Settings, Onboarding, Feedback and Project Support](../01-architecture/settings-onboarding-feedback.md) first — it is the canonical owner of every surface outside the notch panel, and finding it should not require grepping the repository. It covers `SettingsStore` and the Settings window, the first-run tour and What's New, the version-statistics offer, the feedback report path and the GitHub-star/feedback support prompt. Those surfaces share one rule: they present already-owned state and consent, and none of them may become a provider, poller, permission owner or network owner merely in order to display something. Feedback and project support each open an allow-listed HTTPS URL in the user's browser after an explicit click; Impuls performs no HTTP request for either, so neither is a fourth network owner. Persistence is registered in [Storage and Persistence](../01-architecture/storage-persistence.md) and the [Schema & Migration Registry](../12-reference/schema-migration-registry.md).

For the support prompt specifically: eligibility counters are machine-local, excluded from portable backup and never transmitted — they are not telemetry and must not grow a `prompt shown` or `star clicked` event. Impuls never asks GitHub whether a star exists and stores no `starred` flag. Meaningful use has one funnel in `NotchController` and the presentation moment has one owner in `AppDelegate`; do not add a second source for either. Thresholds live in the [Resource Budget Registry](../12-reference/resource-budget-registry.md), the one-shot deferral in the [Background Work & Concurrency Registry](../12-reference/background-concurrency-registry.md), and the manual contract is `SUP-01` in the [Behavioral QA Matrix](../13-qa/behavioral-qa-matrix.md).

### Localization / language rollout

Read [Localization](../04-development/localization.md) first. On the current 1.4.15 baseline the macOS app, marketing website and privacy/legal website each expose seven locales — `ru`, `en`, `de`, `fr`, `es`, `ja`, `zh-Hans` — but they are **three separate contracts** and must never be inferred from one another.

For app-localization changes verify `Resources/*.lproj`, `AppLanguageService`, `CFBundleLocalizations`, localization CI and the `UI-07` manual contract. For marketing website locale/routing changes also read [Website Architecture](../07-web/website.md). For privacy/legal translation, route or policy-revision changes also read [Website Legal and Privacy Localization](../07-web/legal-privacy.md) and `PRIVACY.md`.

A new `.lproj` alone does not publish a website/legal locale. A new website locale alone does not prove the app ships it. If the three sets intentionally diverge, document the divergence explicitly; do not leave future agents to infer it from directory names. After any language-set/routing change run `python3 Scripts/check-current-documentation.py` in addition to the focused localization/site/legal gates.

### Performance / concurrency / background work
Read Background Work & Concurrency Registry before timers, pollers, debounce/retry, Tasks, observers/sockets or queue/actor changes. For limits/timeouts/backpressure also read Resource Budget Registry. Then use the QA impact checker to see which behavioral contracts inherit the change.

### Persistence / backup / Keychain
Read Schema & Migration Registry first. Compatibility/migration, backup inclusion/exclusion and test isolation must be explicit. Review mapped `DATA-*`/release QA impact after implementation changes.

### Dependency / Package.swift / Package.resolved
Read Supply-Chain Policy + `Scripts/dependency-policy.json` + package files. Every resolved remote Swift package must be approved; direct dependencies use exact versions. Run `python3 Scripts/check-dependency-policy.py`.

### Permission
Read permissions + TCC + Behavioral QA + QA Impact Traceability + public privacy/security docs. Prompts remain explicit/user-contextual. If the task prepares or certifies a release, record the actual TCC result in that version's Release QA Evidence file; the matrix or impact report alone is never pass evidence.

### Network
Read networking + ADR-003 + threat model. Exactly three Internet network owners are established. A fourth is an architecture/security change. If the network change has user-visible service/lifecycle behavior, add or update the appropriate Behavioral QA row and impact route.

### Release/signing
Read signing/distribution + release pipeline + update system + ADR-005 + supply chain + Behavioral QA + QA Impact Traceability + Release QA Evidence. A version bump must travel with `docs/releases/<version>.md` **and** `knowledge-base/13-qa/release-evidence/<version>.md`. Starting with 1.4.12, historical `not-recorded` is forbidden: every manual/mixed scenario must have a truthful result and environment/gap classification.

Run the current-state and release gates against the real base before calling the candidate ready:

```bash
python3 Scripts/check-current-documentation.py
python3 Scripts/check-qa-impact.py --base <base-sha>
python3 Scripts/check-release-qa-evidence.py --release-gate
```

The current-documentation guard prevents cold-start/public entrypoints from silently retaining the previous release/localization/legal routing model. QA impact tells you which QA IDs the diff may have affected and confirms impacted non-automated IDs are represented in candidate evidence. Release QA Evidence owns the actual shipping decision. Never convert green unit tests into manual hardware/TCC passes.

If the release changes a durable architecture/privacy/security/performance/ownership contract, also add an entry to `Scripts/architecture-milestones.json`, regenerate the Release Architecture Ledger and create/update an ADR when warranted.

### Version comparison / historical reason
Use [Release Architecture Ledger](../11-history/release-architecture-ledger.md) for the evidence chain release → durable impact → canonical current docs → ADR → release note. Use Release QA Evidence for the independent chain release → real environment → manual result → known gap/decision. Release notes remain user-facing detail, not current architecture or test truth.

### Version statistics production runtime
Current production runtime belongs to the private infrastructure vault. If connected and current-state is required, start from `office-it-docs: Проекты/Impuls.md`; otherwise mark runtime facts unverified.

### Core type ownership change
Update `Scripts/knowledge-map-manifest.json`, regenerate the type map and run `--check`.

### Canonical documentation mapping / current entrypoint change
Consider whether `Scripts/documentation-freshness.json` must track a new high-risk canonical owner. If a change adds/moves a durable cold-start/public route, update `PROJECT-MANIFEST.json`, the relevant agent indexes and `Scripts/check-current-documentation.py` when the new invariant is machine-checkable.

### New behavioral edge
Add/update a Behavioral QA row when deterministic unit tests cannot fully prove a new platform/hardware/TCC/lifecycle path. Then add that ID to the correct source/test rule in `Scripts/qa-impact-rules.json`. The QA impact configuration validator requires every current matrix ID to have a route, and every automated ID to have a mapped test route. Review the current release evidence candidate too: adding a manual/mixed row creates a new evidence obligation. Documentation is not pass evidence.

### Behavioral owner/source change
Read [Behavioral QA Change Impact Traceability](../13-qa/change-impact-traceability.md). A changed tracked production file that matches no QA rule fails closed. Add the correct rule or, only when another explicit verification contract owns the area, a narrow documented exemption. Never add a broad `Sources/**` exemption.

### Full-repository security / performance audit
Read [Pre-Audit Baseline — 1.4.12](../00-project/pre-audit-baseline-1.4.12.md) before scanning code. Use `main` as the only current branch and always verify `Scripts/version`, current tags/releases and the current `main` HEAD before making release-state claims. The 1.4.12 pre-audit document is a trusted historical starting point, not the current shipped-version source of truth. Start with inventory and evidence; do not silently rewrite architecture to make a finding disappear. Performance findings must name the owning queue/actor/timer/provider and the measured or testable risk. Security findings must name the trust/data/permission/network boundary and distinguish exploitability from defense-in-depth.

## Trust rule

При конфликте сначала code + tests + CI. Затем исправь routed canonical knowledge owner и любой stale current-state/public/agent entrypoint. `Scripts/check-current-documentation.py` защищает mutable cold-start/public facts; Documentation Guardian защищает semantic diff obligations; freshness защищает source→doc history; QA impact защищает behavioral ownership. Historical architecture questions use the generated ledger as routing evidence, then verify linked release/canonical sources. Release certification claims require version-specific QA evidence rather than inference from tests, screenshots, impact reports or scenario inventory.

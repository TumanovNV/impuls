---
title: AI Change Impact Matrix
type: ai-reference
status: active
documentation_version: 1.3
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, ai, impact, checklist]
---

# Change Impact Matrix

Используй до правки, чтобы определить обязательные соседние файлы.

| Change | Read first | Usually update/check |
| --- | --- | --- |
| New/changed module | module page, architecture, invariants | store, pane, Tab, AppFeatureCatalog, settings, RU/EN, tests, module doc, QA rows, release notes |
| Core type ownership/source changes | Core Type Reference + generated map | source/tests/canonical doc, `knowledge-map-manifest.json`, regenerate map, knowledge-base CI |
| Timer/poller/debounce/retry/Task/queue | Background Work & Concurrency Registry | lifecycle, cancellation, tolerance, one-in-flight/backpressure, tests, registry, Guardian CI |
| Size/count/cadence/timeout limit | Input & Resource Budget Registry | worst-case cost, bounded/lazy alternative, tests, budget registry, Guardian CI |
| New user-visible platform/hardware lifecycle edge | Behavioral QA Matrix + current Release QA Evidence | automated test where possible + manual/mixed QA row with expected contract; if preparing a release, classify the new row in that version's evidence |
| Panel/motion | multi-display, state ownership, background registry | Theme, NotchController, surface/geometry, Reduce Motion tests, visual QA |
| Display behavior | multi-display + ADR-002 + QA matrix | DisplayCoordinator, topology, pointer, controller tests, DISP rows |
| Clipboard | clipboard doc + schema registry + budgets + storage/threat model | limits, concealed/internal, archive compatibility, persistence tests, privacy docs |
| Files/Shelf | shelf + threat model + budgets | bounded reads, overwrite/undo safety, FileTools tests |
| Calendar | calendar + permissions + background registry | EventKit state, active timer, no auto-prompt, link allow-list, entitlements, QA rows |
| Music | music + networking + permissions + background registry | PlayerBridge/WebMusicPlayer, timers, Automation, domain allow-list, network CI, QA rows |
| Power/devices | power + ADR-004 + background/budget registries + generated map | providers, identity, scheduler, local preference schema, no main-actor I/O, PWR QA |
| Settings/Codable field | Schema & Migration Registry | tolerant/default decode, old snapshot tests, backup behavior, local-only split |
| Persistence/file format | Schema & Migration Registry + storage + data classification | schema version, bounds, migration, deletion, backup, test isolation |
| Backup schema | Schema & Migration Registry | reader range, old-schema fixtures, rejection of future schema, import/export UI |
| Keychain identity/account | Schema & Migration Registry + security/data classification | compatibility, deletion lifecycle, device-only accessibility, no export/logging |
| Collector SQLite shape | Schema & Migration Registry + collector doc + Operations Boundary | explicit DB migration/version mechanism, Python tests, private backup/rollback runbook |
| New permission | permission architecture + TCC + QA matrix | UI explanation, entitlement, privacy/security, audit, PERM rows, CI; release candidate evidence if applicable |
| Network | networking + ADR-003 | consent, allow-list, payload, privacy, audit, CI; likely new ADR |
| Telemetry payload/endpoint | collector doc + schema registry + operations boundary | client + collector + tests + public privacy contract; private ops if deployment contract changes |
| Production telemetry runtime/topology | Operations Boundary | private `office-it-docs` project/server/service/network source of truth; do not copy topology public |
| Update/release | update system + ADR-005 + QA matrix + Release QA Evidence | workflows, bundle/dmg, Sparkle flags, REL rows, artifacts, security audit, version-specific manual/mixed evidence and release decision |
| Version bump | release pipeline + Release QA Evidence | `Scripts/version`, release notes, `knowledge-base/13-qa/release-evidence/<version>.md`, `python3 Scripts/check-release-qa-evidence.py --release-gate`, project-status if baseline changes |

## Mandatory post-change questions

1. Какой documented contract изменился?
2. Изменился ли persisted schema/key/format?
3. Изменился ли timer/task/queue/cadence или MainActor/off-main boundary?
4. Изменился ли size/count/timeout/backpressure budget?
5. Появился ли новый user-visible lifecycle/TCC/hardware edge, которому нужна QA row?
6. Если готовится release, отражён ли каждый manual/mixed QA row в version-specific evidence без выдуманных `pass`?
7. Изменился ли ownership важного type — нужно ли регенерировать map?
8. Затронут ли private production runtime, который принадлежит `office-it-docs`, а не public repo?

Если documented contract изменился, knowledge base входит в тот же change set. Если затронуты одновременно public software и private runtime facts, обновляются оба канонических владельца без дублирования чувствительной topology.

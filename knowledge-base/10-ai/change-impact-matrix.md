---
title: AI Change Impact Matrix
type: ai-reference
status: active
documentation_version: 1.3
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, ai, impact, checklist, qa]
---

# Change Impact Matrix

Используй до правки, чтобы определить обязательные соседние файлы. После изменения поведенческого кода или связанных tests дополнительно прогоняй QA impact traceability: она машинно выводит затронутые Behavioral QA ID из фактического diff.

| Change | Read first | Usually update/check |
| --- | --- | --- |
| New/changed module | module page, architecture, invariants, QA impact traceability | store, pane, Tab, AppFeatureCatalog, settings, RU/EN, tests, module doc, QA rows, `qa-impact-rules.json`, release notes |
| Core type ownership/source changes | Core Type Reference + generated map + QA impact traceability | source/tests/canonical doc, `knowledge-map-manifest.json`, QA source/test ownership rule if behavioral, regenerate map, knowledge-base CI |
| Timer/poller/debounce/retry/Task/queue | Background Work & Concurrency Registry | lifecycle, cancellation, tolerance, one-in-flight/backpressure, tests, registry, Guardian CI, impacted QA IDs |
| Size/count/cadence/timeout limit | Input & Resource Budget Registry | worst-case cost, bounded/lazy alternative, tests, budget registry, Guardian CI, impacted QA IDs |
| New user-visible platform/hardware lifecycle edge | Behavioral QA Matrix + QA Impact Traceability + current Release QA Evidence | automated test where possible + manual/mixed QA row with expected contract + source/test route in `qa-impact-rules.json`; if preparing a release, classify the new row in that version's evidence |
| Panel/motion | multi-display, state ownership, background registry | Theme, NotchController, surface/geometry, Reduce Motion tests, visual QA, `DISP-*`/`UI-*` impact |
| Display behavior | multi-display + ADR-002 + QA matrix | DisplayCoordinator, topology, pointer, controller tests, `DISP-*`; verify impact checker output |
| Clipboard | clipboard doc + schema registry + budgets + storage/threat model | limits, concealed/internal, archive compatibility, persistence tests, privacy docs, `DATA-*` impact |
| Files/Shelf | shelf + threat model + budgets | bounded reads, overwrite/undo safety, FileTools tests; update impact route if ownership is newly behavioral |
| Calendar | calendar + permissions + background registry | EventKit state, active timer, no auto-prompt, link allow-list, entitlements, `PERM-*`, impact checker |
| Music | music + networking + permissions + background registry | PlayerBridge/WebMusicPlayer, timers, Automation, domain allow-list, network CI, `MUS-*`/`PERM-*`, impact checker |
| Power/devices | power + ADR-004 + background/budget registries + generated map | providers, identity, scheduler, local preference schema, no main-actor I/O, `PWR-*`/`PERM-*`, impact checker |
| Settings/Codable field | Schema & Migration Registry | tolerant/default decode, old snapshot tests, backup behavior, local-only split, `DATA-*`/release impact |
| Persistence/file format | Schema & Migration Registry + storage + data classification | schema version, bounds, migration, deletion, backup, test isolation, impacted `DATA-*` IDs |
| Backup schema | Schema & Migration Registry | reader range, old-schema fixtures, rejection of future schema, import/export UI, release-preservation impact |
| Keychain identity/account | Schema & Migration Registry + security/data classification | compatibility, deletion lifecycle, device-only accessibility, no export/logging, power/data QA impact as applicable |
| Collector SQLite shape | Schema & Migration Registry + collector doc + Operations Boundary | explicit DB migration/version mechanism, Python tests, private backup/rollback runbook; collector is outside app Behavioral QA unless user-facing contract changes |
| New permission | permission architecture + TCC + QA matrix + QA impact traceability | UI explanation, entitlement, privacy/security, audit, new/updated `PERM-*`, source/test mapping, release candidate evidence if applicable |
| Network | networking + ADR-003 | consent, allow-list, payload, privacy, audit, CI; likely new ADR; add Behavioral QA only if user-facing lifecycle/service behavior changes |
| Telemetry payload/endpoint | collector doc + schema registry + operations boundary | client + collector + tests + public privacy contract; private ops if deployment contract changes; current version-only telemetry exemption remains narrow |
| Production telemetry runtime/topology | Operations Boundary | private `office-it-docs` project/server/service/network source of truth; do not copy topology public |
| Update/release | update system + ADR-005 + QA matrix + QA Impact Traceability + Release QA Evidence | workflows, bundle/dmg, Sparkle flags, `REL-*`, artifacts, security audit, version-specific manual/mixed evidence and release decision |
| Version bump | release pipeline + QA Impact Traceability + Release QA Evidence | `Scripts/version`, release notes, `knowledge-base/13-qa/release-evidence/<version>.md`, `python3 Scripts/check-qa-impact.py --base <base-sha>`, `python3 Scripts/check-release-qa-evidence.py --release-gate`, project-status if baseline changes |

## Mandatory post-change questions

1. Какой documented contract изменился?
2. Изменился ли persisted schema/key/format?
3. Изменился ли timer/task/queue/cadence или MainActor/off-main boundary?
4. Изменился ли size/count/timeout/backpressure budget?
5. Какие Behavioral QA ID вывел `check-qa-impact.py` для фактического diff?
6. Если появился новый behavioral source owner, есть ли у него явный rule в `Scripts/qa-impact-rules.json`, а не случайный broad exemption?
7. Появился ли новый user-visible lifecycle/TCC/hardware edge, которому нужна новая QA row и новый source/test route?
8. Если готовится release, отражены ли затронутые manual/mixed QA ID в version-specific evidence без выдуманных `pass`?
9. Изменился ли ownership важного type — нужно ли регенерировать map?
10. Затронут ли private production runtime, который принадлежит `office-it-docs`, а не public repo?

Если documented contract изменился, knowledge base входит в тот же change set. Если изменилось behavioral ownership, QA impact map входит в тот же change set. Если затронуты одновременно public software и private runtime facts, обновляются оба канонических владельца без дублирования чувствительной topology.

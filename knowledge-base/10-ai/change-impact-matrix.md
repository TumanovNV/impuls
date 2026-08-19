---
title: AI Change Impact Matrix
type: ai-reference
status: active
documentation_version: 1.2
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, ai, impact, checklist]
---

# Change Impact Matrix

Используй до правки, чтобы определить обязательные соседние файлы.

| Change | Read first | Usually update/check |
| --- | --- | --- |
| New/changed module | module page, architecture, invariants | store, pane, Tab, AppFeatureCatalog, settings, RU/EN, tests, module doc, release notes |
| Core type ownership/source changes | Core Type Reference + generated map | source/tests/canonical doc, `knowledge-map-manifest.json`, regenerate map, knowledge-base CI |
| Panel/motion | multi-display, state ownership | Theme, NotchController, surface/geometry, Reduce Motion tests, visual QA |
| Display behavior | multi-display + ADR-002 | DisplayCoordinator, topology, pointer, controller tests |
| Clipboard | clipboard doc + schema registry + storage/threat model | limits, concealed/internal, archive compatibility, persistence tests, privacy docs |
| Files/Shelf | shelf + threat model | bounded reads, overwrite/undo safety, FileTools tests |
| Calendar | calendar + permissions | EventKit state, no auto-prompt, link allow-list, entitlements |
| Music | music + networking + permissions | PlayerBridge/WebMusicPlayer, Automation, domain allow-list, network CI |
| Power/devices | power + ADR-004 + generated map | providers, identity, scheduler, local preference schema, no main-actor I/O, hardware QA |
| Settings/Codable field | Schema & Migration Registry | tolerant/default decode, old snapshot tests, backup behavior, local-only split |
| Persistence/file format | Schema & Migration Registry + storage + data classification | schema version, bounds, migration, deletion, backup, test isolation |
| Backup schema | Schema & Migration Registry | reader range, old-schema fixtures, rejection of future schema, import/export UI |
| Keychain identity/account | Schema & Migration Registry + security/data classification | compatibility, deletion lifecycle, device-only accessibility, no export/logging |
| Collector SQLite shape | Schema & Migration Registry + collector doc + Operations Boundary | explicit DB migration/version mechanism, Python tests, private backup/rollback runbook |
| New permission | permission architecture | UI explanation, TCC/entitlement, privacy/security, audit, CI |
| Network | networking + ADR-003 | consent, allow-list, payload, privacy, audit, CI; likely new ADR |
| Telemetry payload/endpoint | collector doc + schema registry + operations boundary | client + collector + tests + public privacy contract; private ops if deployment contract changes |
| Production telemetry runtime/topology | Operations Boundary | private `office-it-docs` project/server/service/network source of truth; do not copy topology public |
| Update/release | update system + ADR-005 | workflows, bundle/dmg, Sparkle flags, artifacts, security audit |
| Version bump | release pipeline | `Scripts/version`, release notes, knowledge-base project-status if baseline changes |

## Mandatory post-change questions

1. Какой documented contract изменился?
2. Изменился ли persisted schema/key/format?
3. Изменился ли ownership важного type — нужно ли регенерировать map?
4. Затронут ли private production runtime, который принадлежит `office-it-docs`, а не public repo?

Если documented contract изменился, knowledge base входит в тот же change set. Если затронуты одновременно public software и private runtime facts, обновляются оба канонических владельца без дублирования чувствительной topology.

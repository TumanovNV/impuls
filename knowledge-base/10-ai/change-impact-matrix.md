---
title: AI Change Impact Matrix
type: ai-reference
status: active
documentation_version: 1.1
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, ai, impact, checklist]
---

# Change Impact Matrix

Используй до правки, чтобы определить обязательные соседние файлы.

| Change | Read first | Usually update/check |
| --- | --- | --- |
| New/changed module | module page, architecture, invariants | store, pane, Tab, AppFeatureCatalog, settings, RU/EN, tests, module doc, release notes |
| Panel/motion | multi-display, state ownership | Theme, NotchController, surface/geometry, Reduce Motion tests, visual QA |
| Display behavior | multi-display + ADR-002 | DisplayCoordinator, topology, pointer, controller tests |
| Clipboard | clipboard doc + storage/threat model | limits, concealed/internal, persistence tests, privacy docs |
| Files/Shelf | shelf + threat model | bounded reads, overwrite/undo safety, FileTools tests |
| Calendar | calendar + permissions | EventKit state, no auto-prompt, link allow-list, entitlements |
| Music | music + networking + permissions | PlayerBridge/WebMusicPlayer, Automation, domain allow-list, network CI |
| Power/devices | power + ADR-004 | providers, identity, scheduler, no main-actor I/O, hardware QA |
| Persistence | storage + data classification | schema, limits, migration, deletion, backup, test isolation |
| New permission | permission architecture | UI explanation, TCC/entitlement, privacy/security, audit, CI |
| Network | networking + ADR-003 | consent, allow-list, payload, privacy, audit, CI; likely new ADR |
| Update/release | update system + ADR-005 | workflows, bundle/dmg, Sparkle flags, artifacts, security audit |
| Version bump | release pipeline | `Scripts/version`, release notes, knowledge-base project-status if baseline changes |

## Mandatory post-change question

«Какой documented contract изменился?» Если ответ не «никакой», knowledge base входит в тот же change set.

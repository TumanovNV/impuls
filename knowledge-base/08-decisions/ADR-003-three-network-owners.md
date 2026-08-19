---
title: ADR-003 Three Network Owners
type: decision
status: accepted
documentation_version: 1.1
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, adr, networking, security]
---

# ADR-003 — Three Network Owners

## Status

Accepted and CI-enforced.

## Context

Local-first product должен иметь auditable network surface. Разрешение произвольного `URLSession` в module services сделало бы privacy claims непроверяемыми.

## Decision

Internet networking APIs разрешены только:

1. `UpdateService.swift` / Sparkle signed update flow;
2. `WebMusicPlayer.swift` после explicit Open Web Player;
3. `VersionTelemetryService.swift` после отдельного opt-in.

## Enforcement

`build.yml` и `release.yml` grep'ят network API patterns во всех остальных source files и падают при нарушении.

## Consequences

Новый сетевой feature нельзя «просто добавить». Требуется отдельное архитектурное/security решение, consent model, privacy update, tests/audit и CI boundary change.

## References

- [Networking Architecture](../01-architecture/networking.md)
- [Threat Model](../06-security/threat-model.md)

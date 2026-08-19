---
title: Architecture Decision Records
type: decision-index
status: active
documentation_version: 1.1
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, adr, decisions]
---

# Architecture Decision Records

ADR фиксирует **почему** долгоживущее решение принято, чтобы будущий рефакторинг не отменил его случайно.

- [ADR-001 — Knowledge Base Location](ADR-001-knowledge-base-location.md)
- [ADR-002 — Shared Services, Per-Display Presentation](ADR-002-shared-services-per-display-presentation.md)
- [ADR-003 — Three Network Owners](ADR-003-three-network-owners.md)
- [ADR-004 — Local-Only Device Identity](ADR-004-local-only-device-identity.md)
- [ADR-005 — Signed Update Trust Chain](ADR-005-signed-update-trust-chain.md)

## Когда нужен новый ADR

Ownership/lifecycle architecture; новый network owner; identity/privacy boundary; persistent schema with migration consequences; update/release trust chain; fundamental platform decision. Мелкий implementation detail ADR не требует.

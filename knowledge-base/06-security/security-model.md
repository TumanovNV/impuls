---
title: Security Model
type: security
status: active
documentation_version: 1.1
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, security, model]
---

# Security Model

## Security posture

ИМПУЛЬС проектируется как local-first desktop utility с минимальными explicit boundaries вместо broad background access.

## Security pillars

1. **Bounded input** — files, pasteboard, artwork, search and link scans have explicit limits.
2. **Minimal networking** — three CI-enforced owners only.
3. **Explicit permissions/consent** — no sensitive prompt merely because app launched/updated.
4. **Identity isolation** — raw hardware identity does not cross into UI/log/backup/telemetry.
5. **Signed updates** — fixed feed + signed feed/archive + verify-before-extraction.
6. **Failure isolation** — optional provider/module failure does not collapse unrelated product state.
7. **Test isolation** — injected storage/environment protects real user data.

## Read next

- [Threat Model](threat-model.md)
- [Data Classification](data-classification.md)
- [Privacy Boundaries](privacy-boundaries.md)
- [Networking Architecture](../01-architecture/networking.md)
- [Permission Architecture](../01-architecture/permissions.md)
- [Update System](../05-release/update-system.md)

Public commitments remain in `PRIVACY.md` and `SECURITY.md`; relevant security changes also receive versioned audits under `docs/audits/`.

---
title: Release Architecture Ledger
type: generated-history
status: active
documentation_version: 1.3
app_version: 1.4.13
last_reviewed: 2026-08-19
tags: [impuls, history, releases, architecture, generated]
---

# Release Architecture Ledger

> Generated from `Scripts/architecture-milestones.json`. Do not hand-edit this file.

This is not a user-facing changelog. It records verified release points where a long-lived architecture, privacy, security, performance or ownership contract changed.

| Release | Category | Architecture impact | Canonical docs | ADR | Release evidence |
| --- | --- | --- | --- | --- | --- |
| 1.2.9 | `update-security` | Signed Sparkle in-app update trust chain with explicit user-controlled network/update behavior. | [update-system.md](../05-release/update-system.md)<br>[supply-chain.md](../06-security/supply-chain.md) | [ADR-005-signed-update-trust-chain.md](../08-decisions/ADR-005-signed-update-trust-chain.md) | [release note](../../docs/releases/1.2.9.md) |
| 1.3.0 | `media-network` | Music split into an explicit native Apple Music adapter and user-opened official WebKit sources. | [music.md](../02-modules/music.md)<br>[networking.md](../01-architecture/networking.md) | — | [release note](../../docs/releases/1.3.0.md) |
| 1.4.6 | `devices-privacy` | External Apple-device battery providers, explicit discovery consent and opaque local device identity boundary. | [power.md](../02-modules/power.md)<br>[privacy-boundaries.md](../06-security/privacy-boundaries.md) | [ADR-004-local-only-device-identity.md](../08-decisions/ADR-004-local-only-device-identity.md) | [release note](../../docs/releases/1.4.6.md) |
| 1.4.7 | `presentation` | Multi-display presentation with one shared service graph, per-display surfaces and exactly one active panel. | [multi-display.md](../01-architecture/multi-display.md)<br>[state-and-ownership.md](../01-architecture/state-and-ownership.md) | [ADR-002-shared-services-per-display-presentation.md](../08-decisions/ADR-002-shared-services-per-display-presentation.md) | [release note](../../docs/releases/1.4.7.md) |
| 1.4.8 | `performance` | Panel transition work moved behind a fixed-envelope motion contract; inactive surfaces stay lightweight and refreshes wait for motion completion. | [background-concurrency-registry.md](../12-reference/background-concurrency-registry.md)<br>[multi-display.md](../01-architecture/multi-display.md) | — | [release note](../../docs/releases/1.4.8.md) |
| 1.4.9 | `devices-privacy` | The user-facing connected-Apple-devices setting became the single product gate for iPhone/iPad discovery and I/O. | [power.md](../02-modules/power.md)<br>[permissions.md](../01-architecture/permissions.md) | [ADR-004-local-only-device-identity.md](../08-decisions/ADR-004-local-only-device-identity.md) | [release note](../../docs/releases/1.4.9.md) |
| 1.4.10 | `privacy-network` | Opt-in version statistics introduced a separate first-party collector and the third explicit Internet network owner. | [networking.md](../01-architecture/networking.md)<br>[version-statistics-collector.md](../07-web/version-statistics-collector.md) | [ADR-003-three-network-owners.md](../08-decisions/ADR-003-three-network-owners.md) | [release note](../../docs/releases/1.4.10.md) |
| 1.4.11 | `presentation` | First-run/What's New split and a configurable Menu Bar workspace that consumes existing shared state without starting new work. | [menu-bar.md](../02-modules/menu-bar.md)<br>[settings-onboarding-feedback.md](../01-architecture/settings-onboarding-feedback.md) | — | [release note](../../docs/releases/1.4.11.md) |
| 1.4.13 | `reliability-performance` | Clipboard, Shelf, Snippets, Menu Bar, Actions, Web Music and Power ownership paths were hardened for data durability, bounded work and deterministic teardown. | [storage-persistence.md](../01-architecture/storage-persistence.md)<br>[state-and-ownership.md](../01-architecture/state-and-ownership.md)<br>[background-concurrency-registry.md](../12-reference/background-concurrency-registry.md)<br>[resource-budget-registry.md](../12-reference/resource-budget-registry.md) | — | [release note](../../docs/releases/1.4.13.md) |

## Maintenance contract

Add a milestone only for a durable contract change, not every feature or bug fix. The release note is evidence that the change shipped; canonical docs describe the current contract; ADRs explain durable decisions when one exists.

When a release introduces a new long-lived architecture boundary, update `Scripts/architecture-milestones.json`, run `python3 Scripts/generate-architecture-ledger.py`, and include the generated file in the same change.

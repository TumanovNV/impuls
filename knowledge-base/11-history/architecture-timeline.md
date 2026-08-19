---
title: Architecture Timeline
type: history
status: active
documentation_version: 1.3
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, history, architecture]
---

# Architecture Timeline

Это не полный changelog, а компактная карта архитектурных рубежей. Для machine-checked release evidence используй [Release Architecture Ledger](release-architecture-ledger.md).

```mermaid
timeline
    title IMPULS architecture milestones
    1.2 : Actions local search
        : Clipboard/Snippets/Notes integration
    1.2.2-1.2.3 : Local file tools
        : Group operations and safer undo
    1.2.9 : Sparkle signed in-app updates
        : Explicit update consent boundary
    1.3.0 : Reworked music architecture
        : Explicit native source + user-opened WebKit boundary
    1.4.6 : Apple Device Battery Center
        : Provider architecture + opaque identity
    1.4.7 : Multi-display
        : Shared services / per-display surfaces
    1.4.8 : Fixed-envelope motion/performance
        : Transition race hardening
    1.4.9 : Mobile-device discovery product boundary fix
        : Show Connected Apple Devices becomes only product gate
    1.4.10 : Readable Settings + opt-in version statistics
        : Third network owner
    1.4.11 : Onboarding + configurable Menu Bar workspace
        : Presentation-only widgets over existing state
    Docs 1.0 : Markdown/Obsidian knowledge base
    Docs 1.1 : Module contracts + diagrams + threat/release model
    Docs 1.2 : Schema/type reference + public/private operations boundary
    Docs 1.3 : Guardian + freshness + QA + machine routing + supply-chain controls
```

Для user-facing деталей см. `docs/releases/`. Для причин — ADR и architecture pages. Для точной связи release → architecture → ADR → evidence — generated ledger.

@AGENTS.md

## Claude Code

The shared instructions above apply.

Before planning or editing, read `knowledge-base/10-ai/AI-INDEX.md`. It is the current navigation layer for project status, architecture, modules, security boundaries, release flow, performance/concurrency, QA and repository ownership. Historical files under `docs/` remain useful evidence, but they are not automatically current state.

A few things specific to this setup:

- **Path-scoped rules live in `.claude/rules/`.** They load only when you touch the matching files: `website.md` for `docs/`, `swift-ui.md` for the panel code, `localization.md` for the string tables, `release.md` for version and workflow files.
- **Use plan mode** before editing `Sources/Impuls/Services/UpdateService.swift`, `Scripts/bundle.sh`, `Package.swift` or anything under `.github/workflows/`. Those areas carry security and release guarantees; changes there are never casual one-liners.
- **Read `Sources/Impuls/UI/Theme.swift` before any UI work.** Every size, radius, colour and animation curve is defined there or in the pane itself. Do not invent visual constants without understanding the existing system.
- **Read the v1.3 reference registries before performance-sensitive work.** A timer/poller/debounce/Task/queue/actor change routes through `knowledge-base/12-reference/background-concurrency-registry.md`; a size/count/cadence/timeout/backpressure change routes through `knowledge-base/12-reference/resource-budget-registry.md`; persisted formats still route through the schema registry.
- **Update Behavioral QA** when work adds a new display/TCC/hardware/service/update/lifecycle scenario that cannot be fully proven by a deterministic unit test.
- **Run the repository's current test commands yourself** rather than reporting a change as done. Treat a red test as information, not noise.
- The `Documentation Guardian` is semantic review pressure, not a formatting exercise. If it fires, establish the real contract from code/tests and update the canonical doc truthfully; do not make a meaningless Markdown touch.
- When a change alters architecture, module contracts, networking, permissions, persistence, background work, resource budgets or release flow, update the corresponding file under `knowledge-base/` in the same change. Create an ADR for a new long-lived architectural decision.

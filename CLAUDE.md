@AGENTS.md

## Claude Code

The shared instructions above apply.

Before planning or editing, read `knowledge-base/10-ai/AI-INDEX.md`. It is the current navigation layer for project status, architecture, modules, security boundaries, release flow and repository ownership. Historical files under `docs/` remain useful evidence, but they are not automatically current state.

A few things specific to this setup:

- **Path-scoped rules live in `.claude/rules/`.** They load only when you touch the matching files: `website.md` for `docs/`, `swift-ui.md` for the panel code, `localization.md` for the string tables, `release.md` for version and workflow files.
- **Use plan mode** before editing `Sources/Impuls/Services/UpdateService.swift`, `Scripts/bundle.sh`, `Package.swift` or anything under `.github/workflows/`. Those areas carry security and release guarantees; changes there are never casual one-liners.
- **Read `Sources/Impuls/UI/Theme.swift` before any UI work.** Every size, radius, colour and animation curve is defined there or in the pane itself. Do not invent visual constants without understanding the existing system.
- **Run the repository's current test commands yourself** rather than reporting a change as done. Treat a red test as information, not noise.
- When a change alters architecture, module contracts, networking, permissions, persistence or release flow, update the corresponding file under `knowledge-base/` in the same change. Create an ADR for a new long-lived architectural decision.

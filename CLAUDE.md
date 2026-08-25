@AGENTS.md

## Claude Code

The shared instructions above apply in full. This file adds only what is specific to running as Claude Code — it deliberately does not restate the invariants, the routing workflow or the validation order.

- **Start with the router**, not with a document: `python3 Scripts/agent-context.py <changed-path>`. Read what it returns.
- **Path-scoped rules load themselves, and the router does not route to them.** `.claude/rules/*.md` carry `paths:` frontmatter, so `swift-ui.md`, `localization.md`, `release.md`, `qa-impact.md`, `website.md` and `legal-privacy.md` arrive only when you touch the matching files. `Scripts/agent-context.py` is shared with other agents and deliberately never names them — the two mechanisms are separate, so do not add one to the other. Do not read them pre-emptively, and do not copy their content anywhere else. Website, legal and app localization are three separate contracts — `knowledge-base/04-development/localization.md` is the canonical route before changing the supported-language set.
- **Use plan mode** before editing `Sources/Impuls/Services/UpdateService.swift`, `Scripts/bundle.sh`, `Package.swift` or anything under `.github/workflows/`. Those carry security and release guarantees and are never casual one-liners.
- **Read `Sources/Impuls/UI/Theme.swift` before any UI work.** Every size, radius, colour and animation curve is defined there or in the pane itself.
- **Commit before running the documentation gates.** Freshness, Documentation Guardian and QA impact all compare committed state, so a pre-commit run reports a tree you are not pushing. This has produced a red CI more than once.
- **Anchor edits on the doc comment, not the declaration.** A replacement anchored on `final class X` can land inside its attribute list and silently move an `@MainActor` onto the previous declaration. That failure compiles and passes tests.

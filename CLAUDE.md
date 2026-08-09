@AGENTS.md

## Claude Code

The shared instructions above apply. A few things specific to this setup:

- **Path-scoped rules live in `.claude/rules/`.** They load only when you touch the
  matching files: `website.md` for `docs/`, `swift-ui.md` for the panel code,
  `localization.md` for the string tables, `release.md` for version and workflow files.
- **Use plan mode** before editing `Sources/Impuls/Services/UpdateService.swift`,
  `Scripts/bundle.sh`, `Package.swift` or anything under `.github/workflows/`. Those
  four carry the security guarantees the project is built on, and a change there is
  never a one-liner.
- **Read `Sources/Impuls/UI/Theme.swift` before any UI work.** Every size, radius,
  colour and animation curve is defined there or in the pane itself. Inventing a
  value is how the panel stops looking native.
- **Run `swift test -c release` yourself** rather than reporting a change as done.
  The suite is fast and covers the stores, so a red test is information, not noise.
- **Do not run `git commit`, `git push` or `gh release`.** Prepare the change, show
  the diff, and let the maintainer send it.
